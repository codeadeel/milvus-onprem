# =============================================================================
# lib/cmd_rotate_token.sh — atomic cluster-wide CLUSTER_TOKEN rotation
#
# QA finding F-R4-B.1: rotating CLUSTER_TOKEN one peer at a time leaves a
# window where some peers have NEW + others have OLD, and daemon-to-daemon
# RPCs (rolling MinIO, /upgrade-self, /recreate-minio-self) fail with 403
# during that window. The bash CLI's per-peer rotation works, but operators
# have to coordinate fast.
#
# This command does the right ordering automatically:
#   1. Generate new token
#   2. Update every peer's cluster.env (parallel scp + sed via SSH)
#   3. Render on every peer (parallel)
#   4. Force-recreate every peer's daemon (parallel — accepts the brief
#      RPC dead-window because all daemons restart with the new token at
#      roughly the same instant)
#   5. Verify all peers respond to the new token; fail if any rejects
#
# This requires SSH from the operator host to every peer (the same SSH
# the operator uses for normal multi-host work; we don't add new SSH
# requirements). Standalone mode is a single-step.
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
                       Must be at least 32 hex chars (256 bits).
  --force              Skip confirmation.

What happens:
  1. Generate (or accept) a new CLUSTER_TOKEN.
  2. Update every peer's cluster.env (this peer first, then SSH to others).
  3. Re-render every peer's compose.
  4. Force-recreate every peer's control-plane daemon ~simultaneously.
  5. Verify every peer accepts the new token.

Requirements:
  - distributed mode (rotation is meaningless in standalone)
  - operator's SSH key on every peer's $HOME/.ssh/authorized_keys

If verification fails, the command stops immediately and prints which
peer(s) didn't accept. Recovery: re-run with --new-token=<that value>
to retry, or run teardown + redeploy in the worst case.
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
    echo "All daemons will be restarted in parallel (~5-10s outage of"
    echo "daemon-only operations; data plane unaffected)."
    read -rp "Continue? [y/N] " yn
    [[ "$yn" =~ ^[Yy] ]] || die "aborted"
  fi

  # Step 1+2: update every peer's cluster.env in parallel
  info "==> updating cluster.env on every peer"
  local pids=() failures=0
  for ip in ${PEER_IPS//,/ }; do
    if [[ "$ip" == "$LOCAL_IP" ]]; then
      sed -i "s/^CLUSTER_TOKEN=.*/CLUSTER_TOKEN=$new_token/" "$CLUSTER_ENV"
    else
      ( ssh -o StrictHostKeyChecking=no "adeel@$ip" \
          "sed -i 's/^CLUSTER_TOKEN=.*/CLUSTER_TOKEN=$new_token/' /home/adeel/milvus-onprem/cluster.env" \
          || exit 1 ) &
      pids+=($!)
    fi
  done
  for p in "${pids[@]}"; do wait "$p" || failures=$((failures + 1)); done
  (( failures == 0 )) || die "failed to update cluster.env on $failures peer(s)"

  # Step 3: re-render every peer
  info "==> rendering on every peer"
  pids=()
  for ip in ${PEER_IPS//,/ }; do
    if [[ "$ip" == "$LOCAL_IP" ]]; then
      ( cd "$REPO_ROOT" && ./milvus-onprem render >/dev/null ) &
    else
      ( ssh "adeel@$ip" 'cd /home/adeel/milvus-onprem && ./milvus-onprem render >/dev/null' ) &
    fi
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || failures=$((failures + 1)); done
  (( failures == 0 )) || die "render failed on $failures peer(s)"

  # Step 4: force-recreate daemon on every peer in parallel — minimises
  # the dead window where some peers have new + others old.
  info "==> recreating daemon on every peer (parallel)"
  pids=()
  for ip in ${PEER_IPS//,/ }; do
    local node_dir="rendered/$(_rotate_node_name_for "$ip")"
    if [[ "$ip" == "$LOCAL_IP" ]]; then
      ( docker compose -f "$REPO_ROOT/$node_dir/docker-compose.yml" \
          up -d --force-recreate --no-deps control-plane >/dev/null 2>&1 ) &
    else
      ( ssh "adeel@$ip" "cd /home/adeel/milvus-onprem/$node_dir && \
          docker compose up -d --force-recreate --no-deps control-plane" \
          >/dev/null 2>&1 ) &
    fi
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || failures=$((failures + 1)); done
  (( failures == 0 )) || warn "$failures daemon(s) didn't recreate cleanly — verify manually"

  # Step 5: verify every peer accepts the new token
  info "==> verifying every peer accepts the new token (15s grace for daemon startup)"
  sleep 15
  failures=0
  for ip in ${PEER_IPS//,/ }; do
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      -H "Authorization: Bearer $new_token" \
      "http://$ip:${CONTROL_PLANE_PORT:-19500}/leader" 2>/dev/null \
      || echo 000)"
    if [[ "$code" == "200" ]]; then
      info "  $ip: OK"
    else
      err "  $ip: HTTP $code (token rejected)"
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

# Resolve node-N for a given IP from PEER_IPS order. Mirrors role.sh's
# detection without sourcing it (we only need it for path resolution).
_rotate_node_name_for() {
  local target_ip="$1" idx=1
  for ip in ${PEER_IPS//,/ }; do
    [[ "$ip" == "$target_ip" ]] && { echo "node-$idx"; return; }
    idx=$((idx + 1))
  done
  die "_rotate_node_name_for: $target_ip not in PEER_IPS"
}
