# =============================================================================
# milvus.yaml — overlay overrides for Milvus ${MILVUS_VERSION}
#
# Generated for ${NODE_NAME}. Mounted as /milvus/configs/user.yaml (NOT
# /milvus/configs/milvus.yaml) — overlays the shipped defaults rather than
# replacing them. This keeps us future-proof against new keys Milvus adds
# in patch releases.
#
# DO NOT EDIT BY HAND. Re-render with `milvus-onprem render`.
# =============================================================================

# -----------------------------------------------------------------------------
# etcd — point Milvus at all peers; it'll pick a healthy one and reconnect
# automatically as the cluster's leader changes.
# -----------------------------------------------------------------------------
etcd:
  endpoints:
${MILVUS_ETCD_ENDPOINTS_YAML}
  rootPath: by-dev
  metaSubPath: meta
  kvSubPath: kv

# -----------------------------------------------------------------------------
# minio — point at THIS node's local MinIO. Distributed mode means any
# node's :${MINIO_API_PORT} serves the same content; the local connection
# is just slightly faster.
# -----------------------------------------------------------------------------
minio:
  address: ${LOCAL_IP}
  port: ${MINIO_API_PORT}
  accessKeyID: ${MINIO_ACCESS_KEY}
  secretAccessKey: ${MINIO_SECRET_KEY}
  useSSL: false
  bucketName: milvus-bucket
  rootPath: files
  # cloudProvider must be 'aws' for MinIO since Milvus 2.6 dropped 'minio'
  # as a valid value (segcore filesystem only accepts aws/gcp/azure/aliyun/tencent).
  # MinIO speaks S3, so 'aws' works correctly.
  cloudProvider: aws
  region: ${MINIO_REGION}

# -----------------------------------------------------------------------------
# Message queue — Woodpecker (embedded) is the default in v0. Pulsar can
# be added in a future release; today setting MQ_TYPE=pulsar in cluster.env
# will fail the version validation.
# -----------------------------------------------------------------------------
mq:
  type: ${MQ_TYPE}

# -----------------------------------------------------------------------------
# Woodpecker — Milvus 2.6 embedded WAL. Stores metadata in shared etcd and
# log segments in shared MinIO. Each Milvus instance has its own embedded
# Woodpecker process that participates in the cluster via etcd.
# -----------------------------------------------------------------------------
woodpecker:
  meta:
    type: etcd
    prefix: woodpecker
  storage:
    type: minio
    rootPath: woodpecker

# -----------------------------------------------------------------------------
# Common — disable RBAC by default. Users who need it can override here.
# -----------------------------------------------------------------------------
common:
  security:
    authorizationEnabled: false

# -----------------------------------------------------------------------------
# Coordinator active-standby — required for multi-mixcoord HA in cluster
# mode. Without it, when a second mixcoord starts and tries to register
# its session at by-dev/meta/session/<coord>, the etcd CompareAndSwap
# fails (key already held by the first mixcoord) and the session helper
# panics. With it, the loser of the CAS race watches the leader's
# session lease and promotes on TTL expiry. mixCoord is the 2.6
# consolidated key; per-coord keys still apply for back-compat.
# -----------------------------------------------------------------------------
mixCoord:
  enableActiveStandby: true

rootCoord:
  enableActiveStandby: true

dataCoord:
  enableActiveStandby: true

queryCoord:
  enableActiveStandby: true

log:
  level: info
