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

  # --- MinIO: ${CLUSTER_SIZE}-node distributed cluster --------------------
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

${PULSAR_SERVICE_BLOCK}
  # --- Milvus 2.5 mixcoord: all 4 coordinators in one process -------------
  # rootcoord + datacoord + querycoord + indexcoord, leader-elected via etcd.
  # Run on every node; only one is the active leader at any time, the
  # others stand by. This is the path 2.5 was designed for, and the one
  # `milvus run standalone` deliberately does not provide.
  #
  # NOTE: Milvus 2.5.x's CLI calls this server type `mixture` even though
  # the docs use the name "mixcoord". The container is still named
  # `milvus-mixcoord` so operators see the role-meaningful name in
  # `milvus-onprem ps` / logs.
  #
  # The `-rootcoord/-datacoord/-querycoord/-indexcoord=true` flags must
  # be passed explicitly even though `milvus run mixture --help` claims
  # they default to true. Without them, 2.5.4's mixture process starts
  # but never opens the coord gRPC ports (53100/13333/19531/31000), so
  # proxy hangs in init with `find no available rootcoord`. Tested on
  # real hardware: blank `mixture` → no coord ports bound; with the
  # explicit flags → all four bind and proxy converges.
  mixcoord:
    image: ${MILVUS_IMAGE_REPO}:${MILVUS_IMAGE_TAG}
    container_name: milvus-mixcoord
    network_mode: host
    restart: always
    command:
      - milvus
      - run
      - mixture
      - -rootcoord=true
      - -datacoord=true
      - -querycoord=true
      - -indexcoord=true
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ${HOST_REPO_ROOT}/rendered/${NODE_NAME}/milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - etcd
      - minio
    # Mixcoord exposes /healthz but it's leader-only — standby mixcoords
    # report rootcoord/datacoord/querycoord as unhealthy because they're
    # passive. Probe the rootcoord gRPC port instead: both leader and
    # standby bind it (standby keeps the listener for fast failover),
    # so a TCP-connect distinguishes "process alive with sockets bound"
    # from "process gone". Same /dev/tcp pattern as the workers.
    healthcheck:
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/localhost/${MILVUS_ROOTCOORD_PORT}"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 120s

  # --- Milvus 2.5 proxy: gRPC entry, what nginx routes to -----------------
  # Healthcheck note for the next 4 components: only mixcoord binds
  # /healthz on :9091 in this topology, so each worker's healthcheck is
  # a TCP probe of its own gRPC port using bash's /dev/tcp builtin (no
  # extra binaries needed in the milvus image). Catches the common
  # case where the binary crashes leaving the listener gone; for soft
  # hangs the kernel may still SYN-ACK, so the watchdog won't always
  # catch a wedge — but docker's `restart: always` plus this probe is
  # strictly better than no healthcheck at all (= permanent
  # health=none = LocalComponentWatchdog cannot fire).
  proxy:
    image: ${MILVUS_IMAGE_REPO}:${MILVUS_IMAGE_TAG}
    container_name: milvus-proxy
    network_mode: host
    restart: always
    command: ["milvus", "run", "proxy"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ${HOST_REPO_ROOT}/rendered/${NODE_NAME}/milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - mixcoord
    healthcheck:
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/localhost/${MILVUS_PORT}"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s

  # --- Milvus 2.5 querynode: query / search worker ------------------------
  querynode:
    image: ${MILVUS_IMAGE_REPO}:${MILVUS_IMAGE_TAG}
    container_name: milvus-querynode
    network_mode: host
    restart: always
    command: ["milvus", "run", "querynode"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ${HOST_REPO_ROOT}/rendered/${NODE_NAME}/milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - mixcoord
    healthcheck:
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/localhost/${MILVUS_QUERYNODE_PORT}"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s

  # --- Milvus 2.5 datanode: ingest worker ---------------------------------
  datanode:
    image: ${MILVUS_IMAGE_REPO}:${MILVUS_IMAGE_TAG}
    container_name: milvus-datanode
    network_mode: host
    restart: always
    command: ["milvus", "run", "datanode"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ${HOST_REPO_ROOT}/rendered/${NODE_NAME}/milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - mixcoord
    healthcheck:
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/localhost/${MILVUS_DATANODE_PORT}"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s

  # --- Milvus 2.5 indexnode: index-build worker ---------------------------
  indexnode:
    image: ${MILVUS_IMAGE_REPO}:${MILVUS_IMAGE_TAG}
    container_name: milvus-indexnode
    network_mode: host
    restart: always
    command: ["milvus", "run", "indexnode"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ${HOST_REPO_ROOT}/rendered/${NODE_NAME}/milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - mixcoord
    healthcheck:
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/localhost/${MILVUS_INDEXNODE_PORT}"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 90s

  # --- nginx: LB across all ${CLUSTER_SIZE} proxies on :${NGINX_LB_PORT} --
  nginx:
    image: ${NGINX_IMAGE_REPO}:${NGINX_IMAGE_TAG}
    container_name: milvus-nginx
    network_mode: host
    restart: always
    volumes:
      - ${HOST_REPO_ROOT}/rendered/${NODE_NAME}/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - proxy

${CONTROL_PLANE_SERVICE_BLOCK}
