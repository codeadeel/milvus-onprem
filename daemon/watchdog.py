"""Watchdog — local-component health + peer reachability + alerts.

Two background tasks, both running on every daemon (operator can opt
out individually via WATCHDOG_MODE=monitor):

  LocalComponentWatchdog
    Polls `docker ps` on this node, finds milvus-* containers in the
    `(unhealthy)` state, and after N consecutive ticks docker-restarts
    them. Loop-guard: 3+ restarts within a 5 minute window stops the
    auto-restart and emits COMPONENT_RESTART_LOOP — let the operator
    inspect rather than amplify a misconfigured restart pile.

    Only acts on THIS host's containers. Cross-peer remediation needs
    out-of-band shell/SSH which we deliberately don't have.

  PeerReachabilityWatchdog
    TCP-probes every other peer's control-plane port (:19500). After
    N consecutive misses, emits a one-line structured PEER_DOWN_ALERT
    to stdout (which `journalctl -u …` / `docker logs` will surface).
    On recovery, emits PEER_UP_ALERT with the duration the peer was
    down. Doesn't take action — alerts only.

Alert format (matches the lib/watchdog.sh systemd-unit shape from v1):

  PEER_DOWN_ALERT  ts=<unix> node=<name> ip=<ip> consecutive_failures=N
  PEER_UP_ALERT    ts=<unix> node=<name> ip=<ip> was_down_for_s=N
  COMPONENT_RESTART     ts=<unix> container=<name> reason=unhealthy attempt=N
  COMPONENT_RESTART_LOOP ts=<unix> container=<name> restarts_in_5m=N

Single-line, greppable, parses straight to a dict. Operator can pipe
into `grep -E "PEER_(DOWN|UP)_ALERT"` from `docker logs milvus-onprem-cp`.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from collections import defaultdict, deque
from typing import Any

from .config import DaemonConfig

log = logging.getLogger("daemon.watchdog")

# Containers we watch on the local host. Names are matched as a prefix
# (e.g. "milvus-" catches all the 2.5 sub-services). milvus-onprem-cp
# is excluded — daemon doesn't watch itself; docker's `restart: always`
# already covers daemon crashes.
_WATCHED_PREFIXES = ("milvus-", "milvus")
_EXCLUDED_NAMES = frozenset({"milvus-onprem-cp"})


def _emit(line: str) -> None:
    """Print a single watchdog event line to stdout. Goes through the
    daemon's stdout → docker logs → operator's journalctl."""
    print(line, flush=True)


def _now() -> int:
    return int(time.time())


class LocalComponentWatchdog:
    """Watches `docker ps` for unhealthy local containers and restarts
    them after N consecutive unhealthy ticks. Loop-guarded."""

    def __init__(self, cfg: DaemonConfig):
        """Bind to the runtime config."""
        self._cfg = cfg
        self._consecutive_unhealthy: dict[str, int] = defaultdict(int)
        self._restart_history: dict[str, deque[float]] = defaultdict(deque)
        self._loop_alerted: set[str] = set()
        self._stop = asyncio.Event()

    async def stop(self) -> None:
        """Signal the run loop to exit."""
        self._stop.set()

    async def run(self) -> None:
        """Tick every watchdog_interval_s until stopped."""
        log.info(
            "local watchdog: mode=%s interval=%ds threshold=%d",
            self._cfg.watchdog_mode,
            self._cfg.watchdog_interval_s,
            self._cfg.watchdog_unhealthy_threshold,
        )
        while not self._stop.is_set():
            try:
                await self._tick()
            except Exception as e:
                log.exception("local watchdog tick errored: %s", e)
            try:
                await asyncio.wait_for(
                    self._stop.wait(), timeout=self._cfg.watchdog_interval_s
                )
            except asyncio.TimeoutError:
                continue

    async def _tick(self) -> None:
        """One pass over local containers; restart any that are
        unhealthy past the threshold."""
        containers = await _docker_ps()
        seen = set()
        for c in containers:
            name = c.get("Names", "")
            seen.add(name)
            if not _watched(name):
                continue
            state = c.get("State", "")
            health = _parse_health(c.get("Status", ""))

            # Containers in `Restarting` are docker's own loop — don't
            # add to it.
            if state == "restarting":
                self._consecutive_unhealthy[name] = 0
                continue

            if health == "unhealthy":
                self._consecutive_unhealthy[name] += 1
                if (
                    self._consecutive_unhealthy[name]
                    >= self._cfg.watchdog_unhealthy_threshold
                ):
                    await self._maybe_restart(name)
            else:
                # Healthy or no-healthcheck-defined — reset counter, AND
                # clear the loop-alerted flag so a subsequent re-trip
                # (e.g. operator fixed the bug, container went healthy,
                # then later degrades from a different cause) gets a
                # fresh round of auto-restart attempts.
                self._consecutive_unhealthy[name] = 0
                if health == "healthy" and name in self._loop_alerted:
                    log.info(
                        "watchdog: %s recovered to healthy; clearing "
                        "loop-alerted flag — auto-restart re-armed",
                        name,
                    )
                    self._loop_alerted.discard(name)
                    self._restart_history[name].clear()

        # Drop counters for containers that are gone (e.g. removed).
        for name in list(self._consecutive_unhealthy):
            if name not in seen:
                self._consecutive_unhealthy.pop(name, None)
        # Clear loop-alerted entries for removed containers so a new
        # container with the same name doesn't inherit a stale flag.
        for name in list(self._loop_alerted):
            if name not in seen:
                self._loop_alerted.discard(name)
                self._restart_history.pop(name, None)

    async def _maybe_restart(self, name: str) -> None:
        """Restart `name` if mode allows and the loop-guard hasn't
        tripped. Resets the unhealthy counter on success."""
        # Once a container has tripped the loop guard, do NOT restart
        # again — even if its 5-min sliding window of restart timestamps
        # has aged out. Documented design intent (per the docstring on
        # this class) is "leave alone for operator" once 3 restarts in
        # 5min have happened. Prior behavior was a sliding-window rate-
        # limit: after 5min of inactivity the oldest restart aged out,
        # `len(history)` dropped below `restart_loop_max`, and the
        # watchdog resumed restarts — which contradicts the documented
        # promise and creates indefinite background load on a sticky-
        # unhealthy container. The flag clears only when the container
        # reaches `health=healthy` (see _tick: healthy → reset counter
        # and discard the flag).
        if name in self._loop_alerted:
            log.warning(
                "watchdog: %s in restart loop — leaving alone for operator "
                "(`docker restart %s` to reset once underlying issue is fixed)",
                name, name,
            )
            return

        history = self._restart_history[name]
        cutoff = time.time() - self._cfg.watchdog_restart_loop_window_s
        while history and history[0] < cutoff:
            history.popleft()

        if len(history) >= self._cfg.watchdog_restart_loop_max:
            _emit(
                f"COMPONENT_RESTART_LOOP ts={_now()} container={name} "
                f"restarts_in_5m={len(history)}"
            )
            self._loop_alerted.add(name)
            log.warning(
                "watchdog: %s in restart loop (%d restarts in %ds) — "
                "halting auto-restart for this container",
                name,
                len(history),
                self._cfg.watchdog_restart_loop_window_s,
            )
            return

        if self._cfg.watchdog_mode != "auto":
            log.info(
                "watchdog: %s unhealthy for %d ticks (mode=monitor; not restarting)",
                name,
                self._consecutive_unhealthy[name],
            )
            return

        attempt = len(history) + 1
        _emit(
            f"COMPONENT_RESTART ts={_now()} container={name} "
            f"reason=unhealthy attempt={attempt}"
        )
        log.info("watchdog: docker restart %s (attempt=%d)", name, attempt)
        rc, out, err = await _run(f"docker restart {name}")
        if rc != 0:
            log.warning(
                "watchdog: docker restart %s failed (rc=%d): %s",
                name,
                rc,
                err.strip()[:200],
            )
            return

        history.append(time.time())
        self._consecutive_unhealthy[name] = 0


class PeerReachabilityWatchdog:
    """TCP-probes every peer's control-plane port and emits PEER_DOWN /
    PEER_UP alerts. No remediation — alerts only."""

    def __init__(self, cfg: DaemonConfig, topology):
        """Take the topology mirror so the peer list stays current as
        the cluster grows / shrinks. Excludes self from probing."""
        self._cfg = cfg
        self._topology = topology
        self._consecutive_misses: dict[str, int] = defaultdict(int)
        self._down_since: dict[str, float] = {}
        self._stop = asyncio.Event()

    async def stop(self) -> None:
        """Signal the run loop to exit."""
        self._stop.set()

    async def run(self) -> None:
        """Tick every watchdog_interval_s until stopped."""
        log.info(
            "peer watchdog: interval=%ds peer_failure_threshold=%d",
            self._cfg.watchdog_interval_s,
            self._cfg.watchdog_peer_failure_threshold,
        )
        while not self._stop.is_set():
            try:
                await self._tick()
            except Exception as e:
                log.exception("peer watchdog tick errored: %s", e)
            try:
                await asyncio.wait_for(
                    self._stop.wait(), timeout=self._cfg.watchdog_interval_s
                )
            except asyncio.TimeoutError:
                continue

    async def _tick(self) -> None:
        """One probe-pass across all peers in the topology mirror."""
        peers = list(self._topology.peers.items())
        for name, info in peers:
            ip = info.get("ip")
            if not ip or ip == self._cfg.local_ip:
                continue
            ok = await _tcp_probe(ip, self._cfg.listen_port)
            if ok:
                # Recovery edge.
                if self._consecutive_misses.get(name, 0) >= self._cfg.watchdog_peer_failure_threshold:
                    down_since = self._down_since.pop(name, time.time())
                    _emit(
                        f"PEER_UP_ALERT ts={_now()} node={name} ip={ip} "
                        f"was_down_for_s={int(time.time() - down_since)}"
                    )
                self._consecutive_misses[name] = 0
            else:
                self._consecutive_misses[name] += 1
                if (
                    self._consecutive_misses[name]
                    == self._cfg.watchdog_peer_failure_threshold
                ):
                    self._down_since[name] = time.time()
                    _emit(
                        f"PEER_DOWN_ALERT ts={_now()} node={name} ip={ip} "
                        f"consecutive_failures={self._consecutive_misses[name]}"
                    )


# ── helpers ──────────────────────────────────────────────────────────


def _watched(name: str) -> bool:
    """True if a container name should be tracked by the local watchdog."""
    if name in _EXCLUDED_NAMES:
        return False
    return any(name.startswith(p) for p in _WATCHED_PREFIXES)


def _parse_health(status: str) -> str:
    """Extract docker's healthcheck verdict from the Status string.

    docker ps prints `Up X minutes (healthy)` / `Up X minutes (unhealthy)`
    / `Up X minutes (health: starting)`. We pull the parenthesised
    state. No parens → no healthcheck on the container — return "none"
    so the watchdog never fires on it.
    """
    if "(healthy)" in status:
        return "healthy"
    if "(unhealthy)" in status:
        return "unhealthy"
    if "(health: starting)" in status:
        return "starting"
    return "none"


async def _docker_ps() -> list[dict[str, Any]]:
    """Return `docker ps` output as a list of dicts. Uses the
    --format=json line-per-container output (newer docker CLI)."""
    rc, out, err = await _run("docker ps --format '{{json .}}'")
    if rc != 0:
        log.warning("docker ps failed (rc=%d): %s", rc, err.strip()[:200])
        return []
    rows: list[dict[str, Any]] = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return rows


async def _tcp_probe(ip: str, port: int, timeout_s: float = 2.0) -> bool:
    """Best-effort TCP-connect probe; True if SYN/ACK round-trip
    completes within `timeout_s`."""
    try:
        fut = asyncio.open_connection(ip, port)
        reader, writer = await asyncio.wait_for(fut, timeout=timeout_s)
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        return True
    except (asyncio.TimeoutError, OSError):
        return False


async def _run(cmd: str) -> tuple[int, str, str]:
    """Run a shell command; return (rc, stdout, stderr)."""
    proc = await asyncio.create_subprocess_shell(
        cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        executable="/bin/bash",
    )
    stdout, stderr = await proc.communicate()
    rc = proc.returncode if proc.returncode is not None else -1
    return rc, stdout.decode(errors="replace"), stderr.decode(errors="replace")
