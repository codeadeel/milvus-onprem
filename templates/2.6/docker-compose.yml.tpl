# =============================================================================
# docker-compose.yml — generated for ${NODE_NAME} (Milvus ${MILVUS_VERSION})
#
# DO NOT EDIT BY HAND. Re-render with `milvus-onprem render` after changes
# to cluster.env. Source: templates/${MILVUS_VERSION}/docker-compose.yml.tpl
#
# All services use host networking — simpler cross-node communication and
# avoids docker-bridge port-forwarding overhead. Each container's data
# lives under ${DATA_ROOT}/<component>/ on this host.
# =============================================================================

services:

  # --- etcd: ${CLUSTER_SIZE}-node Raft cluster ----------------------------
  # Quorum-aware metadata store. Tolerates floor((${CLUSTER_SIZE}-1)/2)
  # member failures simultaneously.
  etcd:
    image: ${ETCD_IMAGE_REPO}:${ETCD_IMAGE_TAG}
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
    healthcheck:
      # `etcdctl endpoint health` reports OK when this member is
      # current with the Raft log. Without this, the local watchdog
      # had no way to detect a wedged etcd process (QA finding
      # F-Phase1.C). Ships in the official etcd image at
      # /usr/local/bin/etcdctl.
      test: ["CMD", "etcdctl", "--endpoints=http://127.0.0.1:${ETCD_CLIENT_PORT}", "endpoint", "health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s

  # --- MinIO: ${CLUSTER_SIZE}-node distributed cluster --------------------
  # Erasure-coded across all peers. For ${CLUSTER_SIZE}>=4 nodes this gives
  # automatic single-drive parity. For 3 nodes, the cluster runs but with
  # tighter parity margins. For 1 node it runs as plain single-drive.
  minio:
    image: ${MINIO_IMAGE_REPO}:${MINIO_IMAGE_TAG}
    container_name: milvus-minio
    network_mode: host
    restart: always
    environment:
      - MINIO_ROOT_USER=${MINIO_ACCESS_KEY}
      - MINIO_ROOT_PASSWORD=${MINIO_SECRET_KEY}
      - MINIO_REGION=${MINIO_REGION}
    volumes:
${MINIO_VOLUMES_BLOCK}
    command: ${MINIO_SERVER_CMD}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${MINIO_API_PORT}/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 3

  # --- Milvus: standalone-clustered with embedded Woodpecker WAL ----------
  # Runs `milvus run standalone` — the all-in-one binary. With shared etcd
  # and shared object storage, multiple instances form a clustered Milvus
  # via etcd-based service discovery and leader election.
  milvus:
    image: ${MILVUS_IMAGE_REPO}:${MILVUS_IMAGE_TAG}
    container_name: milvus
    network_mode: host
    restart: always
    command: ["milvus", "run", "standalone"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ${HOST_REPO_ROOT}/rendered/${NODE_NAME}/milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - etcd
      - minio
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${MILVUS_HEALTHZ_PORT}/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3

  # --- nginx: LB across all ${CLUSTER_SIZE} Milvus instances on :${NGINX_LB_PORT}
  # Layer 4 (TCP) load balancer with passive health checks. Clients connect
  # to any node's :${NGINX_LB_PORT}; nginx routes to a healthy Milvus.
  nginx:
    image: ${NGINX_IMAGE_REPO}:${NGINX_IMAGE_TAG}
    container_name: milvus-nginx
    network_mode: host
    restart: always
    volumes:
      - ${HOST_REPO_ROOT}/rendered/${NODE_NAME}/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - milvus
    healthcheck:
      # Verify the LB port is bound. nginx:alpine's busybox `nc -z`
      # handles a connect-only probe without needing bash or curl.
      # (QA finding F-Phase1.C — without this the watchdog couldn't
      # see a wedged nginx process, only an exited container.)
      test: ["CMD-SHELL", "nc -z 127.0.0.1 ${NGINX_LB_PORT} || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

${CONTROL_PLANE_SERVICE_BLOCK}

${PULSAR_SERVICE_BLOCK}
