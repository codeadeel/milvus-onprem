  # --- Milvus 2.6 standalone -----------------------------------------------
  # Single-binary `milvus run standalone` — used for MODE=standalone deploys
  # (single VM, no HA). Multi-VM HA goes through the cluster-mode fragment
  # (_milvus-cluster.yml.tpl) instead.
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
      start_period: ${MILVUS_HEALTHCHECK_START_PERIOD_S}s
