"""
Step 7 — hybrid search: vector + scalar filter.

Milvus evaluates the filter and the ANN search together (not as a
post-filter), so it stays efficient even for selective filters.
"""
import time
import numpy as np
from pymilvus import MilvusClient
from _shared import URI, COLL, DIM, banner

banner("07 — hybrid (ANN + scalar filter)")

q = np.random.default_rng(1).standard_normal(DIM).astype(np.float32)
q = (q / np.linalg.norm(q)).tolist()

client = MilvusClient(uri=URI)
t0 = time.time()
hits = client.search(
    collection_name=COLL, data=[q], limit=5,
    filter='category in ["contract", "brief"] and year >= 2020',
    output_fields=["id", "category", "year"],
    search_params={"metric_type": "COSINE", "params": {"ef": 64}},
)
print(f"  {len(hits[0])} hits in {(time.time()-t0)*1000:.0f}ms  "
      f"(filter: contract|brief AND year >= 2020)")
for h in hits[0]:
    e = h["entity"]
    print(f"    id={h['id']:<5} dist={h['distance']:.4f}  "
          f"cat={e['category']:<8} year={e['year']}")
