# =============================================================================
# lib/cmd_wait.sh — block until the cluster has fully converged
#
# Polls every peer's etcd / minio / milvus until all report healthy, or
# until --timeout-s seconds pass. Used by bootstrap and by operators after
# deploys to confirm the cluster is actually ready before running smoke.
# =============================================================================

[[ -n "${_CMD_WAIT_SH_LOADED:-}" ]] && return 0
_CMD_WAIT_SH_LOADED=1

cmd_wait() {
  local timeout=600    # 10 minutes default
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout-s=*) timeout="${1#*=}"; shift ;;
      --timeout-s)   timeout="$2"; shift 2 ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem wait [--timeout-s N]

Block until every peer reports etcd / MinIO / Milvus / nginx healthy.
Default timeout: 600s. Returns 0 on success, 1 on timeout.
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  env_require
  role_detect
  role_validate_size

  info "waiting up to ${timeout}s for cluster convergence..."
  local i ip start
  start=$(date +%s)

  while (( $(date +%s) - start < timeout )); do
    if _all_peers_healthy; then
      ok "cluster converged in $(( $(date +%s) - start ))s"
      return 0
    fi
    sleep 3
  done

  err "timeout — cluster did not converge in ${timeout}s"
  info "run \`milvus-onprem status\` to see what's not green"
  return 1
}

# Returns 0 only if every peer's services are reachable + healthy.
_all_peers_healthy() {
  local i ip
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    ip="${PEERS_ARR[$i]}"
    etcd_peer_reachable "$ip"  || return 1
    minio_peer_reachable "$ip" || return 1
    timeout 3 bash -c "</dev/tcp/$ip/$MILVUS_PORT" 2>/dev/null || return 1
    timeout 3 bash -c "</dev/tcp/$ip/$NGINX_LB_PORT" 2>/dev/null || return 1
  done
  return 0
}
