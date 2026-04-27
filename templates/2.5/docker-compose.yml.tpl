# =============================================================================
# docker-compose.yml — generated for ${NODE_NAME} (Milvus ${MILVUS_VERSION})
#
# DO NOT EDIT BY HAND. Re-render with `milvus-onprem render` after changes
# to cluster.env. Source: templates/${MILVUS_VERSION}/docker-compose.yml.tpl
#
# Architecture difference from 2.6: Milvus 2.5 cannot run multi-node HA in
# `milvus run standalone` mode (multiple instances panic on rootcoord
# CompareAndSwap when sharing an etcd). Instead, each node runs the
# components separately:
#
#   mixcoord   (all 4 coordinators in 1 container, leader-elected via etcd)
#   proxy      (gRPC entry on :${MILVUS_PORT}, what nginx LBs across peers)
#   querynode  (query worker)
#   datanode   (ingest worker)
#   indexnode  (index-build worker)
#
# Plus the existing etcd / minio / nginx (and pulsar singleton on PULSAR_HOST).
# All milvus-* containers share the same milvus.yaml — each component reads
# only the bits it needs.
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
  # --- Milvus 2.5 mixcoord: all 4 coordinators in one process -------------
  # rootcoord + datacoord + querycoord + indexcoord, leader-elected via etcd.
  # Run on every node; only one is the active leader at any time, the
  # others stand by. This is the path 2.5 was designed for, and the one
  # `milvus run standalone` deliberately does not provide.
  mixcoord:
    image: milvusdb/milvus:${MILVUS_IMAGE_TAG}
    container_name: milvus-mixcoord
    network_mode: host
    restart: always
    command: ["milvus", "run", "mixcoord"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ./milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - etcd
      - minio

  # --- Milvus 2.5 proxy: gRPC entry, what nginx routes to -----------------
  proxy:
    image: milvusdb/milvus:${MILVUS_IMAGE_TAG}
    container_name: milvus-proxy
    network_mode: host
    restart: always
    command: ["milvus", "run", "proxy"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ./milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - mixcoord

  # --- Milvus 2.5 querynode: query / search worker ------------------------
  querynode:
    image: milvusdb/milvus:${MILVUS_IMAGE_TAG}
    container_name: milvus-querynode
    network_mode: host
    restart: always
    command: ["milvus", "run", "querynode"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ./milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - mixcoord

  # --- Milvus 2.5 datanode: ingest worker ---------------------------------
  datanode:
    image: milvusdb/milvus:${MILVUS_IMAGE_TAG}
    container_name: milvus-datanode
    network_mode: host
    restart: always
    command: ["milvus", "run", "datanode"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ./milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - mixcoord

  # --- Milvus 2.5 indexnode: index-build worker ---------------------------
  indexnode:
    image: milvusdb/milvus:${MILVUS_IMAGE_TAG}
    container_name: milvus-indexnode
    network_mode: host
    restart: always
    command: ["milvus", "run", "indexnode"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ./milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - mixcoord

  # --- nginx: LB across all ${CLUSTER_SIZE} proxies on :${NGINX_LB_PORT} --
  nginx:
    image: nginx:${NGINX_IMAGE_TAG}
    container_name: milvus-nginx
    network_mode: host
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - proxy
