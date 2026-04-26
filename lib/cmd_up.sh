# =============================================================================
# lib/cmd_up.sh — start all containers on this node via docker compose
#
# Idempotent: re-running just makes sure everything's up. Doesn't wait for
# services to become healthy — use `milvus-onprem wait` for that, or use
# `milvus-onprem bootstrap` which does both.
# =============================================================================

[[ -n "${_CMD_UP_SH_LOADED:-}" ]] && return 0
_CMD_UP_SH_LOADED=1

cmd_up() {
  env_require
  role_detect
  role_validate_size
  info "starting containers for $NODE_NAME"
  dc up -d
  ok "containers started. Verify with \`milvus-onprem status\` or wait for convergence with \`milvus-onprem wait\`."
}
