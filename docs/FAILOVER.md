# Failover behavior

What this cluster does when a node dies, how to observe it, and what
the SDK caller is expected to handle. Findings are from the 3-node
failover drill on real GCP VMs (m1/m2/m3), Apr 2026.

## Summary

| Topology | Recovery window | First-read failure mode | Operator action |
|---|---|---|---|
| **Milvus 2.6 + Woodpecker** | ~0s observed | none — bare reads keep working | bring node back; auto-rejoin |
| **Milvus 2.5 + Pulsar** (default cfg) | ~50s | `code=106 collection on recovering` until querycoord rebalances channels | retry with backoff; bring node back |
| **Milvus 2.5 + Pulsar** (tuned cfg) | ~15–20s | same `code=106` window, just shorter | same as above |

The watchdog (`milvus-onprem watchdog`, optionally as a systemd unit
via `install --with-watchdog`) emits a `PEER_DOWN_ALERT` after
`WATCHDOG_FAILURE_THRESHOLD` consecutive misses (default 6 × 5s = 30s)
on **any** topology. It is independent of Milvus's own failure
detection and is purely an alerting loop.

## What's actually happening

When a node dies, three failure-detection layers work independently:

1. **etcd Raft** — etcd peers lose contact with the dead member's
   lease in milliseconds; quorum holds with `(N-1)/2` member loss.
2. **MinIO erasure coding** — surviving drives keep serving reads/
   writes for the missing share; degraded mode is transparent.
3. **Milvus session/health** — coord and node sessions in etcd have
   a TTL (`common.session.ttl`, default 30s). The lease only expires
   *after* the TTL, then querycoord runs its node-session check
   (`queryCoord.checkNodeSessionInterval`, default 60s) and starts
   reassigning DML channels to surviving querynodes. **In-flight
   reads during this window get `code=106 collection on recovering`.**

On 2.6 the per-node `milvus run standalone` binary co-locates its own
coord + querynode + streamingnode (Woodpecker WAL), so when a node
dies the surviving nodes' replicas keep serving without waiting for a
centralized querycoord to re-shuffle channel ownership. Failover is
invisible to the SDK in our drills.

## SDK-side: retry on recovery errors

The canonical fix is client-side retry with backoff. A small helper
ships in [`test/tutorial/_shared.py`](../test/tutorial/_shared.py):

```python
from _shared import retry_on_recovering
hits = retry_on_recovering(lambda: client.search(...))
```

It only retries known recovery-class messages (`recovering`,
`no available`, `channel not available`, `channel checker not ready`)
and re-raises everything else, so real bugs still surface. Default
budget is 120s. It's defense-in-depth on 2.6 but **load-bearing on 2.5**.

## Server-side: tuning 2.5 for faster recovery

`templates/2.5/milvus.yaml.tpl` ships these tightened defaults:

```yaml
common:
  session:
    ttl: 10                         # was 30 — etcd lease expires faster
queryCoord:
  checkNodeSessionInterval: 10      # was 60 — detect dead node sooner
  heartbeatAvailableInterval: 5000  # was 10000 — shorter heartbeat window
```

Effect: the `code=106` window observed in 3-node drills drops from
~50s (untuned) to ~15-20s.

**Tradeoff: tighter timeouts mean a higher chance of false-positive
eviction under transient network jitter.** On a LAN with sub-ms
latency this is fine. Over WAN with bursty packet loss, lift the
values closer to defaults. Edit `templates/2.5/milvus.yaml.tpl`,
re-render with `milvus-onprem render`, and `up` to apply.

2.6 doesn't ship these tunings — Woodpecker bypasses the channel-
reassignment path entirely, so they wouldn't change anything observable.

## Watchdog observation

The watchdog runs on each peer and alerts when **other** peers stop
answering on the Milvus port. To observe a node going down:

```bash
# install on every node, alert-only mode
./milvus-onprem install --with-watchdog
journalctl -u milvus-watchdog -f | grep PEER_
```

A `PEER_DOWN_ALERT` line includes the offline peer's IP, the local
observer's name, and the consecutive-failure count. A matching
`PEER_UP_ALERT` fires when the peer comes back, with `was_down_for_s`
measured from the down-alert time. Both alerts are single-line and
greppable.

The watchdog deliberately does not auto-recover — `WATCHDOG_MODE=auto`
is reserved for future work and currently behaves identically to
`monitor`. Recovery is operator-driven (bring the node back; the rest
is automatic).

## Recovery procedure

For a transient outage (reboot, cable, container OOM):

1. **Don't panic.** Cluster keeps serving reads (writes too on 2.6;
   on 2.5 if the dead node isn't `PULSAR_HOST`).
2. **Retry SDK calls** that raised `code=106` — most succeed within
   ~20s on tuned 2.5, immediately on 2.6. Use `retry_on_recovering`.
3. **Bring the node back**: `./milvus-onprem up` on the recovered
   node. `restart: always` on the containers means a simple
   `systemctl start docker` is often enough after a host reboot.
4. **Verify**: `./milvus-onprem status` from any peer should show all
   peers green. `wait` should converge in seconds.
5. **Cross-peer consistency check**: run
   `test/tutorial/05_prove_replication.py` to confirm every peer
   returns the same hits for the same query.

For a permanently-lost node (disk failure, reimage), the procedure
involves `etcdctl member remove` + a fresh init/join — see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) (planned section).
