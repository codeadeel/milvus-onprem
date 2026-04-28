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
                raise PermissionError(
                    f"refusing to remove {target_name} because it is the "
                    f"current leader. failover first (e.g. `docker stop "
                    f"milvus-onprem-cp` on {target_ip}, wait ~15s, then retry)."
                )
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

    # Pre-flight: check current status — skip start() if the pool is
    # already decommissioned (idempotency on retry).
    pool_state = await _decommission_state(target_pool_url_fragment)
    ctx.log_writer(f"current decommission state for pool: {pool_state}")

    if pool_state == "complete":
        ctx.log_writer("(pool already decommissioned — skipping start)")
    elif pool_state == "active":
        ctx.log_writer("(pool decommission already in progress — skipping start)")
    else:
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

    # 3. Poll status until the LEAVING POOL'S row shows "Complete".
    #    Important: the status table includes every pool — surviving
    #    pools always show "Active". We have to check the specific row
    #    for our target pool, not the whole text.
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
        if elapsed >= deadline:
            raise RuntimeError(
                "MinIO decommission did not complete within 30 min — abort. "
                "operator can run "
                "`docker exec milvus-minio mc admin decommission status local` "
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
    ctx.log_writer("Operator follow-up — on the LEAVING VM, clean up its containers:")
    ctx.log_writer(f"    ssh adeel@{target_ip}")
    ctx.log_writer("    cd /home/adeel/milvus-onprem")
    ctx.log_writer("    ./milvus-onprem teardown --full --force")
    ctx.log_writer("")
    ctx.log_writer("(daemon-to-daemon teardown of a leaving peer is a v1.2 feature)")


# ── helpers ──────────────────────────────────────────────────────────


async def _decommission_state(target_url_fragment: str) -> str:
    """Return the decommission state for the pool whose URL contains
    `target_url_fragment` (e.g. "10.0.0.5:9000/drive").

    Possible return values:
      "active"   — decommission in progress for this pool
      "complete" — decommission finished
      "missing"  — pool not present in the status table (already
                   removed, or never existed)
      "none"     — no decommission has been started

    The mc CLI doesn't expose --json on this subcommand consistently
    across versions, so we parse the text table. Surviving pools'
    rows always show "Active" — we MUST check the specific row for
    our target, not the whole output.
    """
    rc, out, err = await _run(
        "docker exec milvus-minio mc admin decommission status local"
    )
    combined_lower = (out + err).lower()
    if "no decommission" in combined_lower:
        return "none"

    for line in out.splitlines():
        if target_url_fragment not in line:
            continue
        line_lower = line.lower()
        if "complete" in line_lower:
            return "complete"
        if "active" in line_lower:
            return "active"
        # Row exists but neither status keyword present — be conservative
        # and treat as still in progress.
        return "active"

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


register_handler("remove-node", run_remove_node)
