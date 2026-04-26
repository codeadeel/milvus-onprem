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

# Usage: host_prep <data-root>
host_prep() {
  local data="$1"
  info "host prep: ensuring $data exists with the right ownership"
  sudo mkdir -p "$data/etcd" "$data/minio" "$data/milvus"
  sudo chown -R 1000:1000 "$data/etcd" "$data/minio"
  sudo chown -R "$(id -u):$(id -g)" "$data/milvus"
}
