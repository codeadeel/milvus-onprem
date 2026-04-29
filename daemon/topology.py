"""Topology source-of-truth in etcd, watched by every daemon.

Each peer is a key under TOPOLOGY_PREFIX with a small JSON value:

  {
    "name": "node-1",
    "ip":   "10.0.0.2",
    "joined_at": 1745912345.123,
    "role": "peer"
  }

Stage 2: just maintain an in-memory mirror and log changes. Stage 5
adds the side-effects (re-render, nginx reload, MinIO pool-add).
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Awaitable, Callable
from typing import Any

from .etcd_client import EtcdClient

log = logging.getLogger("daemon.topology")

TOPOLOGY_PREFIX = "/cluster/topology/peers/"

ChangeHandler = Callable[[str, dict[str, Any] | None, dict[str, Any] | None], Awaitable[None]]
"""Async callback: (event_type, old, new). event_type in {ADDED, UPDATED, REMOVED}."""


class TopologyWatcher:
    """Mirrors the etcd topology prefix into memory and fans out events.

    Stage 2 just maintains the mirror and logs. Stage 5 will register
    handlers (re-render, nginx reload, MinIO pool-add, …) via
    `on_change()`. Splitting the watch from the side-effects keeps the
    handlers testable in isolation.
    """

    def __init__(self, etcd: EtcdClient):
        """Store the etcd client; no I/O yet — that's `run()`."""
        self._etcd = etcd
        self.peers: dict[str, dict[str, Any]] = {}  # node_name -> info
        self._handlers: list[ChangeHandler] = []
        self._stop = asyncio.Event()

    @property
    def peer_count(self) -> int:
        """Number of peers currently in the topology."""
        return len(self.peers)

    @property
    def peer_ips(self) -> list[str]:
        """IPs of all peers, in arbitrary dict order."""
        return [p.get("ip", "") for p in self.peers.values() if p.get("ip")]

    async def authoritative_peers(self) -> dict[str, dict[str, Any]]:
        """Return the topology as a fresh, linearizable read from etcd.

        `self.peers` is the WATCHER's mirror, populated reactively from
        the etcd watch stream. It is eventually consistent with etcd,
        which is fine for handlers (they fire on a watch event the
        watcher already applied). It is NOT fine for workers driving
        cluster-wide operator actions — a recent topology PUT (e.g.,
        a peer that just finished /join) may not yet have triggered
        the local watcher event, and the worker would silently skip
        that peer.

        Workers handling migrate-pulsar / remove-node / rotate-token /
        any other "fan out an operation across every peer" job MUST
        use this method instead of `self.peers`. It does a single
        `get_prefix` against etcd — a quorum-protected read — so the
        returned snapshot is at least as fresh as any committed write.

        Returns the same shape as `self.peers`: {node_name: info_dict}.
        Malformed entries are dropped with a warning.
        """
        raw = await self._etcd.get_prefix(TOPOLOGY_PREFIX)
        out: dict[str, dict[str, Any]] = {}
        for key, val in raw.items():
            name = key.removeprefix(TOPOLOGY_PREFIX)
            try:
                out[name] = json.loads(val)
            except json.JSONDecodeError:
                log.warning(
                    "ignoring malformed topology entry %s in "
                    "authoritative_peers read",
                    name,
                )
        return out

    def on_change(self, handler: ChangeHandler) -> None:
        """Register an async callback fired on every topology change."""
        self._handlers.append(handler)

    async def stop(self) -> None:
        """Signal the run loop to exit at the next event boundary."""
        self._stop.set()

    async def run(self) -> None:
        """Seed the local mirror from etcd, then stream watch events
        forever. Caller is expected to schedule this as an asyncio task."""
        await self._seed()
        async for ev in self._etcd.watch_prefix(TOPOLOGY_PREFIX):
            if self._stop.is_set():
                break
            await self._apply_event(ev)

    # ── helpers ──────────────────────────────────────────────────────

    async def _seed(self) -> None:
        """Range-scan the topology prefix once and populate `self.peers`."""
        existing = await self._etcd.get_prefix(TOPOLOGY_PREFIX)
        for key, val in existing.items():
            name = key.removeprefix(TOPOLOGY_PREFIX)
            try:
                self.peers[name] = json.loads(val)
            except json.JSONDecodeError:
                log.warning("ignoring malformed topology entry %s", key)
        log.info("topology seeded with %d peers: %s",
                 len(self.peers), sorted(self.peers.keys()))

    async def _apply_event(self, ev: dict[str, Any]) -> None:
        """Update the mirror from a single etcd event and notify handlers."""
        key = ev["key"]
        if not key.startswith(TOPOLOGY_PREFIX):
            return
        name = key.removeprefix(TOPOLOGY_PREFIX)

        if ev["type"] == "DELETE":
            old = self.peers.pop(name, None)
            log.info("topology REMOVED: %s", name)
            await self._notify("REMOVED", old, None)
            return

        try:
            new = json.loads(ev["value"]) if ev["value"] is not None else {}
        except json.JSONDecodeError:
            log.warning("malformed topology PUT for %s", name)
            return

        old = self.peers.get(name)
        self.peers[name] = new
        kind = "ADDED" if old is None else "UPDATED"
        log.info("topology %s: %s -> %s", kind, name, new.get("ip"))
        await self._notify(kind, old, new)

    async def _notify(
        self,
        kind: str,
        old: dict[str, Any] | None,
        new: dict[str, Any] | None,
    ) -> None:
        """Run every registered handler; one handler's failure doesn't
        block the others, but it is logged loudly."""
        for h in self._handlers:
            try:
                await h(kind, old, new)
            except Exception as e:
                log.exception("topology handler errored: %s", e)
