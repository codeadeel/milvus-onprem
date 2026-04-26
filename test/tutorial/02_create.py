"""
Step 2 — define a schema and create the collection.

Schema design tip: declare scalar fields explicitly so Milvus can
filter on them efficiently. HNSW + COSINE is the default choice for
text embeddings under ~50M vectors.
"""
from pymilvus import MilvusClient, DataType
from _shared import URI, COLL, DIM, banner

banner(f"02 — create '{COLL}'")

client = MilvusClient(uri=URI)
if client.has_collection(COLL):
    client.drop_collection(COLL)
    print(f"  dropped existing '{COLL}'")

schema = client.create_schema(auto_id=False, enable_dynamic_field=False)
schema.add_field("id",         DataType.INT64,        is_primary=True)
schema.add_field("category",   DataType.VARCHAR,      max_length=32)
schema.add_field("year",       DataType.INT64)
schema.add_field("score",      DataType.FLOAT)
schema.add_field("embedding",  DataType.FLOAT_VECTOR, dim=DIM)

idx = client.prepare_index_params()
idx.add_index(
    field_name="embedding",
    index_type="HNSW",
    metric_type="COSINE",
    params={"M": 16, "efConstruction": 200},
)

client.create_collection(collection_name=COLL, schema=schema, index_params=idx)
print(f"  created '{COLL}' with HNSW(COSINE), dim={DIM}")
