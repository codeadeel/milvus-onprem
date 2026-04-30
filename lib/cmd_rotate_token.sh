# =============================================================================
# lib/cmd_rotate_token.sh — atomic cluster-wide CLUSTER_TOKEN rotation
#
# Submits a `rotate-token` job to the local control-plane daemon. The
# leader's worker fans out to every follower in parallel via the
# documented HTTP control plane (POST /rotate-self with the OLD bearer
# token, body carries the NEW token); each peer writes cluster.env,
# re-renders, and schedules a detached self-recreate of its own
# control-plane container. Leader rotates itself last.
#
# Cross-peer transport is always HTTP+bearer; SSH between peers is
# never assumed (production peers don't have it).
# =============================================================================

[[ -n "${_CMD_ROTATE_TOKEN_SH_LOADED:-}" ]] && return 0
_CMD_ROTATE_TOKEN_SH_LOADED=1

cmd_rotate_token() {
  local new_token=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --new-token=*) new_token="${1#*=}"; shift ;;
      --new-token)   new_token="$2"; shift 2 ;;
      --force)       force=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: milvus-onprem rotate-token [OPTIONS]

Rotate the cluster-wide CLUSTER_TOKEN atomically across every peer.

  --new-token=KEY      Use this exact value (default: auto-generate).
                       Must be at least 32 chars (256 bits).
  --force              Skip confirmation.

What happens:
  1. The CLI submits a `rotate-token` job to the local daemon.
  2. The leader's worker POSTs /rotate-self to every follower in
     parallel (auth'd with the OLD token; body carries the NEW one).
  3. Each peer writes cluster.env, re-renders, and schedules a
     detached self-recreate of its control-plane container.
  4. The leader rotates itself last; its own daemon recreates
     ~5 seconds after the job returns.
  5. The CLI verifies every peer accepts the new token.

Constraints:
  - distributed mode (rotation is meaningless in standalone)
  - all peer daemons must be reachable from the leader

If verification fails, the command stops immediately and prints which
peer(s) didn't accept. Recovery: re-run with --new-token=<that value>
to retry, or `teardown` + redeploy in the worst case.
EOF
        return 0
        ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  env_require
  role_detect
  if [[ "${MODE:-standalone}" != "distributed" ]]; then
    die "rotate-token requires MODE=distributed (no token to rotate in standalone)"
  fi

  if [[ -z "$new_token" ]]; then
    new_token="$(_gen_secret_key 32)"
    info "generated new CLUSTER_TOKEN: $new_token"
  fi
  if (( ${#new_token} < 32 )); then
    die "--new-token must be at least 32 chars (got ${#new_token})"
  fi

  if (( ! force )) && [[ -t 0 ]]; then
    echo ""
    echo "About to rotate CLUSTER_TOKEN across cluster $CLUSTER_NAME"
    echo "Peers: ${PEER_IPS}"
    echo "All daemons will recreate ~simultaneously (~5-10s outage of"
    echo "daemon-only operations; data plane unaffected)."
    read -rp "Continue? [y/N] " yn
    [[ "$yn" =~ ^[Yy] ]] || die "aborted"
  fi

  _rotate_via_daemon "$new_token"
}

# Submit a rotate-token job and poll until done.
_rotate_via_daemon() {
  local new_token="$1"
  local cp_url="http://127.0.0.1:${CONTROL_PLANE_PORT:-19500}"
  local token="${CLUSTER_TOKEN:-}"
  [[ -n "$token" ]] || die "CLUSTER_TOKEN missing in cluster.env"

  local body
  body=$(python3 -c "
import json
print(json.dumps({'type':'rotate-token','params':{'new_token':'$new_token'}}))
")

  info "==> POST /jobs (rotate-token) on $cp_url"
  local resp
  resp=$(curl -fsS --location-trusted --max-time 30 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" "$cp_url/jobs") \
    || die "POST /jobs failed — daemon unreachable?"
  local job_id
  job_id=$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  ok "job created: $job_id"

  # Poll until terminal state. Don't reuse _poll_job (cmd_upgrade.sh)
  # because it auths with the OLD token; once the rotation is done,
  # subsequent polls would fail. We finish polling BEFORE the daemons
  # recreate (job marks done before the 5s recreate delay) so the OLD
  # token still works.
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    local job
    job=$(curl -fsS --max-time 10 \
      -H "Authorization: Bearer $token" "$cp_url/jobs/$job_id" 2>/dev/null) \
      || { sleep 2; continue; }
    local state
    state=$(printf '%s' "$job" | python3 -c "import json,sys; print(json.load(sys.stdin)['state'])" 2>/dev/null || echo unknown)
    case "$state" in
      done) info "  job $job_id: done"; break ;;
      failed|cancelled)
        local err_msg
        err_msg=$(printf '%s' "$job" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error') or '')" 2>/dev/null || echo "")
        die "job $job_id $state: $err_msg"
        ;;
    esac
    sleep 2
  done

  # Wait for daemons to recreate with the new token (~5s detached
  # delay + container restart time).
  info "==> waiting 15s for daemons to recreate with new token"
  sleep 15

  # Verify every peer accepts the new token. Each peer's daemon
  # container restarts ~5s after the job returns, then takes a few
  # seconds to come healthy (FastAPI + etcd reconnect + leader
  # election). The 15s post-job sleep covers most peers, but slow
  # disks or a peer whose recreate landed at the tail end of the
  # window can still need a few more seconds — so we retry per
  # peer with backoff before declaring failure. 3 attempts × 5s
  # apart ≈ 15s extra ceiling per peer, only paid when needed.
  info "==> verifying every peer accepts the new token"
  local failures=0
  for ip in ${PEER_IPS//,/ }; do
    local code attempt=0 max_attempts=3
    while (( attempt < max_attempts )); do
      code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
        -H "Authorization: Bearer $new_token" \
        "http://$ip:${CONTROL_PLANE_PORT:-19500}/leader" 2>/dev/null \
        || echo 000)"
      [[ "$code" == "200" ]] && break
      attempt=$((attempt + 1))
      (( attempt < max_attempts )) && sleep 5
    done
    if [[ "$code" == "200" ]]; then
      if (( attempt > 0 )); then
        info "  $ip: OK (after $((attempt + 1)) attempts)"
      else
        info "  $ip: OK"
      fi
    else
      err "  $ip: HTTP $code (token rejected after $max_attempts attempts)"
      failures=$((failures + 1))
    fi
  done
  (( failures == 0 )) || die "$failures peer(s) didn't accept the new token. Re-run with --new-token=$new_token, or recover manually."

  ok "CLUSTER_TOKEN rotated across all peers."
  echo ""
  echo "  new token: $new_token"
  echo ""
  echo "  Save it somewhere safe. The old token will not work for"
  echo "  daemon RPCs or new joins."
}
