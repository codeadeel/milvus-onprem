"""
Step 8 — upsert and delete.

upsert is delete+insert keyed on the primary key.
delete is a tombstone, applied at read time and physically compacted
in the background.
"""
import time
import numpy as np
from pymilvus import MilvusClient
from _shared import URI, COLL, DIM, banner

banner("08 — upsert + delete")

client = MilvusClient(uri=URI)

# upsert id=0 with new contents
v = np.random.default_rng(99).standard_normal(DIM).astype(np.float32)
v = v / np.linalg.norm(v)
client.upsert(collection_name=COLL, data=[{
    "id": 0, "category": "memo", "year": 2026,
    "score": 0.999, "embedding": v.tolist(),
}])
print(f"  after upsert: {client.query(COLL, filter='id == 0', output_fields=['id', 'category', 'year'])}")

# delete every exhibit
before = len(client.query(COLL, filter='category == \"exhibit\"', output_fields=["id"]))
client.delete(collection_name=COLL, filter='category == "exhibit"')
time.sleep(2)  # tombstones take a beat to propagate
after = len(client.query(COLL, filter='category == \"exhibit\"', output_fields=["id"]))
print(f"  exhibit rows: before={before}, after delete={after}")
