  # --- Milvus 2.6 cluster mode (mixcoord + 4 workers + streamingnode) -----
  # Multi-VM HA path. Each peer runs the per-component services, sharing
  # etcd for metadata + MinIO for storage. mq.type=woodpecker; the WAL is
  # served by streamingnode (embedded Woodpecker). All milvus-* containers
  # share the same milvus.yaml — each component reads only its own keys.
  #
  # mixCoord.enableActiveStandby in milvus.yaml lets the loser of the etcd
  # CompareAndSwap on `by-dev/meta/session/<coord>` enter standby instead
  # of panicking — same pattern as 2.5.

  # mixcoord — all 4 coordinators in one process, leader-elected via etcd.
  # The 2.6 CLI calls the consolidated coordinator type `mixture` (same as
  # 2.5). Container is named `milvus-mixcoord` for operator clarity.
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
    healthcheck:
      # Probe the rootcoord gRPC port — bound by both leader and standby
      # mixcoord instances, so it distinguishes "process alive with sockets
      # bound" from "process gone" without misreporting standbys as
      # unhealthy.
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/localhost/${MILVUS_ROOTCOORD_PORT}"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: ${MILVUS_HEALTHCHECK_START_PERIOD_S}s

  # proxy — gRPC entry on :${MILVUS_PORT}; what nginx routes clients to.
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
      start_period: ${MILVUS_HEALTHCHECK_START_PERIOD_S}s

  # querynode — query / search worker.
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
      start_period: ${MILVUS_HEALTHCHECK_START_PERIOD_S}s

  # datanode — ingest worker.
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
      start_period: ${MILVUS_HEALTHCHECK_START_PERIOD_S}s

  # indexnode — index-build worker.
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
      start_period: ${MILVUS_HEALTHCHECK_START_PERIOD_S}s

  # streamingnode — Woodpecker WAL handler. Replaces the role Pulsar /
  # Kafka played in 2.5. New in 2.6 — every peer runs one.
  streamingnode:
    image: ${MILVUS_IMAGE_REPO}:${MILVUS_IMAGE_TAG}
    container_name: milvus-streamingnode
    network_mode: host
    restart: always
    command: ["milvus", "run", "streamingnode"]
    volumes:
      - ${DATA_ROOT}/milvus:/var/lib/milvus
      - ${HOST_REPO_ROOT}/rendered/${NODE_NAME}/milvus.yaml:/milvus/configs/user.yaml:ro
    depends_on:
      - mixcoord
    healthcheck:
      test: ["CMD", "bash", "-c", "echo > /dev/tcp/localhost/${MILVUS_STREAMINGNODE_PORT}"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: ${MILVUS_HEALTHCHECK_START_PERIOD_S}s
