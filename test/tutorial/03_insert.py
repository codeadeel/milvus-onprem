"""
Step 3 — insert 1,000 rows.

Vectors are L2-normalised so COSINE behaves correctly.
flush() seals the in-memory buffer into a sealed segment in MinIO.
"""
import time, random
import numpy as np
from pymilvus import MilvusClient
from _shared import URI, COLL, DIM, banner

NUM = 1000
banner(f"03 — insert {NUM} rows into '{COLL}'")

client = MilvusClient(uri=URI)
rng    = np.random.default_rng(42)
rand   = random.Random(42)
cats   = ["contract", "brief", "motion", "exhibit", "memo"]

rows = []
for i in range(NUM):
    v = rng.standard_normal(DIM).astype(np.float32)
    v = v / np.linalg.norm(v)
    rows.append({
        "id":        i,
        "category":  rand.choice(cats),
        "year":      rand.randint(2010, 2025),
        "score":     round(rand.uniform(0, 1), 4),
        "embedding": v.tolist(),
    })

t0 = time.time()
client.insert(collection_name=COLL, data=rows)
client.flush(COLL)
print(f"  inserted + flushed {NUM} rows in {time.time()-t0:.2f}s")
