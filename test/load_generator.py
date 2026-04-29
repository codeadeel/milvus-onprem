"""Concurrent load generator for milvus-onprem QA.

Drives a steady stream of inserts and searches against the cluster's
nginx LB endpoint while the operator runs a cluster-changing
operation (parallel join, remove-node, migrate-pulsar, rotate-token).
Reports throughput, error counts, and a final row-count diff so QA
can characterize how the operation behaves under live traffic.

Usage:
    python3 test/load_generator.py \
        --uri http://10.0.0.2:19537 \
        --collection load_test \
        --dim 8 \
        --insert-workers 4 \
        --search-workers 2 \
        --duration-s 120 \
        --report /tmp/load_report.json

Produces a JSON report with:
    inserts_attempted / inserts_ok / inserts_failed
    searches_attempted / searches_ok / searches_failed
    row_count_after (server-reported)
    expected_row_count (= inserts_ok)
    diff (=row_count_after - expected_row_count;
          negative = lost messages, classic lossy-Pulsar window)
    error_samples (first N errors per category)

Exit codes:
    0  — completed (whether or not diff is zero)
    2  — couldn't even connect / create collection
"""

from __future__ import annotations

import argparse
import json
import random
import signal
import sys
import threading
import time
from collections import Counter, defaultdict


def main() -> int:
    """Parse CLI args, run the workload, write the report."""
    args = _parse_args()
    try:
        from pymilvus import (
            CollectionSchema, FieldSchema, DataType, Collection,
            connections, utility,
        )
    except ImportError:
        print("pymilvus is not installed; pip install pymilvus", file=sys.stderr)
        return 2

    print(f"connecting to {args.uri}")
    try:
        connections.connect(uri=args.uri)
    except Exception as e:
        print(f"connect failed: {e}", file=sys.stderr)
        return 2

    if utility.has_collection(args.collection):
        print(f"dropping pre-existing collection '{args.collection}'")
        utility.drop_collection(args.collection)

    schema = CollectionSchema([
        FieldSchema("id", DataType.INT64, is_primary=True, auto_id=False),
        FieldSchema("worker_id", DataType.INT64),
        FieldSchema("seq", DataType.INT64),
        FieldSchema("embedding", DataType.FLOAT_VECTOR, dim=args.dim),
    ])
    coll = Collection(args.collection, schema)
    coll.create_index(
        "embedding",
        {"index_type": "HNSW", "metric_type": "L2",
         "params": {"M": 16, "efConstruction": 200}},
    )
    coll.load()
    print(f"collection '{args.collection}' ready (dim={args.dim})")

    stop_evt = threading.Event()
    counters: dict[str, int] = Counter()
    error_samples: dict[str, list[str]] = defaultdict(list)
    counters_lock = threading.Lock()

    def record(key: str, *, error: str | None = None) -> None:
        """Bump a counter; optionally collect a small sample of error
        strings (capped at 10 per category to keep the report small)."""
        with counters_lock:
            counters[key] += 1
            if error and len(error_samples[key]) < 10:
                error_samples[key].append(error[:200])

    next_id = [0]
    next_id_lock = threading.Lock()

    def claim_id_range(n: int) -> tuple[int, int]:
        """Atomically claim a contiguous [start, end) range of integer
        IDs. Avoids collisions across insert workers."""
        with next_id_lock:
            start = next_id[0]
            next_id[0] += n
            return (start, start + n)

    def insert_worker(worker_id: int) -> None:
        """Push 100-row batches as fast as latency allows until stop."""
        while not stop_evt.is_set():
            batch = 100
            start, end = claim_id_range(batch)
            ids = list(range(start, end))
            workers = [worker_id] * batch
            seqs = list(range(batch))
            embs = [
                [random.random() for _ in range(args.dim)]
                for _ in range(batch)
            ]
            counters_attempted_key = "inserts_attempted"
            with counters_lock:
                counters[counters_attempted_key] += batch
            try:
                coll.insert([ids, workers, seqs, embs])
                with counters_lock:
                    counters["inserts_ok"] += batch
            except Exception as e:
                record(
                    "inserts_failed", error=f"{type(e).__name__}: {e}"
                )
                with counters_lock:
                    counters["inserts_failed_count"] += batch

    def search_worker(worker_id: int) -> None:
        """Run periodic ANN searches; each is a single 5-NN top-k."""
        while not stop_evt.is_set():
            query = [[random.random() for _ in range(args.dim)]]
            with counters_lock:
                counters["searches_attempted"] += 1
            try:
                coll.search(
                    data=query, anns_field="embedding",
                    param={"metric_type": "L2", "params": {"ef": 32}},
                    limit=5,
                )
                with counters_lock:
                    counters["searches_ok"] += 1
            except Exception as e:
                record(
                    "searches_failed", error=f"{type(e).__name__}: {e}"
                )
            time.sleep(0.1)

    threads: list[threading.Thread] = []
    for i in range(args.insert_workers):
        t = threading.Thread(target=insert_worker, args=(i,), daemon=True)
        threads.append(t)
        t.start()
    for i in range(args.search_workers):
        t = threading.Thread(target=search_worker, args=(i,), daemon=True)
        threads.append(t)
        t.start()

    def install_sigterm() -> None:
        """Stop cleanly on SIGTERM/SIGINT so the report still gets
        written (operator may interrupt mid-run)."""
        def handler(signum, frame):  # noqa: ANN001
            stop_evt.set()
        signal.signal(signal.SIGINT, handler)
        signal.signal(signal.SIGTERM, handler)

    install_sigterm()

    print(f"running for {args.duration_s}s with "
          f"{args.insert_workers} insert / {args.search_workers} search workers")
    started_at = time.time()
    try:
        while time.time() - started_at < args.duration_s and not stop_evt.is_set():
            time.sleep(1)
            elapsed = int(time.time() - started_at)
            if elapsed % 10 == 0:
                with counters_lock:
                    snap = dict(counters)
                print(
                    f"  t={elapsed:3d}s  "
                    f"inserts ok/failed={snap.get('inserts_ok', 0)}/"
                    f"{snap.get('inserts_failed_count', 0)}  "
                    f"searches ok/failed={snap.get('searches_ok', 0)}/"
                    f"{snap.get('searches_failed', 0)}"
                )
    finally:
        stop_evt.set()

    print("waiting for workers to drain...")
    for t in threads:
        t.join(timeout=10)

    # Final flush + count check.
    try:
        coll.flush()
        coll.load()
        time.sleep(2)
        row_count = coll.num_entities
    except Exception as e:
        print(f"final flush/count failed: {e}", file=sys.stderr)
        row_count = -1

    with counters_lock:
        counters_snap = dict(counters)

    expected = counters_snap.get("inserts_ok", 0)
    diff = (row_count - expected) if row_count >= 0 else None

    report = {
        "uri": args.uri,
        "collection": args.collection,
        "duration_s": args.duration_s,
        "insert_workers": args.insert_workers,
        "search_workers": args.search_workers,
        "counters": counters_snap,
        "row_count_after": row_count,
        "expected_row_count": expected,
        "diff": diff,
        "error_samples": dict(error_samples),
    }

    print()
    print("=" * 60)
    print(f"REPORT")
    print(f"  inserts ok/failed: {counters_snap.get('inserts_ok', 0)} / "
          f"{counters_snap.get('inserts_failed_count', 0)}")
    print(f"  searches ok/failed: {counters_snap.get('searches_ok', 0)} / "
          f"{counters_snap.get('searches_failed', 0)}")
    print(f"  row_count_after: {row_count}")
    print(f"  expected: {expected}")
    print(f"  diff: {diff}  "
          f"({'data loss!' if diff is not None and diff < 0 else 'OK'})")
    print("=" * 60)

    if args.report:
        with open(args.report, "w") as f:
            json.dump(report, f, indent=2)
        print(f"  report written to {args.report}")

    return 0


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--uri", default="http://127.0.0.1:19537")
    p.add_argument("--collection", default="load_test")
    p.add_argument("--dim", type=int, default=8)
    p.add_argument("--insert-workers", type=int, default=4)
    p.add_argument("--search-workers", type=int, default=2)
    p.add_argument("--duration-s", type=int, default=120)
    p.add_argument("--report", default="/tmp/load_report.json")
    return p.parse_args()


if __name__ == "__main__":
    sys.exit(main())
