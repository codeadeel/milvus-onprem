# =============================================================================
# lib/cmd_render.sh — re-render templates/$MILVUS_VERSION/*.tpl into
# rendered/$NODE_NAME/. Run after editing cluster.env.
# =============================================================================

[[ -n "${_CMD_RENDER_SH_LOADED:-}" ]] && return 0
_CMD_RENDER_SH_LOADED=1

cmd_render() {
  env_require
  role_detect
  role_validate_size
  render_all
  ok "rendered ${RENDERED_DIR:-$REPO_ROOT/rendered}/$NODE_NAME/"
  info "next: \`milvus-onprem up\` (or \`milvus-onprem bootstrap\` for full deploy)"
}
