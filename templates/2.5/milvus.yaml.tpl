# =============================================================================
# milvus.yaml — overlay overrides for Milvus ${MILVUS_VERSION}
#
# Generated for ${NODE_NAME}. Mounted as /milvus/configs/user.yaml.
#
# Differences from 2.6: uses Pulsar as the MQ (no Woodpecker), points
# Milvus at the Pulsar singleton on ${PULSAR_HOST} (${PULSAR_HOST_IP}).
#
# DO NOT EDIT BY HAND. Re-render with `milvus-onprem render`.
# =============================================================================

# -----------------------------------------------------------------------------
# etcd — point Milvus at all peers; same as 2.6.
# -----------------------------------------------------------------------------
etcd:
  endpoints:
${MILVUS_ETCD_ENDPOINTS_YAML}
  rootPath: by-dev
  metaSubPath: meta
  kvSubPath: kv

# -----------------------------------------------------------------------------
# minio — same distributed-mode setup as 2.6.
# Note: in 2.5, cloudProvider 'minio' was still valid. We use 'aws' for
# forward-compatibility with 2.6 upgrades and because MinIO speaks S3.
# -----------------------------------------------------------------------------
minio:
  address: ${LOCAL_IP}
  port: ${MINIO_API_PORT}
  accessKeyID: ${MINIO_ACCESS_KEY}
  secretAccessKey: ${MINIO_SECRET_KEY}
  useSSL: false
  bucketName: milvus-bucket
  rootPath: files
  cloudProvider: aws
  region: ${MINIO_REGION}

# -----------------------------------------------------------------------------
# Pulsar — Milvus 2.5 message queue. Singleton broker on PULSAR_HOST.
# Every node's Milvus connects to this same broker over the network.
# -----------------------------------------------------------------------------
mq:
  type: pulsar

pulsar:
  address: ${PULSAR_HOST_IP}
  port: ${PULSAR_BROKER_PORT}
  webport: ${PULSAR_HTTP_PORT}
  maxMessageSize: 5242880
  tenant: public
  namespace: default

# -----------------------------------------------------------------------------
# Common — disable RBAC by default. Users who need it can override here.
#
# session.ttl tightened from the upstream default (30) to 10. Combined
# with the queryCoord tunings below, this drops the post-failover read
# recovery window from ~50s to ~15-20s in 3-node drills. The tradeoff
# is a higher chance of false-positive eviction under bursty network
# jitter — fine on a LAN, lift toward defaults if you're across WAN.
# See docs/FAILOVER.md.
# -----------------------------------------------------------------------------
common:
  security:
    authorizationEnabled: false
  session:
    ttl: 10

# -----------------------------------------------------------------------------
# Coordinator active-standby — REQUIRED for multi-mixcoord HA.
#
# Default upstream is false. With it disabled, when a second mixcoord
# starts and tries to register its session at by-dev/meta/session/<coord>,
# the etcd CompareAndSwap fails (key already held by the first mixcoord)
# and sessionutil.Session.Register PANICS rather than going into standby.
# In a 3-node cluster only ONE mixcoord stays alive; the other two
# crash-loop forever via docker restart: always. Worse, when the active
# mixcoord dies there's no warm standby to promote, so cluster
# coordination is gone until docker happens to restart-cycle a survivor
# into the leader slot — many seconds of coord-down.
#
# Setting enableActiveStandby=true on all four coords lets the loser of
# the CAS race watch the leader's session lease and promote on TTL
# expiry. This is the canonical Milvus 2.5 HA path. All 4 coords run
# in the same mixcoord container so the flags must be set per-coord
# even though they're co-resident.
# -----------------------------------------------------------------------------
rootCoord:
  enableActiveStandby: true

dataCoord:
  enableActiveStandby: true

# -----------------------------------------------------------------------------
# queryCoord — tightened failure-detection so DML channels get
# reassigned faster after a querynode dies. See docs/FAILOVER.md.
# Plus enableActiveStandby (see rootCoord block above).
# -----------------------------------------------------------------------------
queryCoord:
  enableActiveStandby: true
  checkNodeSessionInterval: 10
  heartbeatAvailableInterval: 5000

indexCoord:
  enableActiveStandby: true

log:
  level: info
