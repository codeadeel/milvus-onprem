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
# queryCoord — tightened failure-detection so DML channels get
# reassigned faster after a querynode dies. See docs/FAILOVER.md.
# -----------------------------------------------------------------------------
queryCoord:
  checkNodeSessionInterval: 10
  heartbeatAvailableInterval: 5000

log:
  level: info
