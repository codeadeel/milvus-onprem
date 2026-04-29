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
  _env_apply_version_defaults
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
  # CLUSTER_TOKEN is required only in distributed mode — the daemon uses
  # it as the shared bearer-token. Standalone deploys don't run a daemon.
  if [[ "${MODE:-standalone}" == "distributed" && -z "${CLUSTER_TOKEN:-}" ]]; then
    die "CLUSTER_TOKEN not set in cluster.env (required for MODE=distributed)"
  fi
  _env_validate_milvus_version
  _env_validate_mq_type
  _env_validate_topology
}

# -----------------------------------------------------------------------------
# Defaults — applied after sourcing cluster.env. The `:=` form means "leave
# alone if already set," so user values in cluster.env always win.
# `set -a` ensures the defaults are exported to envsubst subprocesses.
# -----------------------------------------------------------------------------
_env_apply_defaults() {
  set -a
  : "${CLUSTER_NAME:=milvus-onprem}"
  : "${MINIO_ACCESS_KEY:=minioadmin}"
  : "${MINIO_REGION:=us-east-1}"
  : "${DATA_ROOT:=/data}"
  # MODE selects the deploy shape:
  #   standalone   — single-VM, single-instance services, no daemon
  #   distributed  — HA-ready: cluster-mode services from N=1, control-plane
  #                  daemon, MinIO with 4 drives per node ready to grow
  : "${MODE:=standalone}"
  # Per-mode default drive count on each node's MinIO. Distributed needs >=4
  # to satisfy MinIO's distributed-mode minimum even at N=1; standalone
  # stays at 1 drive (single-instance MinIO).
  if [[ "$MODE" == "distributed" ]]; then
    : "${MINIO_DRIVES_PER_NODE:=4}"
  else
    : "${MINIO_DRIVES_PER_NODE:=1}"
  fi
  # Control-plane daemon listen port (FastAPI + leader election).
  : "${CONTROL_PLANE_PORT:=19500}"
  # Container image for the daemon. Built locally on each node by `init`.
  : "${CONTROL_PLANE_IMAGE:=milvus-onprem-cp:dev}"
  # MQ_TYPE default is version-dependent — set after _env_derive_milvus_version.

  : "${MILVUS_IMAGE_TAG:=v2.6.11}"
  : "${ETCD_IMAGE_TAG:=v3.5.25}"
  : "${MINIO_IMAGE_TAG:=RELEASE.2024-05-28T17-19-04Z}"
  : "${NGINX_IMAGE_TAG:=1.27-alpine}"
  : "${PULSAR_IMAGE_TAG:=3.0.0}"

  # Image repository overrides — set these in cluster.env to point at an
  # internal registry mirror (air-gapped / restricted egress / corporate
  # proxy). Defaults are the upstream public refs.
  : "${MILVUS_IMAGE_REPO:=milvusdb/milvus}"
  : "${ETCD_IMAGE_REPO:=quay.io/coreos/etcd}"
  : "${MINIO_IMAGE_REPO:=minio/minio}"
  : "${NGINX_IMAGE_REPO:=nginx}"
  : "${PULSAR_IMAGE_REPO:=apachepulsar/pulsar}"

  : "${ETCD_CLIENT_PORT:=2379}"
  : "${ETCD_PEER_PORT:=2380}"
  : "${MINIO_API_PORT:=9000}"
  : "${MINIO_CONSOLE_PORT:=9001}"
  : "${MILVUS_PORT:=19530}"
  : "${MILVUS_HEALTHZ_PORT:=9091}"
  # Per-component gRPC ports — only Milvus 2.5's coord-mode-cluster
  # topology binds these (each worker is its own container in 2.5).
  # Used as TCP probe targets for the per-component healthchecks in
  # templates/2.5/docker-compose.yml.tpl. Mixcoord probes 53100
  # (rootcoord) — bound by both leader and standby, so it's a true
  # "process is alive" signal that doesn't trip on standby instances.
  # MILVUS_ROOTCOORD_PORT default is version-conditional — see
  # _env_apply_version_defaults() below. 2.5 → 53100, 2.6 → 22125.
  : "${MILVUS_QUERYNODE_PORT:=21123}"
  : "${MILVUS_DATANODE_PORT:=21124}"
  : "${MILVUS_INDEXNODE_PORT:=21121}"
  # Milvus 2.6 streamingnode — handles the embedded Woodpecker WAL.
  # Used as the healthcheck TCP probe target in 2.6's cluster mode.
  : "${MILVUS_STREAMINGNODE_PORT:=22222}"
  # Healthcheck start_period for the milvus services. Joining peers
  # take a while to converge under shared etcd (rootcoord election +
  # session.ttl + first MinIO read of WAL state). Without a generous
  # start_period the watchdog auto-restarts the container before it
  # finishes initialising. Set conservatively for distributed deploys.
  : "${MILVUS_HEALTHCHECK_START_PERIOD_S:=300}"
  : "${NGINX_LB_PORT:=19537}"
  : "${PULSAR_BROKER_PORT:=6650}"
  : "${PULSAR_HTTP_PORT:=8080}"

  # Watchdog (control-plane daemon, distributed mode only).
  # Defaults match daemon/config.py so an unset cluster.env behaves
  # identically with or without the env-var passthrough.
  : "${WATCHDOG_MODE:=auto}"
  : "${WATCHDOG_INTERVAL_S:=10}"
  : "${WATCHDOG_UNHEALTHY_THRESHOLD:=3}"
  : "${WATCHDOG_PEER_FAILURE_THRESHOLD:=6}"
  : "${WATCHDOG_RESTART_LOOP_WINDOW_S:=300}"
  : "${WATCHDOG_RESTART_LOOP_MAX:=3}"

  # nginx upstream tunings — exposed so operators on flaky LANs / WAN
  # can lift them without editing the template. Defaults are the
  # values we shipped originally (max_fails=3, fail_timeout=30s).
  : "${NGINX_UPSTREAM_MAX_FAILS:=3}"
  : "${NGINX_UPSTREAM_FAIL_TIMEOUT_S:=30}"

  # Rolling MinIO recreate (handlers._rolling_minio_recreate):
  # per-peer RPC timeout (seconds), and per-container healthy-wait
  # ceiling. Defaults match the original code; tighten if your
  # MinIO comes back faster, lift on slow disks.
  : "${ROLLING_MINIO_PEER_RPC_TIMEOUT_S:=180}"
  : "${ROLLING_MINIO_HEALTHY_WAIT_S:=90}"

  : "${PAIR_PORT:=19500}"

  # Singleton Pulsar host (only used for MQ_TYPE=pulsar deploys, e.g. 2.5).
  : "${PULSAR_HOST:=node-1}"
  set +a
}

# Apply defaults that depend on MILVUS_VERSION. Called after
# _env_derive_milvus_version so we know the version.
_env_apply_version_defaults() {
  set -a
  if [[ -z "${MQ_TYPE:-}" ]]; then
    case "$MILVUS_VERSION" in
      2.5) MQ_TYPE="pulsar" ;;       # 2.5 has no Woodpecker
      2.6) MQ_TYPE="woodpecker" ;;   # 2.6's embedded WAL
      *)   MQ_TYPE="woodpecker" ;;   # safe default for unknown versions
    esac
  fi
  # rootCoord gRPC port — bound by the (mix)coord process. Used as
  # the TCP-probe target for the cluster-mode mixcoord healthcheck.
  # 2.5 binary defaults to 53100; 2.6 binary defaults to 22125. We
  # set it here so the same MILVUS_ROOTCOORD_PORT placeholder works
  # in both templates without per-version edits.
  if [[ -z "${MILVUS_ROOTCOORD_PORT:-}" ]]; then
    case "$MILVUS_VERSION" in
      2.5) MILVUS_ROOTCOORD_PORT="53100" ;;
      2.6) MILVUS_ROOTCOORD_PORT="22125" ;;
      *)   MILVUS_ROOTCOORD_PORT="22125" ;;
    esac
  fi
  set +a
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

# Reject MQ_TYPE values that don't make sense for the Milvus version.
# 2.5: must be pulsar (no Woodpecker yet).
# 2.6: woodpecker only — the 2.6/pulsar trapdoor was open in env.sh but
#      templates/2.6/ has no pulsar service block, so bootstrap died at
#      Stage 3a with "no such service: pulsar". Closing it explicitly
#      here so operators get a useful error at init/load time, not a
#      cryptic compose error halfway through bootstrap.
_env_validate_mq_type() {
  case "$MILVUS_VERSION/$MQ_TYPE" in
    2.6/woodpecker) ;;
    2.5/pulsar) ;;
    2.6/pulsar) die "Milvus 2.6 + MQ_TYPE=pulsar is not wired up in this build — templates/2.6/ has no Pulsar service block. Use MQ_TYPE=woodpecker on 2.6 (the embedded WAL is the recommended path); to run Pulsar, use Milvus 2.5 (MILVUS_IMAGE_TAG=v2.5.x)." ;;
    2.5/woodpecker) die "Milvus 2.5 doesn't support Woodpecker (Woodpecker was introduced in 2.6). Set MQ_TYPE=pulsar in cluster.env." ;;
    *) die "unsupported (MILVUS_VERSION=$MILVUS_VERSION, MQ_TYPE=$MQ_TYPE) combination — see docs/CONFIG.md" ;;
  esac
}

# Reject (MILVUS_VERSION, CLUSTER_SIZE) combinations that don't actually
# work in this build. Currently: nothing — 2.5 multi-node now works via
# coord-mode-cluster topology (mixcoord + proxy + querynode + datanode +
# indexnode per node, each leader-elected through etcd). Kept as a stub
# so future incompatible combinations have a clear home for the refusal.
_env_validate_topology() {
  return 0
}

# -----------------------------------------------------------------------------
# env_upsert_kv — atomically set KEY=VALUE in cluster.env. Updates if the
# key exists, appends if it doesn't. Used by lifecycle code that needs to
# persist updated state (e.g. recording the active node after a recovery).
# -----------------------------------------------------------------------------
env_upsert_kv() {
  local key="$1" value="$2"
  [[ -f "$CLUSTER_ENV" ]] || die "cluster.env missing — cannot upsert $key"
  # Defensive: ensure cluster.env ends with a newline before any append-
  # path runs. Without this, if a previous writer didn't terminate the
  # last line cleanly, `echo "KEY=VAL" >>` lands on the previous line
  # and mashes two settings together (e.g. DATA_ROOT=/dataHOST_REPO_ROOT=…).
  if [[ -s "$CLUSTER_ENV" ]] && [[ "$(tail -c 1 "$CLUSTER_ENV")" != $'\n' ]]; then
    printf '\n' >> "$CLUSTER_ENV"
  fi
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
