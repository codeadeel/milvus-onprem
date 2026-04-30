"""FastAPI app + lifespan glue + uvicorn entrypoint.

Wires together: config -> etcd client -> leader elector + topology
watcher -> HTTP routes. The lifespan context manager owns the
background tasks; on shutdown it cancels them and revokes the lease
so leadership transitions promptly without waiting for TTL.

Run as `python -m daemon.main` inside the container.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI

from .api import router
from .config import DaemonConfig
from .etcd_client import EtcdClient
from .handlers import TopologyHandlers
from .jobs import JobsManager
from .leader import LeaderElector
from .topology import TOPOLOGY_PREFIX, TopologyWatcher
from .watchdog import LocalComponentWatchdog, PeerReachabilityWatchdog
from . import workers  # noqa: F401  — import side-effect registers job handlers


def _setup_logging(level_name: str) -> None:
    """Configure root logging to stdout in a parseable single-line format."""
    level = getattr(logging, level_name.upper(), logging.INFO)
    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        level=level,
    )


log = logging.getLogger("daemon")


CLUSTER_VERSION_KEY = "/cluster/milvus_version"


async def _register_cluster_version(etcd: EtcdClient) -> None:
    """Write the cluster's canonical MILVUS_IMAGE_TAG to etcd if absent.

    Read by `lib/render.sh` (via etcdctl) to refuse rendering when a
    peer's cluster.env disagrees with the cluster — resolves QA finding
    F-R4-C.1, where a manual edit of one peer's MILVUS_IMAGE_TAG could
    silently produce a multi-version cluster that fails at runtime in
    confusing ways.

    Source-of-truth: this peer's own cluster.env at daemon start.
    Idempotent — `put_if_absent` is a no-op when the key already
    exists. The version-upgrade worker explicitly overwrites this on
    successful rollout.
    """
    # Read MILVUS_IMAGE_TAG from cluster.env. We read through the
    # directory bind-mount at /repo/cluster.env (not the legacy
    # single-file mount at /etc/milvus-onprem/cluster.env) — atomic-
    # rename writes from handlers._upsert_kv would leave the file mount
    # pinned to a stale inode.
    try:
        with open("/repo/cluster.env") as f:
            for line in f:
                if line.startswith("MILVUS_IMAGE_TAG="):
                    tag = line.partition("=")[2].strip()
                    break
            else:
                log.warning("MILVUS_IMAGE_TAG missing from cluster.env; "
                            "skipping cluster-version anchor")
                return
    except FileNotFoundError:
        log.warning("cluster.env not mounted; skipping cluster-version anchor")
        return

    written = await etcd.put_if_absent(CLUSTER_VERSION_KEY, tag)
    if written:
        log.info("registered cluster MILVUS_IMAGE_TAG=%s in etcd at %s",
                 tag, CLUSTER_VERSION_KEY)


async def _register_self_if_absent(etcd: EtcdClient, config: DaemonConfig) -> None:
    """Write this peer's topology entry on first start (idempotent).

    Distributed-mode init brings the cluster up at N=1 without a leader-
    side `/join` having registered the bootstrap peer. The daemon does it
    here on startup so the topology key prefix is canonical from the
    moment the first daemon comes up. For peers that joined via /join
    later, the leader has already written their entry — `put_if_absent`
    is a no-op.
    """
    key = TOPOLOGY_PREFIX + config.node_name
    existing = await etcd.get(key)
    if existing is not None:
        log.info("topology entry for %s already present; not overwriting",
                 config.node_name)
        return
    info = json.dumps(
        {
            "name": config.node_name,
            "ip": config.local_ip,
            "joined_at": time.time(),
            "role": "peer",
        }
    )
    written = await etcd.put_if_absent(key, info)
    if written:
        log.info("registered self in topology: %s -> %s",
                 config.node_name, config.local_ip)
    else:
        log.info("topology entry for %s appeared concurrently; deferring",
                 config.node_name)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup / shutdown sequence for the daemon.

    Loads config, opens etcd client, kicks off leader election and the
    topology watcher as background tasks. On shutdown: signals the
    tasks to stop, cancels them, revokes the etcd lease, closes HTTP.
    """
    config = DaemonConfig()  # type: ignore[call-arg]  # pydantic loads from env
    _setup_logging(config.log_level)

    log.info("starting daemon: cluster=%s node=%s ip=%s",
             config.cluster_name, config.node_name, config.local_ip)
    log.info("etcd endpoints: %s", config.etcd_endpoint_list)

    etcd = EtcdClient(config.etcd_endpoint_list)
    elector = LeaderElector(etcd, config)
    topology = TopologyWatcher(etcd)

    # Side-effect bundle for topology changes — re-render, nginx
    # reload, MinIO recreate. Registered before the watcher starts so
    # we don't miss any events. Reads peers from the watcher's mirror
    # rather than etcd, so it works during a 1->2 grow's quorum dip.
    handlers = TopologyHandlers(
        config=config, leader=elector, etcd=etcd, topology=topology
    )
    topology.on_change(handlers)

    # Jobs manager — owns the long-running async-job lifecycle.
    # Registration of job types happens at import time via
    # `daemon.workers/__init__.py`, before this point.
    jobs_mgr = JobsManager(etcd=etcd, leader=elector, node_name=config.node_name)

    # Stage 12 watchdogs. Both run on every peer:
    #   - local: docker-restart unhealthy milvus-* containers (loop-guarded)
    #   - peer:  TCP-probe peers, emit PEER_DOWN_ALERT / PEER_UP_ALERT
    # These observe and act locally; no leader gating — every daemon owns
    # remediation for its own node.
    local_watchdog = LocalComponentWatchdog(config)
    peer_watchdog = PeerReachabilityWatchdog(
        config, topology, leader=elector, jobs_mgr=jobs_mgr,
    )

    # Job retention sweeper — only the leader prunes (etcd writes are
    # leader-funneled anyway), but every daemon checks via is_leader so
    # it just runs on the active leader and is a no-op everywhere else.
    stop_pruner = asyncio.Event()

    async def _retention_loop() -> None:
        """Periodically delete terminated jobs older than the retention
        window. Leader-only; followers tick but skip the work."""
        log.info(
            "jobs retention loop: interval=%ds retention=%ds (leader-only)",
            config.jobs_prune_interval_s, config.jobs_retention_s,
        )
        while not stop_pruner.is_set():
            try:
                await asyncio.wait_for(
                    stop_pruner.wait(), timeout=config.jobs_prune_interval_s
                )
                break  # event set → shutdown
            except asyncio.TimeoutError:
                pass
            if not elector.is_leader:
                continue
            try:
                await jobs_mgr.prune_old(config.jobs_retention_s)
            except Exception as e:
                log.warning("jobs prune tick errored: %s", e)

    async def _stuck_sweep_loop() -> None:
        """Periodically mark stuck-running jobs as failed.

        QA finding F5.2: when the daemon that owns a running job dies,
        the worker task dies with it; without this sweep, the job sits
        in `running` state forever. The sweep checks `last_heartbeat`
        on every running job and marks them `failed` after the
        configured timeout (default 60s = 30 flush cycles missed).
        Leader-only; followers tick but no-op.
        """
        log.info(
            "jobs stuck-running sweep: interval=%ds heartbeat_timeout=%ds (leader-only)",
            config.jobs_stuck_sweep_interval_s, config.jobs_heartbeat_timeout_s,
        )
        while not stop_pruner.is_set():
            try:
                await asyncio.wait_for(
                    stop_pruner.wait(),
                    timeout=config.jobs_stuck_sweep_interval_s,
                )
                break
            except asyncio.TimeoutError:
                pass
            if not elector.is_leader:
                continue
            try:
                await jobs_mgr.prune_stuck_running(
                    config.jobs_heartbeat_timeout_s
                )
            except Exception as e:
                log.warning("stuck-running sweep tick errored: %s", e)

    # Stash on app.state so route handlers can read them.
    app.state.config = config
    app.state.etcd = etcd
    app.state.leader = elector
    app.state.topology = topology
    app.state.handlers = handlers
    app.state.jobs = jobs_mgr
    app.state.local_watchdog = local_watchdog
    app.state.peer_watchdog = peer_watchdog

    # Idempotently register ourselves in the topology before kicking off
    # the watcher — that way the very first observation already includes
    # us. Failures here are non-fatal: the leader will eventually retry.
    try:
        await _register_self_if_absent(etcd, config)
    except Exception as e:
        log.warning("self-register deferred: %s (will retry on leader)", e)

    try:
        await _register_cluster_version(etcd)
    except Exception as e:
        log.warning("cluster-version anchor deferred: %s", e)

    elector_task = asyncio.create_task(elector.run(), name="leader-elector")
    topology_task = asyncio.create_task(topology.run(), name="topology-watcher")
    local_watchdog_task = asyncio.create_task(
        local_watchdog.run(), name="local-watchdog"
    )
    peer_watchdog_task = asyncio.create_task(
        peer_watchdog.run(), name="peer-watchdog"
    )
    retention_task = asyncio.create_task(
        _retention_loop(), name="jobs-retention"
    )
    stuck_sweep_task = asyncio.create_task(
        _stuck_sweep_loop(), name="jobs-stuck-sweep"
    )

    background_tasks = (
        elector_task,
        topology_task,
        local_watchdog_task,
        peer_watchdog_task,
        retention_task,
        stuck_sweep_task,
    )

    try:
        yield
    finally:
        log.info("shutdown initiated")
        await elector.stop()
        await topology.stop()
        await local_watchdog.stop()
        await peer_watchdog.stop()
        stop_pruner.set()
        for t in background_tasks:
            t.cancel()
        for t in background_tasks:
            try:
                await t
            except (asyncio.CancelledError, Exception):
                pass
        await etcd.close()
        log.info("shutdown complete")


app = FastAPI(
    title="milvus-onprem control plane",
    version="0.1.0",
    lifespan=lifespan,
)
app.include_router(router)


def main() -> None:
    """Launch uvicorn with the FastAPI app."""
    import uvicorn

    cfg = DaemonConfig()  # type: ignore[call-arg]
    uvicorn.run(
        "daemon.main:app",
        host="0.0.0.0",
        port=cfg.listen_port,
        log_level=cfg.log_level.lower(),
        access_log=False,  # too chatty for production; FastAPI logs handlers
    )


if __name__ == "__main__":
    main()
