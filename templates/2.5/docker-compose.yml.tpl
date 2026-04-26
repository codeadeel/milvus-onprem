# =============================================================================
# docker-compose.yml — generated for ${NODE_NAME} (Milvus ${MILVUS_VERSION})
#
# DO NOT EDIT BY HAND. Re-render with `milvus-onprem render` after changes
# to cluster.env. Source: templates/${MILVUS_VERSION}/docker-compose.yml.tpl
#
# Key difference from 2.6: this version uses Pulsar (no Woodpecker yet).
# Pulsar runs as a singleton on PULSAR_HOST (default: node-1). The
# pulsar service block is conditionally inlined by lib/render.sh —
# only the host node's compose file actually contains it; others get
# an empty block and just connect to Pulsar across the network.
# =============================================================================

services:

  # --- etcd: ${CLUSTER_SIZE}-node Raft cluster ----------------------------
  etcd:
    image: quay.io/coreos/etcd:${ETCD_IMAGE_TAG}
    container_name: milvus-etcd
    network_mode: host
    restart: always
    environment:
      - ETCD_AUTO_COMPACTION_MODE=revision
      - ETCD_AUTO_COMPACTION_RETENTION=1000
      - ETCD_QUOTA_BACKEND_BYTES=4294967296
      - ETCD_SNAPSHOT_COUNT=50000
    volumes:
      - ${DATA_ROOT}/etcd:/etcd-data
    command:
      - etcd
      - --name=${NODE_NAME}
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:${ETCD_CLIENT_PORT}
      - --advertise-client-urls=http://${LOCAL_IP}:${ETCD_CLIENT_PORT}
      - --listen-peer-urls=http://0.0.0.0:${ETCD_PEER_PORT}
      - --initial-advertise-peer-urls=http://${LOCAL_IP}:${ETCD_PEER_PORT}
      - --initial-cluster=${ETCD_INITIAL_CLUSTER}
      - --initial-cluster-token=${CLUSTER_NAME}
      - --initial-cluster-state=${ETCD_INITIAL_CLUSTER_STATE}

  # --- MinIO: ${CLUSTER_SIZE}-node distributed cluster --------------------
  minio:
    image: minio/minio:${MINIO_IMAGE_TAG}
    container_name: milvus-minio
    network_mode: host
    restart: always
    environment:
      - MINIO_ROOT_USER=${MINIO_ACCESS_KEY}
      - MINIO_ROOT_PASSWORD=${MINIO_SECRET_KEY}
      - MINIO_REGION=${MINIO_REGION}
    volumes:
      - ${DATA_ROOT}/minio:/data
    command: ${MINIO_SERVER_CMD}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${MINIO_API_PORT}/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3

${PULSAR_SERVICE_BLOCK}
  # --- Milvus 2.5: standalone-clustered, Pulsar-backed --------------------
  # Same `milvus run standalone` mode as 2.6, but the MQ is the Pulsar
  # singleton on PULSAR_HOST (${PULSAR_HOST}, ${PULSAR_HOST_IP}).
  milvus:
    image: milvusdb/milvus:${MILVUS_IMAGE_TAG}
    container_name: milvus
    network_mode: host
    restart: always
    command: ["milvus", "run", "standalone"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ./milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - etcd
      - minio
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${MILVUS_HEALTHZ_PORT}/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3

  # --- nginx: LB across all ${CLUSTER_SIZE} Milvus instances on :${NGINX_LB_PORT}
  nginx:
    image: nginx:${NGINX_IMAGE_TAG}
    container_name: milvus-nginx
    network_mode: host
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - milvus
