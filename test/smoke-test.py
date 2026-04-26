"""
smoke-test.py — end-to-end validation of an N-node milvus-onprem cluster.

What it does:
  1. Connect to the LB endpoint (default http://127.0.0.1:19537)
  2. Create a test collection (drops if it already exists)
  3. Insert 1,000 random vectors with scalar + embedding fields
  4. Build an HNSW index on the embedding
  5. Load the collection with replica_number=min(2, CLUSTER_SIZE) so it
     works on standalone (1-node) clusters too
  6. Run an ANN search + a hybrid (ANN + scalar filter) search
  7. Print pass/fail summary

Run:
  pip3 install --user --break-system-packages -r test/requirements.txt
  python3 test/smoke-test.py

Env overrides:
  MILVUS_URI       default http://127.0.0.1:19537
  MILVUS_COLL      default smoke_test
  NUM_ROWS         default 1000
  DIM              default 768
  REPLICAS         default 2 (or 1 if cluster is standalone)
"""

import os
import sys
import time
import random
import numpy as np

from pymilvus import MilvusClient, DataType


URI       = os.environ.get("MILVUS_URI",  "http://127.0.0.1:19537")
COLL      = os.environ.get("MILVUS_COLL", "smoke_test")
NUM       = int(os.environ.get("NUM_ROWS", "1000"))
DIM       = int(os.environ.get("DIM",      "768"))
REPLICAS  = int(os.environ.get("REPLICAS", "2"))

FAIL = 0
def check(cond, label, detail=""):
    global FAIL
    if cond:
        print(f"    [OK]   {label}")
    else:
        print(f"    [FAIL] {label}" + (f"  ({detail})" if detail else ""))
        FAIL += 1


def main():
    print("=" * 62)
    print(f" smoke-test.py")
    print(f" uri={URI}  collection={COLL}  rows={NUM}  dim={DIM}  replicas={REPLICAS}")
    print("=" * 62)

    print("\n==> connect")
    t0 = time.time()
    try:
        client = MilvusClient(uri=URI)
        check(True, f"connected in {time.time()-t0:.2f}s")
    except Exception as e:
        check(False, "connect", str(e)); return 1

    print("\n==> create collection")
    if client.has_collection(COLL):
        client.drop_collection(COLL)
        print(f"    (dropped existing '{COLL}')")

    schema = client.create_schema(auto_id=False, enable_dynamic_field=False)
    schema.add_field("id",        DataType.INT64,        is_primary=True)
    schema.add_field("category",  DataType.VARCHAR,      max_length=32)
    schema.add_field("score",     DataType.FLOAT)
    schema.add_field("embedding", DataType.FLOAT_VECTOR, dim=DIM)

    idx = client.prepare_index_params()
    idx.add_index(field_name="embedding",
                  index_type="HNSW", metric_type="COSINE",
                  params={"M": 16, "efConstruction": 200})

    client.create_collection(collection_name=COLL, schema=schema, index_params=idx)
    check(client.has_collection(COLL), f"created '{COLL}' with HNSW")

    print("\n==> insert")
    random.seed(42); np.random.seed(42)
    cats = ["contract", "brief", "motion", "exhibit"]
    rows = []
    for i in range(NUM):
        v = np.random.rand(DIM).astype(np.float32)
        v = v / np.linalg.norm(v)
        rows.append({
            "id": i, "category": random.choice(cats),
            "score": round(random.uniform(0, 1), 4),
            "embedding": v.tolist(),
        })

    t0 = time.time()
    res = client.insert(collection_name=COLL, data=rows)
    inserted = res.get("insert_count", len(rows)) if isinstance(res, dict) else len(rows)
    check(inserted == NUM, f"inserted {inserted}/{NUM} rows in {time.time()-t0:.2f}s")
    client.flush(COLL)

    print(f"\n==> load (replica_number={REPLICAS})")
    t0 = time.time()
    try:
        client.load_collection(COLL, replica_number=REPLICAS)
        check(True, f"loaded with {REPLICAS} replicas in {time.time()-t0:.2f}s")
    except Exception as e:
        check(False, f"load with replica_number={REPLICAS}", str(e))
        print("    Retrying with replica_number=1...")
        client.load_collection(COLL, replica_number=1)

    print("\n==> ANN search (top-5)")
    q = np.random.rand(DIM).astype(np.float32); q = (q / np.linalg.norm(q)).tolist()
    t0 = time.time()
    hits = client.search(collection_name=COLL, data=[q], limit=5,
                         output_fields=["id", "category", "score"],
                         search_params={"metric_type": "COSINE", "params": {"ef": 64}})
    elapsed_ms = (time.time() - t0) * 1000
    check(len(hits) == 1 and len(hits[0]) == 5, f"got 5 hits in {elapsed_ms:.1f}ms")
    if hits and hits[0]:
        top = hits[0][0]
        print(f"    top: id={top.get('id')}  cat={top.get('entity', {}).get('category')}  "
              f"dist={top.get('distance'):.4f}")

    print("\n==> hybrid search (ANN + scalar filter)")
    t0 = time.time()
    hits = client.search(collection_name=COLL, data=[q], limit=5,
                         filter='category == "contract" and score > 0.5',
                         output_fields=["id", "category", "score"],
                         search_params={"metric_type": "COSINE", "params": {"ef": 64}})
    elapsed_ms = (time.time() - t0) * 1000
    all_match = all(
        h.get("entity", {}).get("category") == "contract"
        and h.get("entity", {}).get("score", 0) > 0.5
        for h in (hits[0] if hits else [])
    )
    check(all_match and len(hits[0]) > 0,
          f"{len(hits[0])} filtered hits in {elapsed_ms:.1f}ms")

    print("\n==> count check")
    stats = client.get_collection_stats(COLL)
    row_count = stats.get("row_count", 0) if isinstance(stats, dict) else 0
    check(int(row_count) == NUM, f"row_count={row_count} (expected {NUM})")

    print("\n==> cleanup")
    client.release_collection(COLL)
    client.drop_collection(COLL)
    check(not client.has_collection(COLL), f"dropped '{COLL}'")

    print("\n" + "=" * 62)
    if FAIL == 0:
        print(" SMOKE TEST PASSED")
    else:
        print(f" SMOKE TEST FAILED ({FAIL} check(s) failed)")
    print("=" * 62)
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
