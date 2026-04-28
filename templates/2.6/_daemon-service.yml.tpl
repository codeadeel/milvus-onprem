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
      # /join reads cluster.env to build a copy for the joining peer.
      # Read-only — the daemon never edits cluster.env directly.
      - ${REPO_ROOT}/cluster.env:/etc/milvus-onprem/cluster.env:ro
      # The repo itself, used by the topology-change handler to call
      # `./milvus-onprem render` and rewrite rendered/<node-name>/.
      # The render needs to write rendered/, so this is read-write.
      - ${REPO_ROOT}:/repo
      # Docker socket so the daemon can `docker exec` into sibling
      # containers (nginx reload, MinIO mc admin pool add). Without
      # this the host-side propagation can't run from inside the
      # daemon. Trade-off: the daemon process can control the host
      # docker engine — protected by being only locally accessible.
      - /var/run/docker.sock:/var/run/docker.sock
      # /tmp passthrough so the operator's `--to=/tmp/...` paths used
      # by export-backup land on the host filesystem rather than in
      # the container's ephemeral /tmp. Same trick for any other
      # well-known shared path the operator passes through (/mnt
      # mounts, NFS, USB) would need its own additional bind here.
      - /tmp:/tmp
    depends_on:
      - etcd
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${CONTROL_PLANE_PORT}/health"]
      interval: 15s
      timeout: 3s
      retries: 3
