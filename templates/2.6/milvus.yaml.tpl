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
#
# session.ttl tightened from upstream default (30) to 10. With the
# queryCoord tunings below, this drops the post-failover read recovery
# window from ~50s (untuned) to ~15-20s in 4-peer chaos drills (peer
# stops responding -> shard leaders re-elected on healthy querynodes).
# Without these, single-peer outage caused `code=503: no available
# shard leaders` on shards whose leader landed on the dead peer, even
# with replica_number=2. Tradeoff: tighter timeouts mean a higher
# chance of false-positive eviction under bursty network jitter — fine
# on a LAN, lift toward defaults if you're across WAN. See
# docs/FAILOVER.md.
# -----------------------------------------------------------------------------
common:
  security:
    authorizationEnabled: false
  session:
    ttl: 10

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

# queryCoord tunings: faster failure-detection so the cluster knows a
# querynode is unavailable within ~5-10s instead of the upstream ~60s.
# Same values 2.5 ships. Note: these tunings reduce *most* queries'
# failure window — the proxy stops sending requests to the dead
# querynode quickly. But they do NOT close the window for queries on
# the specific shard whose delegator (shard leader) was on the dead
# peer; queryCoord 2.6's delegator-reassignment isn't gated by these
# knobs (no public knob found in Milvus 2.6.11 to accelerate it).
# Worst-case shard recovery in 4-peer drills is ~60-180s. See
# docs/FAILOVER.md for the SDK-side retry pattern that handles this.
queryCoord:
  enableActiveStandby: true
  checkNodeSessionInterval: 10
  heartbeatAvailableInterval: 5000

log:
  level: info
