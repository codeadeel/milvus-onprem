# pymilvus tutorial

Ten tiny scripts. Read them in order. Run them in order. Each one is a single
focused concept — short enough to skim before running, short enough to learn
from after running.

## Run

```bash
# one-time:
pip3 install --user --break-system-packages -r ../requirements.txt

# from this directory:
cd test/tutorial
python3 01_connect.py
python3 02_create.py
python3 03_insert.py
python3 04_load.py            # ← first run takes 1-3 min, then sub-second
python3 05_prove_replication.py
python3 06_search.py
python3 07_filter.py
python3 08_mutate.py
python3 09_inspect.py
python3 10_cleanup.py
```

Or all at once:

```bash
for f in 0*.py 1*.py; do echo "### $f"; python3 "$f"; done
```

## What each step covers

| File | Concept |
|---|---|
| `01_connect.py` | Connecting via the nginx LB (HA) vs. directly to a node (debug). |
| `02_create.py` | Schema design, index params (HNSW + COSINE), creating a collection. |
| `03_insert.py` | Inserting rows in batches, normalising vectors for cosine, `flush()`. |
| `04_load.py` | Loading the collection with `replica_number=min(2, peers)`. |
| `05_prove_replication.py` | Querying every peer directly to confirm they all serve. |
| `06_search.py` | Plain top-k ANN search. |
| `07_filter.py` | Hybrid search — vector ANN combined with a scalar filter. |
| `08_mutate.py` | `upsert` and `delete`. |
| `09_inspect.py` | `describe_collection`, stats, partitions, indexes. |
| `10_cleanup.py` | `release_collection` + `drop_collection`. |

## Knobs (env vars)

| Var | Default | Notes |
|---|---|---|
| `MILVUS_URI` | `http://127.0.0.1:19537` | Where to connect by default. Local nginx LB. |
| `COLLECTION` | `tutorial_docs` | Name of the collection used across steps. |
| `DIM` | `768` | Vector dimension. |
| `CLUSTER_ENV` | `<repo>/cluster.env` | Path to cluster.env (used by step 5 to enumerate peers). |

Override any of these to point the tutorial at a different cluster, a
different collection name, or a different cluster.env path.

## How step 5 finds the peers

`05_prove_replication.py` reads `cluster.env`'s `PEER_IPS` and constructs
direct gRPC URIs (`http://<ip>:<MILVUS_PORT>`) for each one. So adding a
peer to the cluster automatically extends the replication proof — no
script edits needed.

If `cluster.env` is missing (e.g. running this tutorial against a
different cluster), step 5 falls back to a single localhost peer.
