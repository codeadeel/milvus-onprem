"""
Step 10 — release and drop the collection.

release_collection() unloads from QueryNode RAM.
drop_collection() removes the schema, segments, and index files.
"""
from pymilvus import MilvusClient
from _shared import URI, COLL, banner

banner(f"10 — drop '{COLL}'")

client = MilvusClient(uri=URI)
if client.has_collection(COLL):
    client.release_collection(COLL)
    client.drop_collection(COLL)
    print(f"  released and dropped '{COLL}'")
else:
    print(f"  '{COLL}' didn't exist — nothing to do")
