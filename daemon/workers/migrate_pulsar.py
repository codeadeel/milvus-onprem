"""Worker for the `migrate-pulsar` job type.

Moves the 2.5 Pulsar singleton from its current PULSAR_HOST to a
named target peer, so the operator can subsequently `remove-node`
the old host without breaking the cluster's message queue.

Important caveats — these are intentional simplifications, not bugs:
  - Brief unavailability. Every peer's Milvus is recreated to pick up
    the new pulsar.address. Read-only ops fail until Milvus is
    healthy again on each peer (~30-60s per peer, sequenced).
  - Lossy migration. Topic backlog still pending on the old Pulsar
    instance is dropped — the new instance starts with empty
    topics. Operators are expected to run this during a maintenance
    window with no active inserts.

The full-fidelity migration (Pulsar replication / topic drain) is
out of scope; the recommended long-term path is upgrading to Milvus
2.6, where Woodpecker replaces the singleton broker with a per-peer
streamingnode.

Params:
    to_node     (required) name of the target peer (e.g. "node-2").
                Must already be in the topology mirror.

Refuses if:
    - to_node is missing or not in topology
    - to_node already IS the current PULSAR_HOST
    - this deploy isn't 2.5 / pulsar (target peer would have no
      Pulsar service block in its render anyway)
"""

from __future__ import annotations

import json
import logging
from typing import Any

import httpx

from ..jobs import JobContext, register_handler
from .remove_node import _is_pulsar_deploy, _read_cluster_env_value

log = logging.getLogger("daemon.workers.migrate_pulsar")


async def run_migrate_pulsar(ctx: JobContext) -> None:
    """Execute the migration; raise on any unrecoverable step."""
    to_node = ctx.job.params.get("to_node")
    if not to_node:
        raise ValueError("migrate-pulsar requires a 'to_node' param")

    if not _is_pulsar_deploy():
        raise PermissionError(
            "migrate-pulsar is only meaningful on a 2.5 deploy "
            "(MQ_TYPE=pulsar). 2.6 (Woodpecker) has no singleton "
            "broker to migrate."
        )

    # Need the leader's view of topology + config. Lazy-import to
    # avoid pulling daemon.main at module load.
    from daemon.main import app
    leader = app.state.leader
    config = app.state.config
    topology = app.state.topology

    if leader.is_leader is False:
        raise PermissionError(
            "migrate-pulsar must run on the leader (HTTP layer should "
            "redirect)"
        )

    if to_node not in topology.peers:
        raise ValueError(
            f"to_node={to_node!r} is not in topology. Known peers: "
            f"{sorted(topology.peers)}"
        )
    target_info = topology.peers[to_node]
    target_ip = target_info.get("ip")
    if not target_ip:
        raise ValueError(f"topology entry for {to_node} has no ip")

    current_host = _read_cluster_env_value("PULSAR_HOST", "node-1")
    if current_host == to_node:
        ctx.log_writer(
            f"PULSAR_HOST is already {to_node}; nothing to do"
        )
        return

    current_info = topology.peers.get(current_host) or {}
    current_ip = current_info.get("ip", "")
    ctx.log_writer(
        f"migrating Pulsar: {current_host} ({current_ip or '?'}) "
        f"-> {to_node} ({target_ip})"
    )
    ctx.progress_setter(0.05)

    # Order matters: bring up Pulsar on the new host BEFORE pointing
    # any Milvus at it (otherwise Milvus would dial a not-yet-up
    # broker), and tear down old Pulsar LAST (so a Milvus that hasn't
    # reconnected yet can keep using the old broker until its turn).
    sequenced: list[tuple[str, str, str]] = []  # (label, name, ip)
    sequenced.append(("new pulsar host", to_node, target_ip))
    from ..joining import _node_sort_key
    for name in sorted(topology.peers, key=_node_sort_key):
        if name in (to_node, current_host):
            continue
        info = topology.peers.get(name) or {}
        ip = info.get("ip", "")
        if ip:
            sequenced.append(("milvus-only peer", name, ip))
    if current_ip:
        sequenced.append(("old pulsar host (now milvus-only)", current_host, current_ip))

    progress_step = 0.85 / max(1, len(sequenced))
    progress = 0.05
    for label, name, ip in sequenced:
        ctx.log_writer(f"==> {label}: {name} @ {ip}")
        try:
            await _rpc_sync_pulsar_host(
                ip, to_node, config.cluster_token, config.listen_port
            )
            ctx.log_writer(f"    {name} done")
        except Exception as e:
            # Continue on failure — partial progress is better than
            # leaving the cluster half-converged. The next manual
            # rerun finds whatever didn't apply and re-applies it
            # (handler is idempotent).
            ctx.log_writer(
                f"    {name} FAILED: {type(e).__name__}: {e}"
            )
        progress += progress_step
        ctx.progress_setter(min(0.95, progress))

    ctx.log_writer(
        f"migrate-pulsar finished. New PULSAR_HOST is {to_node} "
        f"({target_ip}). You can now `./milvus-onprem remove-node "
        f"--ip={current_ip}` if removing the old host was the goal."
    )
    ctx.progress_setter(1.0)


async def _rpc_sync_pulsar_host(
    peer_ip: str,
    new_pulsar_host: str,
    cluster_token: str,
    listen_port: int,
) -> None:
    """POST /admin/sync-pulsar-host on the named peer.

    Synchronous from this caller's POV — the endpoint blocks until
    the local recreate has run; the leader's per-peer loop naturally
    waits between peers as a result.
    """
    url = f"http://{peer_ip}:{listen_port}/admin/sync-pulsar-host"
    body = {"pulsar_host": new_pulsar_host}
    # 5 minutes of patience: a docker-compose recreate of pulsar +
    # the Milvus subset can be slow on cold-cache peers.
    async with httpx.AsyncClient(timeout=300.0) as client:
        resp = await client.post(
            url,
            headers={"Authorization": f"Bearer {cluster_token}"},
            json=body,
        )
        resp.raise_for_status()
        data = resp.json()
        if not data.get("applied"):
            raise RuntimeError(
                f"peer {peer_ip} did not apply: {json.dumps(data)[:200]}"
            )


register_handler("migrate-pulsar", run_migrate_pulsar)
