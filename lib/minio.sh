# =============================================================================
# lib/minio.sh — distributed MinIO helpers
#
# In distributed mode (CLUSTER_SIZE>=3), MinIO is a single logical cluster
# spread across all N nodes. Erasure-coded across all peers; tolerates
# loss of (N - parity-set/2) drives without data loss.
#
# In standalone mode (CLUSTER_SIZE=1), MinIO is single-drive — no redundancy.
#
# All operations against the local MinIO go through `mc` inside the
# milvus-minio container so we don't need a host-side mc binary.
#
# Expected to be sourced AFTER lib/role.sh (uses LOCAL_IP, MINIO_*).
# =============================================================================

[[ -n "${_MINIO_SH_LOADED:-}" ]] && return 0
_MINIO_SH_LOADED=1


# -----------------------------------------------------------------------------
# Reachability — TCP probes (no auth, no app-level health required).
# -----------------------------------------------------------------------------

# 0 if local MinIO is bound on its API port.
minio_local_reachable() {
  timeout 3 bash -c "</dev/tcp/127.0.0.1/${MINIO_API_PORT}" 2>/dev/null
}

# 0 if peer's MinIO is bound on its API port.
# Usage: minio_peer_reachable <ip>
minio_peer_reachable() {
  local ip="$1"
  timeout 3 bash -c "</dev/tcp/${ip}/${MINIO_API_PORT}" 2>/dev/null
}


# -----------------------------------------------------------------------------
# App-level health (responds to MinIO's /minio/health endpoints).
# -----------------------------------------------------------------------------

# 0 if local MinIO's live-check returns 200. No auth required.
minio_local_healthy() {
  curl -sf --max-time 3 \
    "http://127.0.0.1:${MINIO_API_PORT}/minio/health/live" >/dev/null 2>&1
}

# 0 if local MinIO reports the cluster as healthy.
# Only meaningful in distributed mode; in standalone always returns OK.
minio_cluster_healthy() {
  curl -sf --max-time 5 \
    "http://127.0.0.1:${MINIO_API_PORT}/minio/health/cluster" >/dev/null 2>&1
}


# -----------------------------------------------------------------------------
# mc helper — wraps `docker exec milvus-minio mc` with lazy alias setup.
# -----------------------------------------------------------------------------

# Run an mc command inside the milvus-minio container against the 'local'
# alias. Alias is set lazily on first call (idempotent — re-running is fine).
#
# Named minio_mc to avoid shadowing /usr/bin/mc (Midnight Commander) on the host.
#
# Usage: minio_mc <args...>          # e.g. minio_mc mb local/milvus-bucket
minio_mc() {
  _minio_alias_setup
  docker exec milvus-minio mc "$@"
}

_minio_alias_setup() {
  [[ -n "${_MINIO_ALIAS_SET:-}" ]] && return 0
  docker exec milvus-minio mc alias set local \
    "http://127.0.0.1:${MINIO_API_PORT}" \
    "${MINIO_ACCESS_KEY}" "${MINIO_SECRET_KEY}" \
    >/dev/null 2>&1
  _MINIO_ALIAS_SET=1
}


# -----------------------------------------------------------------------------
# Bucket operations
# -----------------------------------------------------------------------------

# 0 if the bucket exists on local MinIO.
# Usage: minio_bucket_exists <bucket-name>
minio_bucket_exists() {
  local b="$1"
  minio_mc ls "local/${b}/" >/dev/null 2>&1
}

# Create the bucket if it doesn't exist. Idempotent — safe to call
# repeatedly.
#
# Retries through transient docker-exec failures: when a peer joins a
# distributed pool, MinIO containers across all peers restart for the
# ring re-stripe. A bootstrap running on a peer that joined just before
# can race the restart and see "container not running" from
# `docker exec milvus-minio`. We retry with a short backoff so the
# bootstrap doesn't fail spuriously on a join during pool-grow.
#
# Usage: minio_bucket_ensure <bucket-name>
minio_bucket_ensure() {
  local b="$1"
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if minio_bucket_exists "$b"; then
      info "minio: bucket '$b' already exists"
      return 0
    fi
    info "minio: creating bucket '$b' (attempt $attempt)"
    if minio_mc mb "local/${b}" 2>/dev/null; then
      return 0
    fi
    if (( attempt < 6 )); then
      sleep 5
    fi
  done
  die "minio: bucket '$b' could not be created after retries — \
check 'docker logs milvus-minio' on this peer"
}

# Convenience: create the bucket Milvus expects (bucketName in milvus.yaml).
# Called once during bootstrap; safe to re-run.
minio_create_milvus_bucket() {
  minio_bucket_ensure "milvus-bucket"
}


# -----------------------------------------------------------------------------
# Wait helpers — used by lifecycle code that needs MinIO ready before
# proceeding (e.g. "wait for cluster to form before creating the bucket").
# -----------------------------------------------------------------------------

# Wait up to <timeout-s> seconds for local MinIO to become healthy.
# Returns 0 on success, 1 on timeout.
# Usage: minio_wait_local_healthy [timeout-s]   # default 60
minio_wait_local_healthy() {
  local timeout="${1:-60}"
  local i
  for ((i=0; i<timeout; i++)); do
    if minio_local_healthy; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Wait up to <timeout-s> for the distributed cluster to form (all peers
# reachable + cluster-health endpoint OK). Standalone mode returns 0
# as soon as local MinIO is healthy.
# Usage: minio_wait_cluster_healthy [timeout-s]   # default 120
minio_wait_cluster_healthy() {
  local timeout="${1:-120}"
  local i
  for ((i=0; i<timeout; i++)); do
    if minio_cluster_healthy; then
      return 0
    fi
    sleep 1
  done
  return 1
}
