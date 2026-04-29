# =============================================================================
# lib/cmd_logs.sh — `docker logs` for one of the milvus-* containers
#
# Saves operators from remembering whether it's milvus, milvus-etcd,
# or milvus-pulsar -- accept the short name (etcd, minio, milvus,
# nginx, pulsar) and map to the container.
# =============================================================================

[[ -n "${_CMD_LOGS_SH_LOADED:-}" ]] && return 0
_CMD_LOGS_SH_LOADED=1

cmd_logs() {
  local component=""
  local tail=100
  local follow=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tail=*) tail="${1#*=}"; shift ;;
      --tail)   tail="$2"; shift 2 ;;
      -f|--follow) follow=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem logs <component> [--tail=N] [-f]

Show container logs for one of:

  etcd          -> milvus-etcd
  minio         -> milvus-minio
  milvus        -> milvus                (2.6 standalone only — single container)
  mixcoord      -> milvus-mixcoord       (cluster mode — all 4 coordinators)
  proxy         -> milvus-proxy          (cluster mode — gRPC entry on :19530)
  querynode     -> milvus-querynode      (cluster mode)
  datanode      -> milvus-datanode       (cluster mode)
  indexnode     -> milvus-indexnode      (cluster mode)
  streamingnode -> milvus-streamingnode  (2.6 distributed only — woodpecker WAL)
  nginx         -> milvus-nginx
  pulsar        -> milvus-pulsar         (only on the PULSAR_HOST node, 2.5)
  daemon        -> milvus-onprem-cp      (control-plane daemon, distributed only)

  --tail=N      Show the last N lines (default: 100). N=0 means all.
  -f, --follow  Stream logs (Ctrl-C to stop).
EOF
        return 0
        ;;
      -*) die "unknown flag: $1" ;;
      *)  [[ -n "$component" ]] && die "only one component at a time"
          component="$1"; shift ;;
    esac
  done

  [[ -n "$component" ]] || die "missing component. Try \`milvus-onprem logs --help\`."

  local container
  case "$component" in
    etcd)          container="milvus-etcd" ;;
    minio)         container="milvus-minio" ;;
    milvus)        container="milvus" ;;
    mixcoord)      container="milvus-mixcoord" ;;
    proxy)         container="milvus-proxy" ;;
    querynode)     container="milvus-querynode" ;;
    datanode)      container="milvus-datanode" ;;
    indexnode)     container="milvus-indexnode" ;;
    streamingnode) container="milvus-streamingnode" ;;
    nginx)         container="milvus-nginx" ;;
    pulsar)        container="milvus-pulsar" ;;
    daemon|cp|control-plane) container="milvus-onprem-cp" ;;
    *)             die "unknown component '$component'. Try \`milvus-onprem logs --help\` for the list." ;;
  esac

  if ! docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
    die "container '$container' not present on this node. Try \`milvus-onprem ps\` to see what is."
  fi

  local args=()
  if [[ "$tail" == "0" ]]; then
    args+=()
  else
    args+=("--tail" "$tail")
  fi
  (( follow )) && args+=("--follow")

  docker logs "${args[@]}" "$container"
}
