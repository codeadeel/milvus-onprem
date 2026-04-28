# =============================================================================
# lib/host.sh — host-side filesystem prep
#
# Shared between cmd_init (first-run setup) and cmd_join (post-fetch setup).
# Ensures DATA_ROOT exists with the right ownership for our containers:
#   etcd + minio run as UID 1000 inside their images
#   milvus uses the host operator user
# =============================================================================

[[ -n "${_HOST_SH_LOADED:-}" ]] && return 0
_HOST_SH_LOADED=1

# Usage: host_prep <data-root> [<mode>]
#   mode = standalone (default) — single MinIO drive at <data>/minio
#   mode = distributed         — four MinIO drives at <data>/minio/drive{1..4}
#                                so MinIO can satisfy its distributed-mode
#                                minimum even at N=1 nodes
host_prep() {
  local data="$1"
  local mode="${2:-standalone}"
  info "host prep ($mode): ensuring $data exists with the right ownership"
  sudo mkdir -p "$data/etcd" "$data/milvus" "$data/pulsar"
  if [[ "$mode" == "distributed" ]]; then
    sudo mkdir -p \
      "$data/minio" \
      "$data/minio/drive1" "$data/minio/drive2" \
      "$data/minio/drive3" "$data/minio/drive4"
    sudo chown -R 1000:1000 "$data/etcd" "$data/minio"
  else
    sudo mkdir -p "$data/minio"
    sudo chown -R 1000:1000 "$data/etcd" "$data/minio"
  fi
  sudo chown -R 10000:10000 "$data/pulsar"
  sudo chown -R "$(id -u):$(id -g)" "$data/milvus"
}
