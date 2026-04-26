# =============================================================================
# lib/cmd_urls.sh — print the connection URLs operators need to share
#
# When you stand up a cluster and someone says "great, what's the URL?",
# this is the answer. No more digging through cluster.env to remember
# which port is which.
# =============================================================================

[[ -n "${_CMD_URLS_SH_LOADED:-}" ]] && return 0
_CMD_URLS_SH_LOADED=1

cmd_urls() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        cat <<EOF
Usage: milvus-onprem urls

Print the connection URLs for this cluster — gRPC entry point,
MinIO console, etcd client, healthcheck. Useful for sharing with
the dev team or filing config in tracker.
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  env_require
  role_detect

  echo "Connection points for cluster '$CLUSTER_NAME':"
  echo
  echo "  Milvus (LB, recommended for clients):"
  for ip in "${PEERS_ARR[@]}"; do
    echo "    pymilvus.MilvusClient(uri=\"http://${ip}:${NGINX_LB_PORT}\")"
  done
  echo
  echo "  Milvus (direct gRPC, debug only — bypasses HA):"
  for ip in "${PEERS_ARR[@]}"; do
    echo "    http://${ip}:${MILVUS_PORT}"
  done
  echo
  echo "  MinIO console (browser):"
  for ip in "${PEERS_ARR[@]}"; do
    echo "    http://${ip}:${MINIO_CONSOLE_PORT}"
  done
  echo "    user: ${MINIO_ACCESS_KEY}"
  echo "    pass: (see MINIO_SECRET_KEY in cluster.env)"
  echo
  echo "  MinIO S3 API (for milvus-backup, mc, etc.):"
  for ip in "${PEERS_ARR[@]}"; do
    echo "    http://${ip}:${MINIO_API_PORT}"
  done
  echo
  echo "  etcd (debugging only):"
  for ip in "${PEERS_ARR[@]}"; do
    echo "    http://${ip}:${ETCD_CLIENT_PORT}"
  done
  if [[ "${MQ_TYPE:-}" == "pulsar" ]]; then
    echo
    echo "  Pulsar (singleton on ${PULSAR_HOST}):"
    echo "    pulsar://${PULSAR_HOST_IP}:${PULSAR_BROKER_PORT}"
    echo "    admin http://${PULSAR_HOST_IP}:${PULSAR_HTTP_PORT}"
  fi
}
