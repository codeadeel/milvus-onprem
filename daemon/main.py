"""FastAPI app + lifespan glue + uvicorn entrypoint.

Wires together: config -> etcd client -> leader elector + topology
watcher -> HTTP routes. The lifespan context manager owns the
background tasks; on shutdown it cancels them and revokes the lease
so leadership transitions promptly without waiting for TTL.

Run as `python -m daemon.main` inside the container.
"""

from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI

from .api import router
from .config import DaemonConfig
from .etcd_client import EtcdClient
from .leader import LeaderElector
from .topology import TopologyWatcher


def _setup_logging(level_name: str) -> None:
    """Configure root logging to stdout in a parseable single-line format."""
    level = getattr(logging, level_name.upper(), logging.INFO)
    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        level=level,
    )


log = logging.getLogger("daemon")


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

    # Stash on app.state so route handlers can read them.
    app.state.config = config
    app.state.etcd = etcd
    app.state.leader = elector
    app.state.topology = topology

    elector_task = asyncio.create_task(elector.run(), name="leader-elector")
    topology_task = asyncio.create_task(topology.run(), name="topology-watcher")

    try:
        yield
    finally:
        log.info("shutdown initiated")
        await elector.stop()
        await topology.stop()
        for t in (elector_task, topology_task):
            t.cancel()
        for t in (elector_task, topology_task):
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
