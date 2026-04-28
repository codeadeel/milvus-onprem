  # --- control plane daemon (FastAPI + leader election + topology watch) ---
  # One per node. All daemons join leader election via the etcd lease at
  # /cluster/leader; whichever wins serves write endpoints (/join etc.).
  # Followers serve read endpoints locally and 307-redirect writes. The
  # daemon DOES NOT depend on milvus or minio being up — it lives next
  # to etcd and is what the operator's CLI talks to for cluster ops.
  control-plane:
    image: ${CONTROL_PLANE_IMAGE}
    container_name: milvus-onprem-cp
    network_mode: host
    restart: always
    environment:
      - MILVUS_ONPREM_CLUSTER_NAME=${CLUSTER_NAME}
      - MILVUS_ONPREM_NODE_NAME=${NODE_NAME}
      - MILVUS_ONPREM_LOCAL_IP=${LOCAL_IP}
      - MILVUS_ONPREM_CLUSTER_TOKEN=${CLUSTER_TOKEN}
      - MILVUS_ONPREM_ETCD_ENDPOINTS=http://${LOCAL_IP}:${ETCD_CLIENT_PORT}
      - MILVUS_ONPREM_ETCD_PEER_PORT=${ETCD_PEER_PORT}
      - MILVUS_ONPREM_LISTEN_PORT=${CONTROL_PLANE_PORT}
    volumes:
      # The /join handler reads cluster.env to build a copy for the
      # joining peer. Read-only mount; daemon never edits it.
      - ${REPO_ROOT}/cluster.env:/etc/milvus-onprem/cluster.env:ro
    depends_on:
      - etcd
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${CONTROL_PLANE_PORT}/health"]
      interval: 15s
      timeout: 3s
      retries: 3
