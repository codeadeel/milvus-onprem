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

  # Teardown intentionally tolerates a broken or missing cluster.env: an
  # operator who tripped a validation rule (e.g. 2.6/pulsar) needs a way
  # out, and teardown is the escape hatch. We load if possible — to know
  # DATA_ROOT and run dc down — but skip the strict validation that
  # env_require imposes. If even loading fails, fall back to defaults.
  if env_load 2>/dev/null; then
    role_detect 2>/dev/null || true
  else
    warn "cluster.env missing or unloadable — proceeding with defaults"
    : "${DATA_ROOT:=/data}"
  fi

  warn "teardown level: $level"
  case "$level" in
    data) warn "  will stop containers and wipe ${DATA_ROOT}/{etcd,minio,milvus,pulsar}" ;;
    full) warn "  will stop containers, wipe data, AND remove cluster.env + rendered/" ;;
  esac

  if (( ! force )); then
    read -r -p "Type 'yes' to confirm: " ans
    [[ "$ans" == "yes" ]] || { info "aborted"; return 1; }
  fi

  info "stopping containers"
  # Use `dc down` only when the rendered compose file actually exists.
  # `dc` itself calls `die` (exit 1) on a missing compose, which would
  # abort teardown before it gets to wipe data / cluster.env. Teardown
  # must remain a usable escape hatch on half-initialised nodes (e.g. a
  # `join` that wrote cluster.env but never rendered), so we fall through
  # to a name-based docker rm sweep when there's no compose to use.
  local compose_file="${RENDERED_DIR:-$REPO_ROOT/rendered}/${NODE_NAME:-}/docker-compose.yml"
  if [[ -n "${NODE_NAME:-}" && -f "$compose_file" ]]; then
    dc down --remove-orphans --volumes 2>/dev/null || true
  fi
  docker rm -f milvus milvus-nginx milvus-minio milvus-etcd milvus-pulsar \
    milvus-mixcoord milvus-proxy milvus-querynode milvus-datanode milvus-indexnode \
    milvus-streamingnode milvus-onprem-cp \
    2>/dev/null || true

  info "wiping data dirs under $DATA_ROOT"
  sudo rm -rf "$DATA_ROOT/etcd" "$DATA_ROOT/minio" "$DATA_ROOT/milvus" "$DATA_ROOT/pulsar"

  if [[ "$level" == "full" ]]; then
    info "removing cluster.env and rendered/"
    rm -f "${CLUSTER_ENV:-$REPO_ROOT/cluster.env}"
    rm -rf "${RENDERED_DIR:-$REPO_ROOT/rendered}"
  fi

  ok "teardown complete (level: $level)"
}
