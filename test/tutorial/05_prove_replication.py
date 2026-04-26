"""
Step 5 — prove every peer is serving the same data.

Bypass the LB and connect to each node's Milvus directly. They should
all return identical top hits (deterministic seed → deterministic answer).
If any node errors out, that node isn't holding a replica or its Milvus
is unreachable.

Reads PEER_IPS from cluster.env to enumerate every node automatically.
"""
import numpy as np
from pymilvus import MilvusClient
from _shared import COLL, DIM, all_peer_uris, banner

banner("05 — query every peer directly")

q = np.random.default_rng(0).standard_normal(DIM).astype(np.float32)
q = (q / np.linalg.norm(q)).tolist()

peers = all_peer_uris()
if not peers:
    print("  no peers found — is cluster.env present?")
    raise SystemExit(1)

for name, uri in peers:
    try:
        c = MilvusClient(uri=uri)
        hits = c.search(
            collection_name=COLL, data=[q], limit=3,
            output_fields=["id", "category"],
            search_params={"metric_type": "COSINE", "params": {"ef": 64}},
        )
        top = hits[0][0]
        print(f"  {name:<8} @ {uri:<32}  ok, top id={top['id']} dist={top['distance']:.4f}")
    except Exception as e:
        print(f"  {name:<8} @ {uri:<32}  FAILED: {type(e).__name__}: {e}")
