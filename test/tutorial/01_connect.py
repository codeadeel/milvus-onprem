"""
Step 1 — connect.

We talk to nginx on :19537, not Milvus on :19530 directly.
nginx routes around a dead Milvus process; :19530 doesn't.
"""
from pymilvus import MilvusClient
from _shared import URI, banner

banner("01 — connect")

client = MilvusClient(uri=URI)
print(f"  uri:     {URI}")
print(f"  version: {client.get_server_version()}")
print(f"  list:    {client.list_collections()}")
