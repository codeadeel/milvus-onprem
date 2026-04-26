# =============================================================================
# lib/env.sh — load and validate cluster.env
#
# Sources cluster.env into the current shell, applies defaults for unset
# variables, derives MILVUS_VERSION from the image tag, and offers
# env_upsert_kv for writing back persistent state.
#
# Expected to be sourced AFTER lib/log.sh (uses die/info).
# =============================================================================

[[ -n "${_ENV_SH_LOADED:-}" ]] && return 0
_ENV_SH_LOADED=1

# Path to cluster.env. Caller can override with CLUSTER_ENV before sourcing.
: "${CLUSTER_ENV:=$REPO_ROOT/cluster.env}"

# -----------------------------------------------------------------------------
# env_load — source cluster.env if it exists. Returns 1 if missing.
# -----------------------------------------------------------------------------
env_load() {
  [[ -f "$CLUSTER_ENV" ]] || return 1
  set -a
  # shellcheck disable=SC1090
  source "$CLUSTER_ENV"
  set +a
  _env_apply_defaults
  _env_derive_milvus_version
}

# -----------------------------------------------------------------------------
# env_require — load + validate. Dies if cluster.env missing or required
# fields unset. Use in commands that need a working config.
# -----------------------------------------------------------------------------
env_require() {
  env_load || die "cluster.env not found at $CLUSTER_ENV — run \`milvus-onprem init\` first"
  [[ -n "${PEER_IPS:-}" ]]        || die "PEER_IPS not set in cluster.env"
  [[ -n "${CLUSTER_NAME:-}" ]]    || die "CLUSTER_NAME not set in cluster.env"
  [[ -n "${MINIO_SECRET_KEY:-}" ]] || die "MINIO_SECRET_KEY not set in cluster.env"
  _env_validate_milvus_version
}

# -----------------------------------------------------------------------------
# Defaults — applied after sourcing cluster.env. The `:=` form means "leave
# alone if already set," so user values in cluster.env always win.
# -----------------------------------------------------------------------------
_env_apply_defaults() {
  : "${CLUSTER_NAME:=milvus-onprem}"
  : "${MINIO_ACCESS_KEY:=minioadmin}"
  : "${MINIO_REGION:=us-east-1}"
  : "${DATA_ROOT:=/data}"
  : "${MINIO_DRIVES_PER_NODE:=1}"
  : "${MQ_TYPE:=woodpecker}"

  : "${MILVUS_IMAGE_TAG:=v2.6.11}"
  : "${ETCD_IMAGE_TAG:=v3.5.25}"
  : "${MINIO_IMAGE_TAG:=RELEASE.2024-05-28T17-19-04Z}"
  : "${NGINX_IMAGE_TAG:=1.27-alpine}"

  : "${ETCD_CLIENT_PORT:=2379}"
  : "${ETCD_PEER_PORT:=2380}"
  : "${MINIO_API_PORT:=9000}"
  : "${MINIO_CONSOLE_PORT:=9001}"
  : "${MILVUS_PORT:=19530}"
  : "${MILVUS_HEALTHZ_PORT:=9091}"
  : "${NGINX_LB_PORT:=19537}"

  : "${WATCHDOG_MODE:=monitor}"
  : "${WATCHDOG_INTERVAL_S:=5}"
  : "${WATCHDOG_FAILURE_THRESHOLD:=6}"

  : "${PAIR_PORT:=19500}"
}

# -----------------------------------------------------------------------------
# MILVUS_VERSION is derived (not user-set) — extract major.minor from
# MILVUS_IMAGE_TAG. Examples:  v2.6.11 -> 2.6,  v2.5.4 -> 2.5.
# Used to select the right templates/<version>/ directory.
# -----------------------------------------------------------------------------
_env_derive_milvus_version() {
  local tag="${MILVUS_IMAGE_TAG#v}"           # strip leading "v"
  if [[ "$tag" =~ ^([0-9]+)\.([0-9]+) ]]; then
    MILVUS_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    export MILVUS_VERSION
  else
    die "MILVUS_IMAGE_TAG=$MILVUS_IMAGE_TAG doesn't look like a Milvus image tag (expected vN.M.P)"
  fi
}

_env_validate_milvus_version() {
  local tpl_dir="$REPO_ROOT/templates/$MILVUS_VERSION"
  if [[ ! -d "$tpl_dir" ]]; then
    die "Milvus $MILVUS_VERSION not supported in this build — no templates/$MILVUS_VERSION/. See docs/CONFIG.md for the supported-versions matrix."
  fi
}

# -----------------------------------------------------------------------------
# env_upsert_kv — atomically set KEY=VALUE in cluster.env. Updates if the
# key exists, appends if it doesn't. Used by lifecycle code that needs to
# persist updated state (e.g. recording the active node after a recovery).
# -----------------------------------------------------------------------------
env_upsert_kv() {
  local key="$1" value="$2"
  [[ -f "$CLUSTER_ENV" ]] || die "cluster.env missing — cannot upsert $key"
  local tmp
  tmp="$(mktemp "${CLUSTER_ENV}.XXXXXX")"
  if grep -q "^${key}=" "$CLUSTER_ENV"; then
    sed "s|^${key}=.*|${key}=${value}|" "$CLUSTER_ENV" > "$tmp"
  else
    cp "$CLUSTER_ENV" "$tmp"
    echo "${key}=${value}" >> "$tmp"
  fi
  mv "$tmp" "$CLUSTER_ENV"
  chmod 600 "$CLUSTER_ENV"
}
