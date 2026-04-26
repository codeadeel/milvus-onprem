# =============================================================================
# lib/cmd_status.sh — show this node + cluster health
#
# Three sections:
#   header     — cluster name, this node's role, MILVUS_VERSION
#   containers — `docker ps` filtered to milvus-* on this node
#   reachability — local services + every peer's etcd/minio/milvus
# =============================================================================

[[ -n "${_CMD_STATUS_SH_LOADED:-}" ]] && return 0
_CMD_STATUS_SH_LOADED=1

cmd_status() {
  env_require
  role_detect
  role_validate_size

  _status_header
  _status_containers
  _status_local_reachability
  _status_peer_reachability
}

_status_header() {
  echo "=============================================================="
  echo "  cluster:  $CLUSTER_NAME"
  echo "  this node: $NODE_NAME (index=$NODE_INDEX, ip=$LOCAL_IP)"
  echo "  cluster size: $CLUSTER_SIZE  (peers: $PEER_IPS)"
  echo "  Milvus:   $MILVUS_IMAGE_TAG  (version=$MILVUS_VERSION, mq=$MQ_TYPE)"
  echo "=============================================================="
}

_status_containers() {
  echo
  echo "==> containers on $NODE_NAME"
  # Use docker's --filter rather than grep: the table format pads names
  # with trailing spaces, so a regex like `milvus$` never matches the
  # lone `milvus` container, only `milvus-*`. --filter "name=^milvus"
  # matches `milvus`, `milvus-etcd`, `milvus-minio`, `milvus-nginx`,
  # `milvus-pulsar` cleanly.
  local out
  out=$(docker ps -a --filter 'name=^milvus' \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}')
  if [[ -n "$out" && $(printf '%s\n' "$out" | wc -l) -gt 1 ]]; then
    printf '%s\n' "$out"
  else
    warn "  no milvus-* containers found — run \`milvus-onprem up\`"
  fi
}

_status_local_reachability() {
  echo
  echo "==> local reachability"
  _probe "etcd@127.0.0.1"  etcd_local_health
  _probe "minio@127.0.0.1" minio_local_healthy
  _probe "milvus@127.0.0.1" _milvus_local_health
  _probe "nginx-lb@127.0.0.1" _nginx_local_reachable
}

_status_peer_reachability() {
  echo
  echo "==> peer reachability"
  local i ip
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    ip="${PEERS_ARR[$i]}"
    [[ "$ip" == "$LOCAL_IP" ]] && continue   # skip self
    _probe "etcd@$ip"   etcd_peer_reachable "$ip"
    _probe "minio@$ip"  minio_peer_reachable "$ip"
    _probe "milvus@$ip" _milvus_peer_reachable "$ip"
  done
}

# Run a check function and print [OK] / [FAIL] + label.
_probe() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  [OK]   %s\n' "$label"
  else
    printf '  [FAIL] %s\n' "$label"
  fi
}

# Local Milvus healthcheck — proxy/healthz on localhost.
_milvus_local_health() {
  curl -sf --max-time 3 "http://127.0.0.1:${MILVUS_HEALTHZ_PORT}/healthz" >/dev/null
}

_milvus_peer_reachable() {
  local ip="$1"
  timeout 3 bash -c "</dev/tcp/$ip/$MILVUS_PORT" 2>/dev/null
}

_nginx_local_reachable() {
  timeout 3 bash -c "</dev/tcp/127.0.0.1/$NGINX_LB_PORT" 2>/dev/null
}
