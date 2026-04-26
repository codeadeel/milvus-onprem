"""
Step 9 — inspect what the cluster knows about your collection.

describe_collection / get_collection_stats / list_partitions / list_indexes
are the four endpoints you'll use most often when debugging.
"""
from pymilvus import MilvusClient
from _shared import URI, COLL, banner

banner(f"09 — inspect '{COLL}'")

client = MilvusClient(uri=URI)
desc   = client.describe_collection(COLL)
fields = [f"{f['name']}:{f.get('type', '?')}" for f in desc.get("fields", [])]

print(f"  collection_id: {desc.get('collection_id')}")
print(f"  num_shards:    {desc.get('num_shards')}")
print(f"  fields:        {fields}")
print(f"  stats:         {client.get_collection_stats(COLL)}")
print(f"  partitions:    {client.list_partitions(COLL)}")
print(f"  indexes:       {client.list_indexes(COLL)}")
