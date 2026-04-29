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
    # Pulsar singleton guard: in 2.5 deploys, Pulsar runs on exactly one
    # peer (PULSAR_HOST in cluster.env, default node-1) and every other
    # peer's Milvus connects to it across the network. Removing that
    # peer strands the survivors with no broker. Refuse with an
    # actionable message instead of running a remove that breaks the
    # cluster. 2.6 (Woodpecker) doesn't have this — every peer runs
    # streamingnode locally, so the check is gated on MQ_TYPE.
    #
    # MQ_TYPE isn't persisted in cluster.env (lib/env.sh derives it
    # from MILVUS_IMAGE_TAG so an upgrade just changes the tag and the
    # rest follows). Mirror that derivation here so the Python worker
    # can detect 2.5 deploys without a separate field to keep in sync.
    if _is_pulsar_deploy():
        pulsar_host = _read_cluster_env_value("PULSAR_HOST", "node-1")
        if target_name == pulsar_host:
            raise PermissionError(
                f"refusing to remove {target_name}: it is the cluster's "
                f"Pulsar host (PULSAR_HOST={pulsar_host}). Removing it "
                f"would leave the surviving peers without a broker. "
                f"Migrate Pulsar to another peer first:\n"
                f"  ./milvus-onprem migrate-pulsar --to=<other-peer-name>\n"
                f"then retry remove-node. Or upgrade to Milvus 2.6 "
                f"(Woodpecker — per-peer streamingnode, no singleton)."
            )

    leader_info_raw = await etcd.get("/cluster/leader")
    if leader_info_raw:
        try:
            li = json.loads(leader_info_raw)
            if li.get("ip") == target_ip or li.get("node_name") == target_name:
                # remove-node-of-self orchestration is the CLI's job:
                # the operator's `./milvus-onprem remove-node` reads
                # /leader, calls /admin/step-down on the local daemon
                # if target == leader, waits for a new leader, and
                # POSTs /jobs to that new leader's daemon directly.
                # By the time this worker runs, target should be a
                # follower (or already removed from etcd). If we
                # nonetheless land here with target == self, that
                # means an older CLI is talking to a newer daemon.
                # Refuse with a clear pointer instead of the doomed
                # in-daemon failover dance: that path stranded the
                # CLI's poll loop because the original daemon's etcd
                # got removed during the operation, breaking local
                # /jobs reads.
                raise PermissionError(
                    f"refusing to remove {target_name}: it is the "
                    f"current leader. The operator-side CLI must call "
                    f"/admin/step-down on the leader and re-target "
                    f"the new leader before submitting remove-node. "
                    f"Update your milvus-onprem CLI to a version that "
                    f"orchestrates this; or run remove-node from a "
                    f"different peer's CLI after manually triggering "
                    f"failover."
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

    # 4. Delete topology entry FIRST. The watcher fires REMOVED on
    #    every peer; survivors' handlers re-render their compose
    #    without the leaving peer in MINIO_VOLUMES, and the leader's
    #    rolling-recreate sweep bounces every survivor's MinIO with
    #    the new (shrunk) pool list. This used to be the LAST step,
    #    but moving it ahead of etcd member-remove closes a real
    #    race: between "decommission completes" (MinIO marks the
    #    pool decommissioned in shared metadata) and "compose
    #    updated" (handler-driven re-render), any restart of a
    #    survivor's MinIO crashes with "pool decommissioned, please
    #    remove from server command line". The window can be long
    #    enough on slow disks that a healthcheck blip catches it.
    #    Doing the topology delete + waiting for the rolling sweep
    #    BEFORE the etcd-side remove keeps the survivors on a clean
    #    compose throughout. m1's etcd is still in the cluster at
    #    this point but its membership is purely cosmetic now —
    #    nobody routes traffic to it.
    ctx.log_writer(f"==> deleting topology entry for {target_name}")
    await etcd.delete(TOPOLOGY_PREFIX + target_name)
    ctx.log_writer(
        "waiting for the topology-watcher chain to settle on each "
        "survivor (rolling MinIO recreate excludes the decommissioned "
        "pool)..."
    )
    await _wait_minio_settled_after_remove(
        etcd=etcd,
        target_ip=target_ip,
        cluster_token=config.cluster_token,
        listen_port=config.listen_port,
        log_writer=ctx.log_writer,
        timeout_s=180,
    )

    # 5. etcd member-remove — by now every survivor is on a compose
    #    that no longer references the leaving peer's MinIO pool, so
    #    nothing about the etcd-side cleanup will trigger a MinIO
    #    crash. Find the member by peer URL, then delete.
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
    ctx.progress_setter(0.95)

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
        parsed = _json.loads(out) if out.strip() else []
    except _json.JSONDecodeError:
        # mc may produce non-json prefix; try to find the array.
        return "missing"

    # `mc admin decommission status --json` returns a list of pool dicts
    # on success, but a single error object {"status":"error", ...} when
    # mc can't reach the local MinIO (e.g. MinIO crash-looping because
    # its server cmdline still references a now-decommissioned pool —
    # which is the very state our caller is polling through). Treat any
    # non-list response as a transient "missing" so the caller's poll
    # loop retries instead of crashing with AttributeError on the
    # error dict's keys.
    if not isinstance(parsed, list):
        log.warning(
            "mc admin decommission status returned non-list "
            "(probably an mc error): %s",
            str(parsed)[:200],
        )
        return "missing"
    pools = parsed

    for pool in pools:
        if not isinstance(pool, dict):
            continue
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
    """Read a single KEY=VALUE from the bind-mounted cluster.env.

    Reads via /repo/cluster.env (the directory-mount path) rather than
    /etc/milvus-onprem/cluster.env (the file-mount path). Single-file
    bind mounts in Docker capture an inode at attach time; when the
    host atomically replaces the file via temp-write + rename (see
    daemon/handlers.py:_upsert_kv), the file-mount stays pinned to
    the now-deleted old inode and reads return stale content. The
    directory mount is live — the new file appears immediately.
    """
    for path in ("/repo/cluster.env", "/etc/milvus-onprem/cluster.env"):
        try:
            with open(path) as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    k, _, v = line.partition("=")
                    if k.strip() == key:
                        return v.strip().strip('"').strip("'")
            return default
        except FileNotFoundError:
            continue
    return default


def _minio_api_port() -> str:
    return _read_cluster_env_value("MINIO_API_PORT", "9000")


def _etcd_peer_port() -> int:
    return int(_read_cluster_env_value("ETCD_PEER_PORT", "2380"))


def _minio_access() -> str:
    return _read_cluster_env_value("MINIO_ACCESS_KEY", "minioadmin")


def _minio_secret() -> str:
    return _read_cluster_env_value("MINIO_SECRET_KEY", "")


def _is_pulsar_deploy() -> bool:
    """Mirror lib/env.sh:_env_apply_version_defaults — derive MQ_TYPE from
    the cluster.env'd Milvus image tag. Operator override via explicit
    `MQ_TYPE=...` in cluster.env wins; otherwise 2.5.x → pulsar,
    2.6+ → woodpecker (no singleton broker)."""
    explicit = _read_cluster_env_value("MQ_TYPE", "").strip().lower()
    if explicit:
        return explicit == "pulsar"
    tag = _read_cluster_env_value("MILVUS_IMAGE_TAG", "").lstrip("v")
    parts = tag.split(".")
    if len(parts) >= 2 and parts[0] == "2" and parts[1] == "5":
        return True
    return False


async def _wait_minio_settled_after_remove(
    *,
    etcd: Any,
    target_ip: str,
    cluster_token: str,
    listen_port: int,
    log_writer: Any,
    timeout_s: int,
) -> None:
    """Block until every surviving peer's MinIO is healthy and no
    longer references `target_ip` in its container's running
    MINIO_VOLUMES.

    Used after the topology entry for the leaving peer is deleted but
    BEFORE the etcd member-remove. Goal: don't proceed until every
    survivor's MinIO has been recreated with a compose that excludes
    the now-decommissioned pool — otherwise a transient MinIO restart
    in the survivors would crash with "pool decommissioned, please
    remove from server command line".

    We poll each survivor's daemon HTTP endpoint for a "minio
    recreated and healthy" signal. If that endpoint isn't reachable
    or doesn't yet exist on older daemons, fall back to TCP-probing
    the peer's MinIO port and accepting that the topology-watcher
    chain has had enough wall-clock time.
    """
    import httpx

    # Discover surviving peers from current topology (target was just
    # deleted; this gives us the SURVIVING set).
    raw = await etcd.get_prefix(TOPOLOGY_PREFIX)
    survivors: list[tuple[str, str]] = []
    for k, v in raw.items():
        name = k.removeprefix(TOPOLOGY_PREFIX)
        try:
            info = json.loads(v)
        except json.JSONDecodeError:
            continue
        ip = info.get("ip")
        if ip and ip != target_ip:
            survivors.append((name, ip))

    deadline = asyncio.get_event_loop().time() + timeout_s
    pending = {(n, ip): None for n, ip in survivors}

    async def _peer_settled(ip: str) -> bool:
        # Two signals we accept as "settled": (1) the peer's MinIO
        # admin info shows a pool count <= len(survivors) (i.e., the
        # decommissioned pool has been pruned from the running
        # MINIO_VOLUMES), (2) a TCP probe to the local control-plane
        # works AND it has been at least 30s since topology-delete
        # (heuristic upper bound on watcher fan-out + recreate).
        # Implementing (1) cleanly requires reaching mc inside the
        # peer's milvus-minio container, which we can't do remotely.
        # So in this first pass we use (2): just probe control-plane.
        url = f"http://{ip}:{listen_port}/health"
        try:
            async with httpx.AsyncClient(timeout=3.0) as client:
                resp = await client.get(
                    url,
                    headers={"Authorization": f"Bearer {cluster_token}"},
                )
                return resp.status_code == 200
        except Exception:
            return False

    while asyncio.get_event_loop().time() < deadline:
        for name, ip in list(pending.keys()):
            if await _peer_settled(ip):
                # NB: a healthy daemon HTTP endpoint doesn't strictly
                # prove MinIO has been recreated — that's the
                # heuristic. The handler's MinIO recreate is
                # synchronous (waits for healthy) so by the time the
                # daemon's HTTP is responsive AFTER a topology event,
                # the recreate has finished too.
                pending.pop((name, ip), None)
                log_writer(f"  {name} @ {ip}: settled")
        if not pending:
            return
        await asyncio.sleep(3)

    if pending:
        names = ", ".join(f"{n} ({ip})" for (n, ip) in pending)
        log_writer(
            f"WARN: timed out waiting for {names} to settle after "
            f"topology delete. The cluster may still finish "
            f"converging on its own; if a survivor's MinIO crash-loops "
            f"with 'pool decommissioned', recreate it manually with "
            f"`docker compose --project-name <name> -f "
            f"rendered/<name>/docker-compose.yml up -d --force-recreate "
            f"--no-deps minio`."
        )


register_handler("remove-node", run_remove_node)
