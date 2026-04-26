# =============================================================================
# lib/dc.sh — `docker compose` wrapper for this node's rendered compose file
#
# Every cmd_* that touches containers goes through `dc`. Centralising the
# compose-file path here means callers don't have to reconstruct it.
# =============================================================================

[[ -n "${_DC_SH_LOADED:-}" ]] && return 0
_DC_SH_LOADED=1

# Run `docker compose` with this node's rendered compose file.
# Usage: dc <command...>     # e.g. dc up -d, dc down --remove-orphans, dc ps
dc() {
  local compose_file="${RENDERED_DIR:-$REPO_ROOT/rendered}/$NODE_NAME/docker-compose.yml"
  [[ -f "$compose_file" ]] || \
    die "compose file not found at $compose_file — run \`milvus-onprem render\` first"
  docker compose -f "$compose_file" --project-name "$NODE_NAME" "$@"
}
