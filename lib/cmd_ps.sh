# =============================================================================
# lib/cmd_ps.sh — `docker ps` filtered to milvus-* containers
# =============================================================================

[[ -n "${_CMD_PS_SH_LOADED:-}" ]] && return 0
_CMD_PS_SH_LOADED=1

cmd_ps() {
  local all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--all) all=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem ps [-a]

Show running milvus-* containers on this node (just \`docker ps\`
filtered to our names). Pass -a / --all to include exited containers.
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local args=()
  (( all )) && args+=("-a")
  docker ps "${args[@]}" --filter "name=^milvus" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}
