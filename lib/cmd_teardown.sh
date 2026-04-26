# =============================================================================
# lib/cmd_teardown.sh — destructive: stop containers AND wipe data dirs
#
# Three levels:
#   plain               stop+rm containers, keep data           (= cmd_down)
#   --data              also wipe ${DATA_ROOT}/{etcd,minio,milvus}
#   --full              also remove cluster.env + rendered/    ← FULL RESET
#
# Always prompts unless --force is given.
# =============================================================================

[[ -n "${_CMD_TEARDOWN_SH_LOADED:-}" ]] && return 0
_CMD_TEARDOWN_SH_LOADED=1

cmd_teardown() {
  local level="data"   # default level
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --data)   level="data"; shift ;;
      --full)   level="full"; shift ;;
      --force)  force=1;      shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem teardown [--data | --full] [--force]

  --data    (default) Stop containers + wipe data dirs.
  --full    Also remove cluster.env and rendered/.
  --force   Skip confirmation prompt.
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  env_require
  role_detect

  warn "teardown level: $level"
  case "$level" in
    data) warn "  will stop containers and wipe ${DATA_ROOT}/{etcd,minio,milvus}" ;;
    full) warn "  will stop containers, wipe data, AND remove cluster.env + rendered/" ;;
  esac

  if (( ! force )); then
    read -r -p "Type 'yes' to confirm: " ans
    [[ "$ans" == "yes" ]] || { info "aborted"; return 1; }
  fi

  info "stopping containers"
  dc down --remove-orphans --volumes || true

  info "wiping data dirs under $DATA_ROOT"
  sudo rm -rf "$DATA_ROOT/etcd" "$DATA_ROOT/minio" "$DATA_ROOT/milvus"

  if [[ "$level" == "full" ]]; then
    info "removing cluster.env and rendered/"
    rm -f "$CLUSTER_ENV"
    rm -rf "${RENDERED_DIR:-$REPO_ROOT/rendered}"
  fi

  ok "teardown complete (level: $level)"
}
