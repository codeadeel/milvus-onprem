# SDK guide — using the cluster from your app

For app developers who **didn't deploy the cluster** but need to use it.
If you're the operator, start with [GETTING_STARTED.md](GETTING_STARTED.md).

This page is one screen of code per topic — copy, paste, adapt.

## Install

```bash
pip install pymilvus
```

That's it. The cluster speaks the same gRPC protocol as any other Milvus
deploy. No special client library, no custom auth handshake — just
pymilvus.

## Connect

Always connect to a peer's **nginx LB on port 19537**, not Milvus's
direct port 19530. The LB routes around dead peers; the direct port
doesn't.

```python
from pymilvus import MilvusClient

# Pick ANY peer's IP. nginx round-robins to a healthy backend.
# For HA: list all peers in your config and the client picks one.
client = MilvusClient(uri="http://10.0.0.10:19537")
print(client.get_server_version())
print(client.list_collections())
```

## Create a collection

Schema + index in one call. HNSW + COSINE is the default for text
embeddings; switch to L2 / IP / dot-product if your model says so.

```python
from pymilvus import DataType

schema = client.create_schema(auto_id=False)
schema.add_field("id",        DataType.INT64,        is_primary=True)
schema.add_field("category",  DataType.VARCHAR,      max_length=32)
schema.add_field("score",     DataType.FLOAT)
schema.add_field("embedding", DataType.FLOAT_VECTOR, dim=768)

idx = client.prepare_index_params()
idx.add_index("embedding",
              index_type="HNSW",
              metric_type="COSINE",
              params={"M": 16, "efConstruction": 200})

client.create_collection("docs", schema=schema, index_params=idx)
```

## Load (with replicas for HA)

`replica_number` controls how many querynode replicas hold the
collection. **For production HA, set it to ≥ 3 on a 4+-peer cluster** —
that way any single-peer outage still leaves ≥ 2 healthy leader
candidates per shard.

```python
client.load_collection("docs", replica_number=3)
```

| Cluster size | Recommended `replica_number` |
|---|---|
| 1 (standalone) | 1 |
| 2-3 peers | 2 |
| 4+ peers | 3 |

`milvus-onprem restore-backup --load` picks this automatically.

## Insert

Batch is fine. Up to ~10k rows per `insert()` call works well.

```python
import random

rows = [
    {"id": i,
     "category": random.choice(["a", "b", "c"]),
     "score":    random.random(),
     "embedding": [random.random() for _ in range(768)]}
    for i in range(1000)
]
client.insert("docs", rows)
client.flush("docs")          # flush before search to make new rows visible
```

## Search

Vector + scalar filter combined.

```python
hits = client.search(
    "docs",
    data=[[0.5] * 768],                       # one query vector
    limit=5,                                  # top-5
    anns_field="embedding",
    filter='category == "a" and score > 0.7', # optional scalar filter
    output_fields=["id", "category", "score"],
    search_params={"metric_type": "COSINE", "params": {"ef": 64}},
)
for h in hits[0]:
    print(h["id"], h["entity"]["category"], h["distance"])
```

## Failover-safe reads (production pattern)

During topology changes (peer dies, upgrade running, auto-migrate-pulsar
firing on 2.5), Milvus may briefly return recovery-class errors:

| Error | Why |
|---|---|
| `code=503: no available shard leaders` | queryCoord hasn't promoted a new shard leader yet (worst case ~60-180s on 2.6 distributed) |
| `code=106: collection on recovering` | 2.5 mid-failover (~15-20s) |
| `code=65535: ... node not found` | Old grpc client cached a now-dead querynode |
| `code=700: index not found` | Just-created index not visible yet (~seconds) |
| `service unavailable: internal: Milvus Proxy is not ready yet` | 2.5 Pulsar singleton bouncing |

These all **settle in seconds**. Wrap reads in the shipped retry helper:

```python
import sys
sys.path.insert(0, "/path/to/milvus-onprem/test/tutorial")
from _shared import retry_on_recovering

# Default budget 120s — enough for 2.5 and most 2.6 cases.
hits = retry_on_recovering(lambda: client.search(...))

# Bump to 240s for 2.6 distributed worst-case (one shard whose delegator
# was on the dead peer can take 60-180s to re-promote).
hits = retry_on_recovering(lambda: client.search(...), max_wait_s=240)
```

Or roll your own — the code is short:

```python
import time
from pymilvus.exceptions import MilvusException

def retry_on_recovering(fn, max_wait_s=120):
    transient = ("recovering", "no available", "channel not available",
                 "channel checker not ready", "node not found",
                 "proxy is not ready",
                 "index not found", "collection not found")
    deadline = time.monotonic() + max_wait_s
    delay = 1.0
    while True:
        try:
            return fn()
        except MilvusException as e:
            if not any(p in str(e).lower() for p in transient) \
               or time.monotonic() >= deadline:
                raise
            time.sleep(min(delay, 10.0))
            delay = min(delay * 2, 10.0)
```

## Inspect, mutate, cleanup

```python
# Row count
client.query("docs", filter="id >= 0", output_fields=["count(*)"])

# Get by primary key
client.get("docs", ids=[1, 2, 3], output_fields=["category", "score"])

# Update (delete + insert with same id)
client.delete("docs", ids=[1])
client.insert("docs", [{"id": 1, "category": "z", "score": 0.99,
                        "embedding": [0.0] * 768}])

# Drop
client.release_collection("docs")
client.drop_collection("docs")
```

## What you get for free from milvus-onprem (vs vanilla Milvus standalone)

| | Standalone | milvus-onprem cluster |
|---|---|---|
| HA on peer loss | ❌ | ✅ — nginx routes to healthy backend, replica_number ≥ 2 keeps reads alive |
| Backup / restore | manual | `milvus-onprem create-backup` / `restore-backup` |
| Rolling upgrade | restart-and-pray | `milvus-onprem upgrade --milvus-version=v2.6.12` (peer-by-peer) |
| Add a node | rebuild from scratch | `milvus-onprem join` (online, no downtime) |
| Backup retry on transients | hand-rolled | shipped `retry_on_recovering` helper |

Your **app code is identical** to vanilla pymilvus — the difference is
all on the operator side.

## What's NOT shipped (do this in your app)

- **Auth** — Milvus's `authorizationEnabled: false` is the shipped
  default. Anyone with `:19537` access has full DB control. If you
  need RBAC, enable it via Milvus's API (also requires editing
  `templates/<version>/milvus.yaml.tpl`).
- **TLS** — gRPC is plaintext. Fine inside a private VPC; not fine on
  open networks. Add a TLS-terminating LB in front (Caddy, nginx with
  TLS, cloud LB) if your client is across the open internet.
- **Sharding logic** — `replica_number` is per-collection. If you have
  many collections with different HA requirements, set per collection.
- **Schema migrations** — Milvus is schemaless after create. Need to
  add a field? Drop + recreate, then re-load from your source-of-truth.

## More

- [`test/tutorial/`](../test/tutorial/) — 10-step pymilvus walkthrough
  (connect, create, insert, load, replication, search, filter, mutate,
  inspect, cleanup). Run them in order — each script is < 50 lines.
- [FAILOVER.md](FAILOVER.md) — what your app sees when a peer dies, how
  long recovery takes, when to use which retry budget.
- [TUTORIAL.md](TUTORIAL.md) — operator-side end-to-end walkthrough for
  every shipped feature (backup, upgrade, migrate-pulsar, etc.).
