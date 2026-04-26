"""
Step 4 — load with replica_number=min(2, peers).

The "moment of truth" for redundancy: for a 3-node cluster, 2 replicas
means QueryNodes on 2 different VMs each hold a copy of the data.

First load on a fresh cluster: 1-3 min cold-cache. Subsequent loads:
sub-second.
"""
import time
from pymilvus import MilvusClient
from _shared import URI, COLL, banner, all_peer_uris

REPLICAS = min(2, len(all_peer_uris()))

banner(f"04 — load '{COLL}' with replica_number={REPLICAS}")

client = MilvusClient(uri=URI)
t0 = time.time()
client.load_collection(COLL, replica_number=REPLICAS)
print(f"  loaded in {time.time()-t0:.1f}s")
print(f"  state:  {client.get_load_state(COLL)}")
