"""
Step 6 — plain ANN search.

Top-5 nearest neighbours of a query vector under cosine similarity.
ef=64 controls HNSW's search-time exploration breadth — higher is
more accurate, slower; 64 is fine for top-k <= 10.
"""
import time
import numpy as np
from pymilvus import MilvusClient
from _shared import URI, COLL, DIM, banner

banner("06 — ANN top-5")

q = np.random.default_rng(1).standard_normal(DIM).astype(np.float32)
q = (q / np.linalg.norm(q)).tolist()

client = MilvusClient(uri=URI)
t0 = time.time()
hits = client.search(
    collection_name=COLL, data=[q], limit=5,
    output_fields=["id", "category", "year"],
    search_params={"metric_type": "COSINE", "params": {"ef": 64}},
)
print(f"  {len(hits[0])} hits in {(time.time()-t0)*1000:.0f}ms")
for h in hits[0]:
    e = h["entity"]
    print(f"    id={h['id']:<5} dist={h['distance']:.4f}  "
          f"cat={e['category']:<8} year={e['year']}")
