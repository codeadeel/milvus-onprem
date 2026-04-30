"""
Shared config + helpers for the tutorial files.

Everything imports from here. Override defaults via env vars.
"""
import os

# Default talks to the local nginx LB (works from any cluster node).
URI = os.environ.get("MILVUS_URI", "http://127.0.0.1:19537")

COLL = os.environ.get("COLLECTION", "tutorial_docs")
DIM  = int(os.environ.get("DIM", "768"))


def banner(title: str) -> None:
    print(f"\n{'=' * 60}\n  {title}\n{'=' * 60}")


def retry_on_recovering(fn, *, max_wait_s=120, base_delay_s=1.0, max_delay_s=10.0):
    """
    Call fn() and retry while Milvus reports a transient recovery error.

    During a node failover or restart the cluster briefly returns errors
    like 'collection on recovering' or 'no available rootcoord' while
    coordinators / querynodes reassign channels. Bare reads will fail
    once and then succeed if you retry — this helper hides the loop.

    Re-raises the original exception if max_wait_s elapses, or
    immediately if the exception is not a known recovery-class error
    (so real bugs surface instead of getting silently swallowed).

    For 2.6 distributed: the worst-case shard whose delegator was on
    the dead peer can take 60-180s for queryCoord to re-promote a
    replica leader, so pass max_wait_s=240 there to comfortably cover.
    """
    import time
    from pymilvus.exceptions import MilvusException

    transient = ("recovering", "no available", "channel not available",
                 "channel checker not ready", "node not found")
    deadline = time.monotonic() + max_wait_s
    delay = base_delay_s
    while True:
        try:
            return fn()
        except MilvusException as e:
            if not any(p in str(e).lower() for p in transient) \
               or time.monotonic() >= deadline:
                raise
            time.sleep(min(delay, max_delay_s))
            delay = min(delay * 2, max_delay_s)


def all_peer_uris():
    """
    Read PEER_IPS from cluster.env and return (name, gRPC-uri) pairs for
    every peer in the cluster. Used by 05_prove_replication to iterate
    every node, not just the local LB. If cluster.env is missing, returns
    a single localhost entry.
    """
    cluster_env = os.environ.get("CLUSTER_ENV", _default_cluster_env())
    if not os.path.exists(cluster_env):
        return [("local", "http://127.0.0.1:19530")]

    peer_ips = None
    milvus_port = "19530"
    with open(cluster_env) as f:
        for line in f:
            line = line.strip()
            if line.startswith("PEER_IPS="):
                peer_ips = line.split("=", 1)[1].strip()
            elif line.startswith("MILVUS_PORT="):
                milvus_port = line.split("=", 1)[1].strip()

    if not peer_ips:
        return [("local", "http://127.0.0.1:19530")]

    return [
        (f"node-{i+1}", f"http://{ip}:{milvus_port}")
        for i, ip in enumerate(peer_ips.split(","))
    ]


def _default_cluster_env():
    """Look for cluster.env at the repo root (two levels up from this file)."""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(os.path.dirname(os.path.dirname(here)), "cluster.env")
