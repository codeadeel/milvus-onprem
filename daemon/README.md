# milvus-onprem control plane daemon

FastAPI daemon, one per node, leader-elected via etcd. Stage 2 ships
the scaffold (leader election + topology watch + minimum read-only
endpoints). Subsequent stages add `/join`, jobs, backup/restore/upgrade
endpoints.

See `docs/CONTROL_PLANE.md` for the full design.

## Files

| File | Purpose |
|---|---|
| `main.py` | FastAPI app + lifespan + uvicorn entrypoint |
| `config.py` | Env-var-driven config (pydantic-settings) |
| `etcd_client.py` | Async wrapper over the etcd v3 HTTP gateway (lease, kv, txn, watch) |
| `leader.py` | Leader election via etcd lease + atomic create |
| `topology.py` | Watches `/cluster/topology/peers/`, fans out events to handlers |
| `auth.py` | Bearer-token middleware |
| `api.py` | HTTP routes (`/health`, `/version`, `/leader`, `/topology`) |
| `Dockerfile` | Container build (python:3.12-slim base + curl for healthcheck) |
| `requirements.txt` | Pinned deps |

## Configuration

Every setting comes from a `MILVUS_ONPREM_*` env var. Required:

| Var | Example | What |
|---|---|---|
| `MILVUS_ONPREM_CLUSTER_NAME` | `milvus-onprem` | Logical cluster ID. |
| `MILVUS_ONPREM_NODE_NAME` | `node-1` | This peer's stable name. |
| `MILVUS_ONPREM_LOCAL_IP` | `10.0.0.2` | This peer's IP. |
| `MILVUS_ONPREM_CLUSTER_TOKEN` | `<random-256-bit>` | Shared bearer token. |
| `MILVUS_ONPREM_ETCD_ENDPOINTS` | `http://10.0.0.2:2379,...` | Comma-separated. |

Optional (sensible defaults):

| Var | Default | What |
|---|---|---|
| `MILVUS_ONPREM_LISTEN_PORT` | `19500` | HTTP port. |
| `MILVUS_ONPREM_LEASE_TTL_S` | `15` | Leader lease TTL. |
| `MILVUS_ONPREM_KEEPALIVE_INTERVAL_S` | `5` | Lease keepalive cadence. |
| `MILVUS_ONPREM_LOG_LEVEL` | `info` | Python logging level. |

## Local smoke test (no real cluster)

Spin up a throwaway etcd, build the image, run the daemon, hit the
endpoints. From repo root:

```bash
# 1. ephemeral etcd
docker run -d --rm --name smoke-etcd -p 2379:2379 \
  quay.io/coreos/etcd:v3.5.25 \
  etcd \
  --listen-client-urls=http://0.0.0.0:2379 \
  --advertise-client-urls=http://localhost:2379

# 2. build image
docker build -t milvus-onprem-cp:dev daemon/

# 3. run daemon (network=host so it can reach the etcd above)
docker run -d --rm --name smoke-cp --network=host \
  -e MILVUS_ONPREM_CLUSTER_NAME=smoke \
  -e MILVUS_ONPREM_NODE_NAME=node-1 \
  -e MILVUS_ONPREM_LOCAL_IP=127.0.0.1 \
  -e MILVUS_ONPREM_CLUSTER_TOKEN=t0ken \
  -e MILVUS_ONPREM_ETCD_ENDPOINTS=http://127.0.0.1:2379 \
  milvus-onprem-cp:dev

# 4. probe
curl -s http://127.0.0.1:19500/health | jq
curl -s -H 'Authorization: Bearer t0ken' http://127.0.0.1:19500/leader | jq
docker logs smoke-cp | tail -20

# 5. cleanup
docker stop smoke-cp smoke-etcd
```

Expected: `/health` returns `is_leader: true` once the elector grabs
the lease (within ~1s on a fresh etcd). Daemon logs show `acquired
leadership (lease=...)`.

## Failure scenarios worth checking by hand

- Kill the daemon container while it's leader; the etcd lease expires
  in ~15s. A re-launched daemon takes over without manual cleanup.
- Block egress from one of two daemons in a multi-daemon test; the
  watcher reconnects automatically. (Stage 7 will validate this on
  real 4-VM hardware.)
