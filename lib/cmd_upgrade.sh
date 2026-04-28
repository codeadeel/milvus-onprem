# =============================================================================
# lib/cmd_upgrade.sh — rolling Milvus version upgrade via the daemon.
#
#   ./milvus-onprem upgrade --milvus-version=vX.Y.Z [--force]
#
# Distributed mode only. The daemon's version-upgrade worker pulls the
# new image on every peer in turn, edits cluster.env, re-renders, and
# `docker compose up -d --force-recreate` the milvus container(s) one
# peer at a time. Aborts on first peer failure — the cluster lands in
# a mixed-version state and the operator decides what to do next.
#
# Refuses cross-major-minor changes (e.g. v2.5.4 -> v2.6.x) — those
# need backup -> teardown -> re-init at the new version, not in-place
# restart. Worker enforces this; CLI flags it early.
# =============================================================================

[[ -n "${_CMD_UPGRADE_SH_LOADED:-}" ]] && return 0
_CMD_UPGRADE_SH_LOADED=1

cmd_upgrade() {
  local target=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --milvus-version=*) target="${1#*=}"; shift ;;
      --milvus-version)   target="$2"; shift 2 ;;
      --force)            force=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem upgrade --milvus-version=vX.Y.Z [--force]

Roll the cluster to a new Milvus image tag, peer-by-peer. The daemon
on each peer:
  1. Pulls the new image so the recreate is fast.
  2. Updates MILVUS_IMAGE_TAG in that peer's cluster.env.
  3. Re-renders the local templates.
  4. \`docker compose up -d --force-recreate\` the milvus services.
  5. Waits for the milvus gRPC port to come back up before moving on.

The leader is upgraded first (so any breakage hits the orchestrator
first), then each follower in node-N order. Aborts on first failure.

Constraints:
  - MODE=distributed only. Standalone deploys edit cluster.env +
    \`milvus-onprem up\` directly.
  - Same major.minor only. v2.5.4 -> v2.5.5 OK; v2.5.4 -> v2.6.x is
    refused (cross-major needs backup + re-init, not restart).
EOF
        return 0
        ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  [[ -n "$target" ]] || die "--milvus-version is required (e.g. --milvus-version=v2.5.5)"

  env_require
  role_detect

  if [[ "${MODE:-standalone}" != "distributed" ]]; then
    die "upgrade requires MODE=distributed (standalone: edit cluster.env + 'up')"
  fi

  if (( ! force )); then
    if [[ -t 0 ]]; then
      echo ""
      echo "About to roll the cluster from ${MILVUS_IMAGE_TAG} → ${target}."
      echo "Each peer's milvus container(s) will be recreated in turn."
      echo "Brief per-peer downtime is expected (~30-90s)."
      echo ""
      read -r -p "Type 'yes' to proceed: " ans
      [[ "$ans" == "yes" ]] || { info "aborted"; return 1; }
    else
      die "non-interactive use requires --force"
    fi
  fi

  _upgrade_via_daemon "$target"
}

# POST a version-upgrade job and poll until done.
_upgrade_via_daemon() {
  local target="$1"
  local cp_url="http://127.0.0.1:${CONTROL_PLANE_PORT:-19500}"
  local token="${CLUSTER_TOKEN:-}"
  [[ -n "$token" ]] || die "CLUSTER_TOKEN missing in cluster.env"

  local body
  body=$(python3 -c "
import json
print(json.dumps({'type':'version-upgrade','params':{'milvus_version':'$target'}}))
")

  info "==> POST /jobs (version-upgrade -> $target) on $cp_url"
  local resp
  resp=$(curl -fsS --location-trusted --max-time 30 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" "$cp_url/jobs") \
    || die "POST /jobs failed — daemon unreachable?"
  local job_id
  job_id=$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  ok "job created: $job_id"
  _poll_job "$job_id" "$cp_url" "$token"
}
