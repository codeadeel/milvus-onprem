"""Worker for the `remove-node` job type.

Graceful peer removal. Order matters — getting this wrong loses data:

  1. Validate: peer is in topology, isn't the only peer, isn't the
     current leader (operator should failover first).
  2. Decommission the leaving peer's MinIO pool. `mc admin decommission
     start` flags the pool, blocks new writes to it, and starts copying
     data to other pools. Slow on big clusters; near-instant on a
     fresh test cluster.
  3. Poll `mc admin decommission status` until complete. Required —
     stopping the pool's MinIO before decommission is done loses the
     un-copied data.
  4. etcd member-remove (clean Raft exit; updates membership before
     the etcd container goes away).
  5. Delete the topology entry. The watcher on every remaining peer
     fires: re-render (smaller MINIO_VOLUMES + nginx upstream) plus
     MinIO recreate. The leaving peer is now orphaned at the
     control-plane level.
  6. The leaving peer's containers are still running; operator runs
     `./milvus-onprem teardown --full --force` on that VM to clean
     up. We can't do this remotely — daemon-to-daemon docker exec is
     a v1.2 concern, and even then the local daemon would be stopping
     itself.

Refuses to remove if the cluster would have <1 peer after, or if the
target is the current leader (operator should failover first).
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from typing import Any

from ..jobs import JobContext, register_handler
from ..topology import TOPOLOGY_PREFIX

log = logging.getLogger("daemon.workers.remove_node")


async def run_remove_node(ctx: JobContext) -> None:
    """Execute the remove-node sequence; raise on any unrecoverable step."""
    target_ip = ctx.job.params.get("ip")
    if not target_ip:
        raise ValueError("remove-node requires an 'ip' param")

    # Need direct access to etcd + the daemon's own state; the worker
    # imports app lazily so it doesn't pull a circular import at module
    # load.
    from daemon.main import app
    etcd = app.state.etcd
    leader = app.state.leader
    config = app.state.config
    topology = app.state.topology

    # 1. Validate against the in-memory topology mirror (fresh after the
    #    watcher seeded itself at startup).
    target_name = _find_node_name_by_ip(topology.peers, target_ip)
    if target_name is None:
        raise ValueError(
            f"no peer found with ip={target_ip}; topology has: "
            f"{sorted({p.get('ip') for p in topology.peers.values()})}"
        )
    ctx.log_writer(f"resolved {target_ip} -> {target_name}")

    if topology.peer_count <= 1:
        raise ValueError(
            "refusing to remove the only peer in the cluster — that would "
            "destroy the cluster. teardown the whole cluster instead."
        )

    if leader.is_leader is False:
        raise PermissionError(
            "remove-node must run on the leader (HTTP layer should redirect)"
        )
    leader_info_raw = await etcd.get("/cluster/leader")
    if leader_info_raw:
        try:
            li = json.loads(leader_info_raw)
            if li.get("ip") == target_ip or li.get("node_name") == target_name:
                # Self-removal of the current leader: voluntarily step
                # down, wait for a peer to take over, then re-route the
                # remove-node job to that new leader so the worker runs
                # on a non-target peer. This used to refuse with an
                # operator-facing message that asked the operator to
                # `docker stop` the daemon on a specific peer; now the
                # daemon orchestrates the failover itself.
                #
                # `_failover_attempted` flag in params guards against an
                # infinite loop if the new leader is again the target
                # (shouldn't happen because of the cooldown in
                # LeaderElector.step_down, but defensive).
                if ctx.job.params.get("_failover_attempted"):
                    raise PermissionError(
                        f"refusing to remove {target_name}: re-attempt "
                        f"after self-failover still landed on the target. "
                        f"Cluster may have only this peer eligible — "
                        f"verify topology and try again."
                    )
                ctx.log_writer(
                    f"target {target_name} is the current leader; "
                    f"stepping down and re-routing the job to a peer"
                )
                if not await leader.step_down(cooldown_s=20.0):
                    raise PermissionError(
                        f"refusing to remove {target_name}: "
                        f"step_down failed (already a follower? cluster "
                        f"is in transient state — retry shortly)."
                    )
                new_leader_ip = await _wait_new_leader(
                    etcd, exclude_ip=target_ip, timeout_s=30.0
                )
                if new_leader_ip is None:
                    raise RuntimeError(
                        "self-failover: no new leader elected within 30s "
                        "after stepping down. Cluster may need manual "
                        "intervention."
                    )
                ctx.log_writer(
                    f"new leader is {new_leader_ip}; forwarding "
                    f"remove-node job"
                )
                forwarded_id = await _forward_remove_node(
                    new_leader_ip,
                    target_ip,
                    config.cluster_token,
                    config.listen_port,
                )
                ctx.log_writer(
                    f"forwarded as job {forwarded_id} on the new leader"
                )
                await _wait_forwarded_job(
                    new_leader_ip,
                    forwarded_id,
                    config.cluster_token,
                    config.listen_port,
                    log_writer=ctx.log_writer,
                )
                return
        except json.JSONDecodeError:
            pass

    ctx.log_writer(f"removing peer {target_name} @ {target_ip} from cluster of {topology.peer_count}")
    ctx.progress_setter(0.05)

    # 2. Decommission the leaving peer's MinIO pool.
    pool_url_pattern = (
        f"http://{target_ip}:{_minio_api_port()}/drive{{1...4}}"
    )
    target_pool_url_fragment = f"{target_ip}:{_minio_api_port()}/drive"

    # mc alias prep (no-op after first run; cheap to repeat).
    await _run(
        f"docker exec milvus-minio mc alias set local "
        f"http://127.0.0.1:{_minio_api_port()} "
        f"{_minio_access()} {_minio_secret()}"
    )

    # Pre-flight: check current decommission state. Only skip the
    # `start` call for states where issuing it would be wrong:
    #   complete  — pool already drained, calling start would error
    #   active    — already in progress, calling start would error
    # All other states ("none", "missing", "failed", "canceled") mean
    # we need to issue the start call. "failed"/"canceled" require an
    # explicit `cancel` first to clear the previous attempt.
    pool_state = await _decommission_state(target_pool_url_fragment)
    ctx.log_writer(f"current decommission state for pool: {pool_state}")

    if pool_state == "complete":
        ctx.log_writer("(pool already decommissioned — skipping start)")
    elif pool_state == "active":
        ctx.log_writer("(pool decommission already in progress — skipping start)")
    else:
        if pool_state in ("failed", "canceled"):
            ctx.log_writer(
                f"clearing previous {pool_state} decommission attempt"
            )
            await _run(
                f"docker exec milvus-minio mc admin decommission cancel local "
                f"'{pool_url_pattern}'"
            )
        ctx.log_writer(f"==> mc admin decommission start pool={pool_url_pattern}")
        rc, out, err = await _run(
            f"docker exec milvus-minio mc admin decommission start local "
            f"'{pool_url_pattern}'"
        )
        ctx.log_writer(out.rstrip())
        combined = (out + err).lower()
        if rc != 0 and not any(
            s in combined for s in (
                "already decommissioning",
                "already decommissioned",
                "no pool",
            )
        ):
            raise RuntimeError(
                f"mc admin decommission start failed (rc={rc}): "
                f"{err.strip()[:300]}"
            )
    ctx.progress_setter(0.10)

    # 3. Poll status until the LEAVING POOL reports complete.
    #    Reads JSON via _decommission_state — the human-readable table
    #    misleads (every pool shows "Active" by default, meaning
    #    "online/serving", not "decommissioning in progress").
    ctx.log_writer("==> waiting for decommission to complete (poll every 5s)")
    deadline = 30 * 60
    elapsed = 0
    while True:
        state = await _decommission_state(target_pool_url_fragment)
        if state == "complete":
            ctx.log_writer("decommission complete")
            break
        if state == "missing":
            # Pool no longer in the status table — could mean it was
            # already removed / never existed. Treat as done.
            ctx.log_writer("(pool not in status table — assuming done)")
            break
        if state == "failed":
            raise RuntimeError(
                "MinIO decommission FAILED. Inspect with "
                "`docker exec milvus-minio mc admin decommission status local --json` "
                "and consider `cancel` + retry once root cause is addressed."
            )
        if state == "canceled":
            raise RuntimeError(
                "MinIO decommission was CANCELLED externally. Restart the "
                "remove-node job to reissue the start command."
            )
        if state == "none":
            # Should not happen after step 2, but guards against a
            # follower that lost its mc state (e.g. minio container
            # restarted mid-decommission, dropping in-memory progress).
            raise RuntimeError(
                "MinIO reports no decommission scheduled for the target "
                "pool. The decommission may have been silently dropped — "
                "rerun remove-node to reissue."
            )
        # state == "active" — keep polling.
        if elapsed >= deadline:
            raise RuntimeError(
                "MinIO decommission did not complete within 30 min — abort. "
                "operator can run "
                "`docker exec milvus-minio mc admin decommission status local --json` "
                "to inspect; rerun once data movement settles."
            )
        ctx.progress_setter(min(0.6, 0.10 + (elapsed / deadline) * 0.5))
        await asyncio.sleep(5)
        elapsed += 5

    ctx.progress_setter(0.70)

    # 4. etcd member-remove — find the member by peer URL, then delete.
    ctx.log_writer(f"==> etcd member-remove for {target_name}")
    member_id = await _find_etcd_member_id_by_peer_url(
        etcd, target_ip, _etcd_peer_port()
    )
    if member_id is None:
        ctx.log_writer(
            f"WARN: no etcd member found with peer-url for {target_ip}; "
            "skipping etcd-side remove (membership may already be clean)"
        )
    else:
        ctx.log_writer(f"removing etcd member id={member_id:x}")
        try:
            await etcd._post(
                "/v3/cluster/member/remove", {"ID": member_id}
            )
        except Exception as e:
            raise RuntimeError(f"etcd member-remove failed: {e}") from e
    ctx.progress_setter(0.90)

    # 5. Delete topology entry. Watchers on remaining peers will fire,
    #    re-render, nginx-reload, MinIO recreate (now without the
    #    leaving pool — format.json on remaining drives still says it
    #    used to be N pools, but MinIO with one fewer pool definition
    #    accepts that the missing one is decommissioned).
    ctx.log_writer(f"==> deleting topology entry for {target_name}")
    await etcd.delete(TOPOLOGY_PREFIX + target_name)

    ctx.progress_setter(1.0)
    ctx.log_writer("")
    ctx.log_writer(f"OK {target_name} ({target_ip}) removed from the cluster.")
    ctx.log_writer("")
    ctx.log_writer(f"Operator follow-up — on the leaving VM ({target_ip}), clean up its")
    ctx.log_writer("containers and data:")
    ctx.log_writer("    ./milvus-onprem teardown --full --force")
    ctx.log_writer("")
    ctx.log_writer("(daemon-to-daemon teardown of a leaving peer is a future feature)")


# ── helpers ──────────────────────────────────────────────────────────


async def _decommission_state(target_url_fragment: str) -> str:
    """Return the decommission state for the pool whose URL contains
    `target_url_fragment` (e.g. "10.0.0.5:9000/drive").

    Possible return values:
      "none"     — no decommission has been started for this pool
      "active"   — decommission started, in progress
      "complete" — decommission finished successfully
      "failed"   — decommission errored
      "canceled" — decommission was cancelled
      "missing"  — pool not present in the status output

    Uses `mc admin decommission status --json` because the
    human-readable table is misleading: every pool's "Status" column
    shows "Active" by default (meaning "online + serving"), not
    "decommissioning in progress." JSON exposes the per-pool
    `decommissionInfo.{startTime, complete, failed, canceled}` fields
    which are unambiguous.
    """
    import json as _json

    rc, out, err = await _run(
        "docker exec milvus-minio mc admin decommission status local --json"
    )
    if rc != 0:
        # mc returns non-zero with a clear message when nothing's been
        # decommissioned ever; treat as "no pool", caller decides.
        if "no decommission" in (out + err).lower():
            return "none"

    try:
        pools = _json.loads(out) if out.strip() else []
    except _json.JSONDecodeError:
        # mc may produce non-json prefix; try to find the array.
        return "missing"

    for pool in pools:
        cmdline = pool.get("cmdline", "")
        if target_url_fragment not in cmdline:
            continue
        info = pool.get("decommissionInfo") or {}
        if info.get("complete"):
            return "complete"
        if info.get("failed"):
            return "failed"
        if info.get("canceled"):
            return "canceled"
        # Decommission counts as "in progress" once startTime moves
        # off the epoch-zero default. Otherwise it hasn't been
        # started — caller should call `decommission start`.
        start = info.get("startTime", "")
        if start and not start.startswith("0001-01-01"):
            return "active"
        return "none"

    return "missing"


def _find_node_name_by_ip(
    peers: dict[str, dict[str, Any]], ip: str
) -> str | None:
    """Reverse-lookup a node's name from its IP in the topology mirror."""
    for name, info in peers.items():
        if info.get("ip") == ip:
            return name
    return None


async def _find_etcd_member_id_by_peer_url(
    etcd, ip: str, peer_port: int
) -> int | None:
    """Look up an etcd member's numeric ID by its peer URL.

    The HTTP gateway returns IDs as decimal strings — we parse to int
    so the subsequent member/remove call accepts the right shape.
    """
    members = await etcd.member_list()
    needle = f"http://{ip}:{peer_port}"
    for m in members:
        urls = m.get("peerURLs") or []
        if any(u == needle for u in urls):
            return int(m.get("ID"))
    return None


async def _run(cmd: str) -> tuple[int, str, str]:
    """Run a bash command, return (rc, stdout, stderr)."""
    proc = await asyncio.create_subprocess_shell(
        cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        executable="/bin/bash",
    )
    stdout, stderr = await proc.communicate()
    return (
        proc.returncode if proc.returncode is not None else -1,
        stdout.decode(errors="replace"),
        stderr.decode(errors="replace"),
    )


def _read_cluster_env_value(key: str, default: str = "") -> str:
    """Read a single KEY=VALUE from the bind-mounted cluster.env."""
    try:
        with open("/etc/milvus-onprem/cluster.env") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                if k.strip() == key:
                    return v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return default


def _minio_api_port() -> str:
    return _read_cluster_env_value("MINIO_API_PORT", "9000")


def _etcd_peer_port() -> int:
    return int(_read_cluster_env_value("ETCD_PEER_PORT", "2380"))


def _minio_access() -> str:
    return _read_cluster_env_value("MINIO_ACCESS_KEY", "minioadmin")


def _minio_secret() -> str:
    return _read_cluster_env_value("MINIO_SECRET_KEY", "")


# ── self-failover helpers (for remove-node-of-leader) ──────────────────


async def _wait_new_leader(
    etcd: Any, exclude_ip: str, timeout_s: float
) -> str | None:
    """Poll /cluster/leader until a leader OTHER THAN `exclude_ip` is set.

    Returns the new leader's IP, or None on timeout. `exclude_ip` is
    the peer we just stepped down (the remove-node target) — we want
    to wait until a different peer takes over before forwarding the
    job, otherwise we'd just bounce right back to the same daemon.
    """
    import json as _json
    deadline = asyncio.get_event_loop().time() + timeout_s
    while asyncio.get_event_loop().time() < deadline:
        raw = await etcd.get("/cluster/leader")
        if raw:
            try:
                info = _json.loads(raw)
                ip = info.get("ip", "")
                if ip and ip != exclude_ip:
                    return ip
            except _json.JSONDecodeError:
                pass
        await asyncio.sleep(1)
    return None


async def _forward_remove_node(
    leader_ip: str,
    target_ip: str,
    cluster_token: str,
    listen_port: int,
) -> str:
    """POST a fresh remove-node job at the new leader; return its job-id.

    Marks `_failover_attempted=True` in params so the new leader's
    worker won't try its own self-failover dance if (somehow) the
    target is still its leader.
    """
    import httpx
    body = {
        "type": "remove-node",
        "params": {
            "ip": target_ip,
            "_failover_attempted": True,
        },
    }
    url = f"http://{leader_ip}:{listen_port}/jobs"
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            url,
            headers={"Authorization": f"Bearer {cluster_token}"},
            json=body,
        )
        resp.raise_for_status()
        return resp.json()["id"]


async def _wait_forwarded_job(
    leader_ip: str,
    job_id: str,
    cluster_token: str,
    listen_port: int,
    log_writer: Any,
    timeout_s: float = 60 * 60,
) -> None:
    """Poll the new leader for the forwarded job until done; raise on
    failure so the original CLI sees the same error context."""
    import httpx
    url = f"http://{leader_ip}:{listen_port}/jobs/{job_id}"
    deadline = asyncio.get_event_loop().time() + timeout_s
    last_log_len = 0
    async with httpx.AsyncClient(timeout=30.0) as client:
        while asyncio.get_event_loop().time() < deadline:
            resp = await client.get(
                url,
                headers={"Authorization": f"Bearer {cluster_token}"},
            )
            resp.raise_for_status()
            data = resp.json()
            log_lines = data.get("log_lines") or []
            if len(log_lines) > last_log_len:
                for line in log_lines[last_log_len:]:
                    log_writer(f"[forwarded] {line.rstrip()}")
                last_log_len = len(log_lines)
            state = data.get("state")
            if state == "done":
                return
            if state in ("failed", "cancelled"):
                err = data.get("error") or "(no error message)"
                raise RuntimeError(
                    f"forwarded remove-node job on {leader_ip} {state}: {err}"
                )
            await asyncio.sleep(2)
    raise RuntimeError(
        f"forwarded remove-node job on {leader_ip} did not finish "
        f"within {timeout_s}s"
    )


register_handler("remove-node", run_remove_node)
