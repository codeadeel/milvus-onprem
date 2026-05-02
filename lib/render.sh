# =============================================================================
# lib/render.sh — render templates/$MILVUS_VERSION/*.tpl into
# rendered/$NODE_NAME/* via envsubst.
#
# Computes derived strings (etcd initial-cluster spec, MinIO volumes URL,
# nginx upstream block) before substitution since envsubst cannot iterate.
#
# Expected to be sourced AFTER env_require + role_detect.
# =============================================================================

[[ -n "${_RENDER_SH_LOADED:-}" ]] && return 0
_RENDER_SH_LOADED=1

: "${RENDERED_DIR:=$REPO_ROOT/rendered}"

render_all() {
  local src_dir="$REPO_ROOT/templates/$MILVUS_VERSION"
  local out_dir="$RENDERED_DIR/$NODE_NAME"
  mkdir -p "$out_dir"

  # QA finding F-R4-C.1: refuse to render when this peer's
  # MILVUS_IMAGE_TAG disagrees with the cluster's canonical anchor in
  # etcd (`/cluster/milvus_version`). An operator who manually edits
  # one peer's cluster.env to a different tag used to silently produce
  # a multi-version cluster that fails at runtime in confusing ways.
  # Now caught at render time with an actionable message. Skipped on
  # standalone (no etcd cluster) and during the upgrade flow itself
  # (the upgrade worker writes the new anchor explicitly after success).
  if [[ "${MODE:-standalone}" == "distributed" ]] \
     && [[ -z "${MILVUS_ONPREM_INTERNAL:-}" ]] \
     && docker ps --filter 'name=^milvus-etcd$' --format '{{.Names}}' 2>/dev/null \
        | grep -q .; then
    # Best-effort probe of the canonical version anchor. The etcdctl
    # call is wrapped in `|| true` so a transient etcd-side timeout —
    # most commonly the brief raft-conf-change window right after a
    # member-add, when this peer's daemon re-renders before the new
    # member's etcd has come online — does NOT abort the render. An
    # empty `cluster_tag` from a failed probe simply skips the check
    # this round; the next render (post-handler) will re-probe a
    # healthy etcd and catch any real mismatch.
    local cluster_tag=""
    cluster_tag="$(docker exec milvus-etcd /usr/local/bin/etcdctl \
      --endpoints="http://127.0.0.1:${ETCD_CLIENT_PORT}" \
      get /cluster/milvus_version --print-value-only 2>/dev/null \
      | head -1 || true)"
    if [[ -n "$cluster_tag" && "$cluster_tag" != "$MILVUS_IMAGE_TAG" ]]; then
      die "MILVUS_IMAGE_TAG in cluster.env (\"$MILVUS_IMAGE_TAG\") differs from the cluster's canonical version (\"$cluster_tag\" in etcd /cluster/milvus_version). Manually editing one peer's version is unsupported and produces a multi-version cluster that fails at runtime. Use \`./milvus-onprem upgrade --milvus-version=$cluster_tag\` to roll the cluster forward, or restore cluster.env to match."
    fi
  fi

  _render_compute_derived

  info "rendering templates for $NODE_NAME (Milvus $MILVUS_VERSION) → $out_dir"
  local tpl base
  for tpl in "$src_dir"/*.tpl; do
    [[ -f "$tpl" ]] || continue
    base="$(basename "$tpl" .tpl)"
    # Files starting with _ are fragment templates (e.g. _pulsar-service.yml.tpl).
    # They get inlined into other templates via _render_compute_derived,
    # not rendered as standalone files.
    [[ "$base" == _* ]] && continue
    _render_one "$tpl" "$out_dir/$base"
    info "  rendered $out_dir/$base"
  done
}

_render_one() {
  local src="$1" dst="$2"
  envsubst "$(_render_var_list)" < "$src" > "$dst"
}

# Variables exposed to templates. Explicit list (not $(env)) so templates
# don't accidentally substitute unrelated environment variables.
_render_var_list() {
  local v
  for v in CLUSTER_NAME NODE_NAME NODE_INDEX LOCAL_IP CLUSTER_SIZE \
           PEER_IPS DATA_ROOT MINIO_DRIVES_PER_NODE MQ_TYPE MODE \
           REPO_ROOT HOST_REPO_ROOT \
           MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_REGION \
           MILVUS_VERSION \
           MILVUS_IMAGE_TAG ETCD_IMAGE_TAG MINIO_IMAGE_TAG NGINX_IMAGE_TAG \
           PULSAR_IMAGE_TAG \
           MILVUS_IMAGE_REPO ETCD_IMAGE_REPO MINIO_IMAGE_REPO \
           NGINX_IMAGE_REPO PULSAR_IMAGE_REPO \
           ETCD_CLIENT_PORT ETCD_PEER_PORT \
           MINIO_API_PORT MINIO_CONSOLE_PORT \
           MILVUS_PORT MILVUS_HEALTHZ_PORT NGINX_LB_PORT \
           MILVUS_ROOTCOORD_PORT MILVUS_QUERYNODE_PORT \
           MILVUS_DATANODE_PORT MILVUS_INDEXNODE_PORT \
           MILVUS_STREAMINGNODE_PORT MILVUS_HEALTHCHECK_START_PERIOD_S \
           PULSAR_BROKER_PORT PULSAR_HTTP_PORT \
           ETCD_INITIAL_CLUSTER ETCD_INITIAL_CLUSTER_STATE \
           MINIO_VOLUMES MINIO_VOLUMES_BLOCK MINIO_SERVER_CMD \
           MINIO_HA_POOL_SIZE MINIO_EXTRA_HOSTS_BLOCK \
           NGINX_UPSTREAM_BLOCK \
           MILVUS_ETCD_ENDPOINTS MILVUS_ETCD_ENDPOINTS_YAML \
           PULSAR_HOST PULSAR_HOST_IP PULSAR_SERVICE_BLOCK \
           CLUSTER_TOKEN CONTROL_PLANE_PORT CONTROL_PLANE_IMAGE \
           CONTROL_PLANE_SERVICE_BLOCK MILVUS_SERVICES_BLOCK \
           WATCHDOG_MODE WATCHDOG_INTERVAL_S \
           WATCHDOG_UNHEALTHY_THRESHOLD WATCHDOG_PEER_FAILURE_THRESHOLD \
           WATCHDOG_RESTART_LOOP_WINDOW_S WATCHDOG_RESTART_LOOP_MAX \
           AUTO_MIGRATE_PULSAR_ON_HOST_FAILURE AUTO_MIGRATE_PULSAR_THRESHOLD \
           NGINX_UPSTREAM_MAX_FAILS NGINX_UPSTREAM_FAIL_TIMEOUT_S \
           ROLLING_MINIO_PEER_RPC_TIMEOUT_S ROLLING_MINIO_HEALTHY_WAIT_S; do
    printf '${%s} ' "$v"
  done
}

# -----------------------------------------------------------------------------
# MinIO pool layout helpers. Two paths:
#
#   _render_minio_ha_pool M
#     First M peers form one pool of 4M drives behind `mio-{1...M}`
#     aliases (resolved via extra_hosts). Peers beyond M become
#     additional per-host pools. With M>=3 this layout tolerates
#     loss of any single host because erasure parity spans hosts.
#
#   _render_minio_legacy_pools
#     One pool per peer. No cross-host parity, but join-time
#     scale-out preserves existing pools' on-disk format.json.
#
# Both paths set MINIO_VOLUMES, MINIO_SERVER_CMD, and (for the HA
# path) MINIO_EXTRA_HOSTS_BLOCK.
# -----------------------------------------------------------------------------
_render_minio_ha_pool() {
  local ha_size="$1"
  local drives_per_node="${MINIO_DRIVES_PER_NODE:-4}"

  # Wide pool spanning the first ha_size peers via sequential aliases.
  # The single-arg form `http://mio-{1...M}:PORT/drive{1...K}` is
  # what tells MinIO "treat all of these as one erasure-coded pool"
  # — multiple space-separated args would create multiple pools.
  MINIO_VOLUMES="http://mio-{1...${ha_size}}:${MINIO_API_PORT}/drive{1...${drives_per_node}}"

  # Peers that joined after the initial HA pool was sized are
  # appended as their own per-host pools. Their alias index is the
  # node-N suffix, so e.g. node-4 in a ha_size=3 cluster lands as
  # `http://mio-4:PORT/drive{1...4}` — a new pool, leaving the
  # 12-drive wide pool's format.json untouched.
  local i name idx
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    name="${PEER_NAMES[$i]}"
    idx="${name#node-}"
    if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx > ha_size )); then
      MINIO_VOLUMES+=" http://mio-${idx}:${MINIO_API_PORT}/drive{1...${drives_per_node}}"
    fi
  done
  MINIO_SERVER_CMD="server ${MINIO_VOLUMES} --address :${MINIO_API_PORT} --console-address :${MINIO_CONSOLE_PORT}"

  # extra_hosts block. Maps every alias the wide-pool ellipsis can
  # produce (mio-1..mio-ha_size) plus every joined peer beyond
  # ha_size. Unjoined wide-pool slots get 127.0.0.1 as a sentinel so
  # DNS resolution always succeeds — MinIO then logs "remote
  # disconnected" and waits for the real peer rather than panicking
  # on a `no such host` error. When the peer joins, the topology
  # watcher re-renders with the real IP and the rolling-recreate
  # picks it up.
  declare -A _alias_to_ip=()
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    name="${PEER_NAMES[$i]}"
    idx="${name#node-}"
    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    _alias_to_ip[$idx]="${PEERS_ARR[$i]}"
  done
  MINIO_EXTRA_HOSTS_BLOCK=""
  local k
  for ((k=1; k<=ha_size; k++)); do
    local mapped="${_alias_to_ip[$k]:-127.0.0.1}"
    MINIO_EXTRA_HOSTS_BLOCK+="      - \"mio-${k}:${mapped}\""$'\n'
  done
  for k in "${!_alias_to_ip[@]}"; do
    if (( k > ha_size )); then
      MINIO_EXTRA_HOSTS_BLOCK+="      - \"mio-${k}:${_alias_to_ip[$k]}\""$'\n'
    fi
  done
  if [[ -n "$MINIO_EXTRA_HOSTS_BLOCK" ]]; then
    MINIO_EXTRA_HOSTS_BLOCK="    extra_hosts:"$'\n'"${MINIO_EXTRA_HOSTS_BLOCK%$'\n'}"
  fi
}

_render_minio_legacy_pools() {
  local drives_per_node="${MINIO_DRIVES_PER_NODE:-4}"
  local i ip
  MINIO_VOLUMES=""
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    ip="${PEERS_ARR[$i]}"
    MINIO_VOLUMES+="http://${ip}:${MINIO_API_PORT}/drive{1...${drives_per_node}} "
  done
  MINIO_VOLUMES="${MINIO_VOLUMES% }"
  MINIO_SERVER_CMD="server ${MINIO_VOLUMES} --address :${MINIO_API_PORT} --console-address :${MINIO_CONSOLE_PORT}"
  MINIO_EXTRA_HOSTS_BLOCK=""
}

# -----------------------------------------------------------------------------
# Compute strings that need iteration over PEER_IPS — envsubst can't do
# loops, so we materialise them into single variables here.
# -----------------------------------------------------------------------------
_render_compute_derived() {
  # MinIO extra_hosts is empty for any path that doesn't go through
  # _render_minio_ha_pool. Initialise here so envsubst always has a
  # value (an unset var would leak the literal `${MINIO_EXTRA_HOSTS_BLOCK}`
  # token into the rendered compose).
  MINIO_EXTRA_HOSTS_BLOCK=""

  # etcd --initial-cluster:  node-1=http://10.0.0.10:2380,node-2=...
  ETCD_INITIAL_CLUSTER=""
  local i ip
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    ip="${PEERS_ARR[$i]}"
    ETCD_INITIAL_CLUSTER+="${PEER_NAMES[$i]}=http://${ip}:${ETCD_PEER_PORT},"
  done
  ETCD_INITIAL_CLUSTER="${ETCD_INITIAL_CLUSTER%,}"

  # Milvus etcd.endpoints:  10.0.0.10:2379,10.0.0.11:2379,...
  MILVUS_ETCD_ENDPOINTS=""
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    MILVUS_ETCD_ENDPOINTS+="${PEERS_ARR[$i]}:${ETCD_CLIENT_PORT},"
  done
  MILVUS_ETCD_ENDPOINTS="${MILVUS_ETCD_ENDPOINTS%,}"

  # YAML list form for milvus.yaml — multi-line with leading indentation.
  #     - 10.0.0.10:2379
  #     - 10.0.0.11:2379
  MILVUS_ETCD_ENDPOINTS_YAML=""
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    MILVUS_ETCD_ENDPOINTS_YAML+="    - ${PEERS_ARR[$i]}:${ETCD_CLIENT_PORT}"$'\n'
  done
  MILVUS_ETCD_ENDPOINTS_YAML="${MILVUS_ETCD_ENDPOINTS_YAML%$'\n'}"

  # MinIO server command + bind-mount block. Differs by MODE:
  #
  #   MODE=standalone:  one drive, command points at /data, mounted from
  #                     ${DATA_ROOT}/minio. Single-instance MinIO.
  #
  #   MODE=distributed: each peer contributes 4 drives. The pool layout
  #                     depends on MINIO_HA_POOL_SIZE (set at init via
  #                     `init --ha-cluster-size=N`):
  #
  #     MINIO_HA_POOL_SIZE >= 2 (HA layout):
  #       The first M peers (M = MINIO_HA_POOL_SIZE) form ONE pool of
  #       4M drives, addressed via the `mio-{1...M}` alias ellipsis:
  #
  #         server http://mio-{1...M}:9000/drive{1...4} ...
  #
  #       Aliases resolve to peer IPs via the docker-compose
  #       extra_hosts block rendered in MINIO_EXTRA_HOSTS_BLOCK. With
  #       M>=3 and default MinIO parity (EC:M), losing any single host
  #       leaves the pool readable AND writable — erasure parity spans
  #       hosts, not just drives within a host. Peers that join LATER
  #       (index > M) are appended as additional per-host pools so
  #       their format.json doesn't conflict with the existing wide
  #       pool's on-disk record.
  #
  #     MINIO_HA_POOL_SIZE unset or <=1 (legacy per-host-pool layout):
  #       Each peer is its OWN pool. Joining new peers appends args
  #       without disturbing existing pools' format.json. Survives
  #       grow gracefully but loses host-loss tolerance — a peer
  #       outage takes ListObjects (and therefore the bucket) offline.
  #       This is the path operators get when they don't pre-declare
  #       --ha-cluster-size at init.
  if [[ "${MODE:-standalone}" == "distributed" ]]; then
    MINIO_VOLUMES_BLOCK="      - \${DATA_ROOT}/minio/drive1:/drive1
      - \${DATA_ROOT}/minio/drive2:/drive2
      - \${DATA_ROOT}/minio/drive3:/drive3
      - \${DATA_ROOT}/minio/drive4:/drive4"
    MINIO_VOLUMES_BLOCK="${MINIO_VOLUMES_BLOCK//\$\{DATA_ROOT\}/${DATA_ROOT}}"

    local ha_size="${MINIO_HA_POOL_SIZE:-0}"
    [[ "$ha_size" =~ ^[0-9]+$ ]] || ha_size=0

    if (( ha_size >= 2 )); then
      _render_minio_ha_pool "$ha_size"
    else
      _render_minio_legacy_pools
    fi
  elif (( CLUSTER_SIZE == 1 )); then
    MINIO_VOLUMES_BLOCK="      - ${DATA_ROOT}/minio:/data"
    MINIO_VOLUMES="/data"
    MINIO_SERVER_CMD="server /data --address :${MINIO_API_PORT} --console-address :${MINIO_CONSOLE_PORT}"
  else
    MINIO_VOLUMES_BLOCK="      - ${DATA_ROOT}/minio:/data"
    MINIO_VOLUMES=""
    for ((i=0; i<CLUSTER_SIZE; i++)); do
      MINIO_VOLUMES+="http://${PEERS_ARR[$i]}:${MINIO_API_PORT}/data "
    done
    MINIO_VOLUMES="${MINIO_VOLUMES% }"
    MINIO_SERVER_CMD="server ${MINIO_VOLUMES} --address :${MINIO_API_PORT} --console-address :${MINIO_CONSOLE_PORT}"
  fi

  # nginx LB upstream block — one server line per peer with passive health-check.
  # max_fails=3 fail_timeout=30s marks a backend down after 3 failed
  # requests within 30s; nginx routes around it until it recovers.
  NGINX_UPSTREAM_BLOCK=""
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    NGINX_UPSTREAM_BLOCK+="    server ${PEERS_ARR[$i]}:${MILVUS_PORT} max_fails=${NGINX_UPSTREAM_MAX_FAILS} fail_timeout=${NGINX_UPSTREAM_FAIL_TIMEOUT_S}s;"$'\n'
  done

  # Default the etcd cluster state to "new" — `milvus-onprem rejoin` flips
  # this to "existing" before re-rendering, so a recovering node joins
  # rather than bootstrapping fresh.
  : "${ETCD_INITIAL_CLUSTER_STATE:=new}"

  # PULSAR_SERVICE_BLOCK is the docker-compose service block. It's
  # populated only when this node IS the Pulsar singleton host; other
  # nodes get an empty block and just connect to PULSAR_HOST_IP across
  # the network. PULSAR_HOST_IP itself is resolved earlier in role_detect.
  PULSAR_SERVICE_BLOCK=""
  if [[ "${MQ_TYPE:-}" == "pulsar" && "$NODE_NAME" == "${PULSAR_HOST:-node-1}" ]]; then
    local fragment="$REPO_ROOT/templates/$MILVUS_VERSION/_pulsar-service.yml.tpl"
    if [[ -f "$fragment" ]]; then
      # Pre-render the fragment with the same var list so its ${VAR}s resolve.
      # The result is captured as a literal block that the main compose
      # template's ${PULSAR_SERVICE_BLOCK} will substitute in verbatim.
      # Naming convention: fragments start with `_` so render_all skips them
      # as standalone files.
      PULSAR_SERVICE_BLOCK="$(envsubst "$(_render_var_list)" < "$fragment")"
    fi
  fi

  # CONTROL_PLANE_SERVICE_BLOCK — same pre-render trick for the daemon
  # container. Only included for MODE=distributed; standalone deploys
  # don't run a daemon and would just have an unused service.
  CONTROL_PLANE_SERVICE_BLOCK=""
  if [[ "${MODE:-standalone}" == "distributed" ]]; then
    local cp_fragment="$REPO_ROOT/templates/$MILVUS_VERSION/_daemon-service.yml.tpl"
    if [[ -f "$cp_fragment" ]]; then
      CONTROL_PLANE_SERVICE_BLOCK="$(envsubst "$(_render_var_list)" < "$cp_fragment")"
    fi
  fi

  # MILVUS_SERVICES_BLOCK — chooses standalone (single milvus container)
  # vs cluster mode (per-component containers) based on MODE. 2.5 always
  # ships cluster mode inline in its docker-compose.yml.tpl (it can't
  # run multi-instance standalone HA at all), so this only matters for
  # 2.6.
  MILVUS_SERVICES_BLOCK=""
  local milvus_fragment=""
  if [[ "${MILVUS_VERSION:-}" == "2.6" ]]; then
    if [[ "${MODE:-standalone}" == "distributed" ]]; then
      milvus_fragment="$REPO_ROOT/templates/2.6/_milvus-cluster.yml.tpl"
    else
      milvus_fragment="$REPO_ROOT/templates/2.6/_milvus-standalone.yml.tpl"
    fi
    if [[ -f "$milvus_fragment" ]]; then
      MILVUS_SERVICES_BLOCK="$(envsubst "$(_render_var_list)" < "$milvus_fragment")"
    fi
  fi

  export ETCD_INITIAL_CLUSTER ETCD_INITIAL_CLUSTER_STATE \
         MINIO_VOLUMES MINIO_VOLUMES_BLOCK MINIO_SERVER_CMD \
         MINIO_HA_POOL_SIZE MINIO_EXTRA_HOSTS_BLOCK \
         NGINX_UPSTREAM_BLOCK \
         MILVUS_ETCD_ENDPOINTS MILVUS_ETCD_ENDPOINTS_YAML \
         PULSAR_HOST_IP PULSAR_SERVICE_BLOCK \
         CONTROL_PLANE_SERVICE_BLOCK MILVUS_SERVICES_BLOCK
}
