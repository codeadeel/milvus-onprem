# =============================================================================
# lib/cmd_down.sh — stop and remove all containers on this node
#
# Stops + removes containers. Does NOT delete data dirs (etcd/minio/milvus
# under DATA_ROOT) — use `milvus-onprem teardown` for the destructive option.
# =============================================================================

[[ -n "${_CMD_DOWN_SH_LOADED:-}" ]] && return 0
_CMD_DOWN_SH_LOADED=1

cmd_down() {
  env_require
  role_detect
  info "stopping containers for $NODE_NAME"
  dc down --remove-orphans || true
  ok "containers stopped. Data preserved under $DATA_ROOT/."
}
