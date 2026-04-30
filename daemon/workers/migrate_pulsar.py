"""Worker for the `migrate-pulsar` job type.

Moves the 2.5 Pulsar singleton from its current PULSAR_HOST to a
named target peer, so the operator can subsequently `remove-node`
the old host without breaking the cluster's message queue.

Production-grade discipline (the 1729afb / fcd773c / b965560 series
established the pattern; this worker follows it explicitly):

  1. AUTHORITATIVE SNAPSHOT — read topology directly from etcd
     (linearizable get_prefix), not from the watcher's mirror. The
     watcher is eventually consistent; a peer that just finished
     /join may not have triggered the watcher event yet, and
     trusting the mirror would silently skip that peer (split-brain
     Pulsar).

  2. PREFLIGHT — every peer's daemon must answer /health within a
     short timeout. If any are unreachable, ABORT before any side
     effects. The operator can re-run after the cluster settles.
     Half-applied migration leaves Milvus on different peers
     pointing at different brokers — much worse than no migration.

  3. PER-PEER FAIL-LOUD — apply errors raise. The job state surfaces
     the failed peer to the operator. Continuing past a failure
     would leave the cluster split between peers that successfully
     reconfigured and those that didn't.

  4. POST-VERIFY — after the apply sweep, re-read every peer's
     PULSAR_HOST via the new /admin/get-pulsar-host endpoint and
     fail unless every survivor reports the new value. Catches the
     case where a peer's apply call returned 200 but the file write
     was somehow lost.

Caveats called out in the CLI --help (intentional simplifications,
not bugs):
  - Brief unavailability per peer during recreate (~30-60s each).
  - Lossy: Pulsar topic backlog still pending on the old broker is
    dropped — the new broker starts with empty topics. Operators
    are expected to run during a maintenance window with no active
    inserts.

Params:
    to_node     (required) name of the target peer (e.g. "node-2").
                Must be in the authoritative topology snapshot.
"""

from __future__ import annotations

import asyncio
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

    # Step 1 — AUTHORITATIVE SNAPSHOT. The watcher's mirror is
    # eventually consistent; a peer whose /join just finished may
    # have committed its topology PUT but not yet fired the watcher
    # event on this leader. Iterating `topology.peers` would skip it.
    peers = await topology.authoritative_peers()
    ctx.log_writer(
        f"authoritative topology: {len(peers)} peers — "
        f"{sorted(peers)}"
    )

    if to_node not in peers:
        raise ValueError(
            f"to_node={to_node!r} is not in topology. Known peers: "
            f"{sorted(peers)}"
        )
    target_ip = (peers[to_node] or {}).get("ip")
    if not target_ip:
        raise ValueError(f"topology entry for {to_node} has no ip")

    current_host = _read_cluster_env_value("PULSAR_HOST", "node-1")
    if current_host == to_node:
        ctx.log_writer(f"PULSAR_HOST is already {to_node}; nothing to do")
        return

    current_ip = (peers.get(current_host) or {}).get("ip", "")
    ctx.log_writer(
        f"migrating Pulsar: {current_host} ({current_ip or '?'}) "
        f"-> {to_node} ({target_ip})"
    )
    ctx.progress_setter(0.05)

    # `force_when_old_host_dead` lets the auto-migrate-pulsar feature
    # in the watchdog tolerate the OLD pulsar host being unreachable
    # (the entire reason auto-migrate fires is that the host is dead).
    # When set, the preflight allows the old-host to be unreachable
    # but still requires every OTHER peer; the apply skips the dead
    # old host's sync-pulsar-host call (it's gone anyway); the post-
    # verify excludes the dead old host.
    force_when_old_host_dead = bool(
        ctx.job.params.get("force_when_old_host_dead", False)
    )

    # Step 2 — PREFLIGHT. Every peer must be reachable. We refuse to
    # start a migration that we know will leave the cluster split.
    unreachable = await _preflight_peers_reachable(
        peers, config.cluster_token, config.listen_port
    )
    # unreachable items are formatted "<name>@<ip>"; pull just the names.
    unreachable_names = [u.split("@", 1)[0] for u in unreachable]
    if force_when_old_host_dead and unreachable_names == [current_host]:
        ctx.log_writer(
            f"preflight: only the OLD pulsar host {current_host} is "
            f"unreachable; force_when_old_host_dead=true so the migration "
            f"proceeds (the dead host's sync-pulsar-host call will be "
            f"skipped, and post-verify excludes it)"
        )
    elif unreachable:
        raise RuntimeError(
            f"preflight: cannot reach daemon on {len(unreachable)} "
            f"peer(s): {unreachable}. Migration aborted before any "
            f"side effects. Wait for `./milvus-onprem status` to "
            f"report all peers reachable, then retry."
        )
    else:
        ctx.log_writer(f"preflight: all {len(peers)} peers reachable")
    ctx.progress_setter(0.10)

    # Step 3 — APPLY. Order matters: bring up Pulsar on the new host
    # BEFORE pointing any Milvus at it; tear down old Pulsar LAST.
    sequenced: list[tuple[str, str, str]] = []  # (label, name, ip)
    sequenced.append(("new pulsar host", to_node, target_ip))
    from ..joining import _node_sort_key
    for name in sorted(peers, key=_node_sort_key):
        if name in (to_node, current_host):
            continue
        ip = (peers.get(name) or {}).get("ip", "")
        if ip:
            sequenced.append(("milvus-only peer", name, ip))
    if current_ip and not (force_when_old_host_dead and current_host in unreachable_names):
        sequenced.append(
            ("old pulsar host (now milvus-only)", current_host, current_ip)
        )
    elif force_when_old_host_dead and current_host in unreachable_names:
        ctx.log_writer(
            f"skipping apply on dead old pulsar host {current_host} "
            f"(force_when_old_host_dead)"
        )

    progress_step = 0.70 / max(1, len(sequenced))
    progress = 0.10
    for label, name, ip in sequenced:
        ctx.log_writer(f"==> {label}: {name} @ {ip}")
        try:
            await _rpc_sync_pulsar_host(
                ip, to_node, config.cluster_token, config.listen_port
            )
            ctx.log_writer(f"    {name} done")
        except Exception as e:
            # FAIL-LOUD. Partial migration is worse than no migration:
            # peers that already applied point at the new broker;
            # peers that didn't, point at the old. Surface the failure
            # so the operator can fix it (e.g., reboot the stuck
            # peer's daemon) and rerun. The handler is idempotent so
            # rerunning is safe.
            raise RuntimeError(
                f"sync-pulsar-host on {name} ({ip}) failed: "
                f"{type(e).__name__}: {e}. Migration aborted; "
                f"some peers may have applied and some may not. "
                f"Inspect cluster.env on each peer's PULSAR_HOST "
                f"and rerun migrate-pulsar after fixing the stuck "
                f"peer."
            ) from e
        progress += progress_step
        ctx.progress_setter(min(0.85, progress))

    # Step 4 — POST-VERIFY. Read every peer's currently-applied
    # PULSAR_HOST and confirm everyone is on the new value. Catches
    # the path where a sync-pulsar-host returned 200 but the actual
    # cluster.env write didn't take. When force_when_old_host_dead is
    # set, exclude the dead old host (it's not reachable to verify;
    # we'll fix its cluster.env when it comes back via the regular
    # topology-change machinery + a manual re-sync if needed).
    ctx.log_writer("post-verify: confirming PULSAR_HOST on every peer")
    verify_peers = peers
    if force_when_old_host_dead and current_host in unreachable_names:
        verify_peers = {n: i for n, i in peers.items() if n != current_host}
        ctx.log_writer(
            f"post-verify excludes dead old host {current_host} "
            f"(force_when_old_host_dead)"
        )
    mismatches = await _verify_pulsar_host_everywhere(
        verify_peers, to_node, config.cluster_token, config.listen_port
    )
    if mismatches:
        raise RuntimeError(
            f"post-verify FAILED. Expected PULSAR_HOST={to_node} on "
            f"every peer; mismatches: {mismatches}. The cluster is "
            f"in a partially-migrated state — operator action "
            f"required."
        )
    ctx.log_writer(
        f"migrate-pulsar finished. PULSAR_HOST={to_node} ({target_ip}) "
        f"on every peer. You can now `./milvus-onprem remove-node "
        f"--ip={current_ip}` if removing the old host was the goal."
    )
    ctx.progress_setter(1.0)


async def _preflight_peers_reachable(
    peers: dict[str, dict[str, Any]],
    cluster_token: str,
    listen_port: int,
) -> list[str]:
    """Concurrently probe every peer's daemon /health. Return the list
    of peer labels (`<name>@<ip>`) that didn't answer 200 within 5s."""
    async def probe(name: str, ip: str) -> tuple[str, str, bool]:
        url = f"http://{ip}:{listen_port}/health"
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(
                    url,
                    headers={"Authorization": f"Bearer {cluster_token}"},
                )
                return (name, ip, resp.status_code == 200)
        except Exception:
            return (name, ip, False)

    tasks = [
        probe(name, info.get("ip", ""))
        for name, info in peers.items()
        if info.get("ip")
    ]
    results = await asyncio.gather(*tasks)
    return [f"{name}@{ip}" for name, ip, ok in results if not ok]


async def _verify_pulsar_host_everywhere(
    peers: dict[str, dict[str, Any]],
    expected_host: str,
    cluster_token: str,
    listen_port: int,
) -> list[str]:
    """Concurrently fetch each peer's `/admin/get-pulsar-host` and
    return labels of any peer whose PULSAR_HOST differs from
    `expected_host` (or whose endpoint is unreachable)."""
    async def fetch(name: str, ip: str) -> tuple[str, str, str | None]:
        url = f"http://{ip}:{listen_port}/admin/get-pulsar-host"
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(
                    url,
                    headers={"Authorization": f"Bearer {cluster_token}"},
                )
                if resp.status_code != 200:
                    return (name, ip, None)
                return (name, ip, resp.json().get("pulsar_host"))
        except Exception:
            return (name, ip, None)

    tasks = [
        fetch(name, info.get("ip", ""))
        for name, info in peers.items()
        if info.get("ip")
    ]
    results = await asyncio.gather(*tasks)
    return [
        f"{name}@{ip}={got!r}"
        for name, ip, got in results
        if got != expected_host
    ]


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
