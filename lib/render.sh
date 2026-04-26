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

  _render_compute_derived

  info "rendering templates for $NODE_NAME (Milvus $MILVUS_VERSION) → $out_dir"
  local tpl base
  for tpl in "$src_dir"/*.tpl; do
    [[ -f "$tpl" ]] || continue
    base="$(basename "$tpl" .tpl)"
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
           PEER_IPS DATA_ROOT MINIO_DRIVES_PER_NODE MQ_TYPE \
           MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_REGION \
           MILVUS_VERSION \
           MILVUS_IMAGE_TAG ETCD_IMAGE_TAG MINIO_IMAGE_TAG NGINX_IMAGE_TAG \
           ETCD_CLIENT_PORT ETCD_PEER_PORT \
           MINIO_API_PORT MINIO_CONSOLE_PORT \
           MILVUS_PORT MILVUS_HEALTHZ_PORT NGINX_LB_PORT \
           ETCD_INITIAL_CLUSTER ETCD_INITIAL_CLUSTER_STATE \
           MINIO_VOLUMES MINIO_SERVER_CMD \
           NGINX_UPSTREAM_BLOCK \
           MILVUS_ETCD_ENDPOINTS MILVUS_ETCD_ENDPOINTS_YAML; do
    printf '${%s} ' "$v"
  done
}

# -----------------------------------------------------------------------------
# Compute strings that need iteration over PEER_IPS — envsubst can't do
# loops, so we materialise them into single variables here.
# -----------------------------------------------------------------------------
_render_compute_derived() {
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

  # MinIO server command — differs for N=1 (single-drive) vs N>=3 (distributed).
  if (( CLUSTER_SIZE == 1 )); then
    MINIO_VOLUMES="/data"
    MINIO_SERVER_CMD="server /data --address :${MINIO_API_PORT} --console-address :${MINIO_CONSOLE_PORT}"
  else
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
    NGINX_UPSTREAM_BLOCK+="    server ${PEERS_ARR[$i]}:${MILVUS_PORT} max_fails=3 fail_timeout=30s;"$'\n'
  done

  # Default the etcd cluster state to "new" — `milvus-onprem rejoin` flips
  # this to "existing" before re-rendering, so a recovering node joins
  # rather than bootstrapping fresh.
  : "${ETCD_INITIAL_CLUSTER_STATE:=new}"

  export ETCD_INITIAL_CLUSTER ETCD_INITIAL_CLUSTER_STATE \
         MINIO_VOLUMES MINIO_SERVER_CMD \
         NGINX_UPSTREAM_BLOCK \
         MILVUS_ETCD_ENDPOINTS MILVUS_ETCD_ENDPOINTS_YAML
}
