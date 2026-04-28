"""Leader election via etcd lease + atomic create.

Algorithm (standard etcd pattern):
  1. Grant a lease with TTL.
  2. Put `/cluster/leader` *if create_revision == 0* with our value
     and the lease. Atomic — exactly one node wins.
  3. Winner: keep-alive every keepalive_interval_s. Lose connection?
     Lease expires; another node takes over after TTL elapses.
  4. Loser: watch the leader key. On DELETE, race for the next term.

This module owns *only* the leadership state. Whoever observes
`is_leader` should not assume it can mutate without re-checking
under the lease — proper write paths still wrap their etcd writes
in transactions guarded by the lease.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time

from .config import DaemonConfig
from .etcd_client import EtcdClient

log = logging.getLogger("daemon.leader")

LEADER_KEY = "/cluster/leader"


class LeaderElector:
    """One per daemon. Runs forever in a background asyncio task.

    Public read-only attributes:
      is_leader        — current leadership state.
      lease_id         — the etcd lease backing leadership (None when
                          not leader).
      term_started_at  — unix-ts of when this peer last became leader.
    """

    def __init__(self, etcd: EtcdClient, config: DaemonConfig):
        """Store deps and initialise to follower state."""
        self._etcd = etcd
        self._cfg = config
        self.is_leader: bool = False
        self.lease_id: int | None = None
        self.term_started_at: float | None = None
        self._stop = asyncio.Event()

    async def stop(self) -> None:
        """Signal the run loop to exit and revoke our lease so the next
        leader can take over without waiting for TTL."""
        self._stop.set()
        if self.lease_id is not None:
            try:
                await self._etcd.lease_revoke(self.lease_id)
                log.info("revoked lease %d on shutdown", self.lease_id)
            except Exception as e:
                log.warning("lease_revoke failed on shutdown: %s", e)

    async def run(self) -> None:
        """Run the elect-or-follow loop until stop() is called.

        Bare `Exception` is wrapped in exponential backoff so a flaky
        etcd doesn't burn CPU; cancellation propagates so the lifespan
        manager can shut us down promptly.
        """
        log.info("leader elector starting for %s", self._cfg.node_name)
        backoff = 1.0
        while not self._stop.is_set():
            try:
                await self._cycle()
                backoff = 1.0
            except asyncio.CancelledError:
                raise
            except Exception as e:
                log.warning("leader cycle errored (%s); retry in %.1fs", e, backoff)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 30.0)
        log.info("leader elector stopped")

    async def _cycle(self) -> None:
        """One round: grant a lease, race for the leader key, hold or watch."""
        self.lease_id = await self._etcd.lease_grant(self._cfg.lease_ttl_s)
        my_value = json.dumps(
            {
                "node_name": self._cfg.node_name,
                "ip": self._cfg.local_ip,
                "since": time.time(),
                "lease_id": self.lease_id,
                "ttl_s": self._cfg.lease_ttl_s,
            }
        )

        won = await self._etcd.put_if_absent(LEADER_KEY, my_value, self.lease_id)
        if won:
            self.is_leader = True
            self.term_started_at = time.time()
            log.info("acquired leadership (lease=%d)", self.lease_id)
            try:
                await self._hold_leadership()
            finally:
                self.is_leader = False
                self.term_started_at = None
                log.info("released leadership")
        else:
            self.is_leader = False
            current = await self._etcd.get(LEADER_KEY)
            if current:
                try:
                    info = json.loads(current)
                    log.info(
                        "follower mode; current leader is %s (%s)",
                        info.get("node_name"),
                        info.get("ip"),
                    )
                except json.JSONDecodeError:
                    log.info("follower mode; leader info unparsable")
            await self._await_leader_change()

    async def _hold_leadership(self) -> None:
        """Keep our lease alive at the configured interval until we
        either lose it or are told to stop."""
        interval = self._cfg.keepalive_interval_s
        while not self._stop.is_set():
            await asyncio.sleep(interval)
            try:
                ttl = await self._etcd.lease_keepalive(self.lease_id)  # type: ignore[arg-type]
                if ttl <= 0:
                    log.warning("lease expired while holding leadership")
                    return
            except Exception as e:
                log.warning("keepalive failed: %s — releasing leadership", e)
                return

    async def _await_leader_change(self) -> None:
        """Watch the leader key and return when it's deleted, signalling
        a new election round can start."""
        async for ev in self._etcd.watch_prefix(LEADER_KEY):
            if ev["key"] != LEADER_KEY:
                continue
            if ev["type"] == "DELETE":
                log.info("leader key deleted; racing for next term")
                return
