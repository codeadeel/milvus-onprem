"""Topology-change handlers — the side-effect layer.

When a peer is added (or removed, or updated) in `/cluster/topology/
peers/`, every daemon's TopologyWatcher fires its registered handlers.
This module owns those handlers — they run on every node, so each peer
keeps its local rendered/ + cluster.env + nginx config in lockstep
with etcd without operator intervention.

What runs where:
  - re_render_locally:  every daemon. Edits cluster.env's PEER_IPS,
                        calls `./milvus-onprem render`. Idempotent.
  - reload_nginx:       every daemon. `docker exec milvus-nginx
                        nginx -s reload`. Cheap, non-disruptive.
  - add_minio_pool:     LEADER only — exactly one node should run the
                        cluster-wide pool-add or we'd get duplicate
                        attach attempts. Talks to MinIO via mc inside
                        the milvus-minio sibling container.

These handlers shell out to host-side tools (docker, bash, mc). The
daemon container has them via the apt installs in Dockerfile + the
docker.sock bind mount.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shlex
from typing import Any

from .config import DaemonConfig
from .etcd_client import EtcdClient
from .leader import LeaderElector

log = logging.getLogger("daemon.handlers")

REPO_PATH = "/repo"  # bind-mounted from the host's milvus-onprem dir
CLUSTER_ENV_PATH = "/repo/cluster.env"  # directory-mount; see _shell_helpers


class TopologyHandlers:
    """Bundle of handlers + the deps they need.

    Construct once at lifespan startup and register with
    `TopologyWatcher.on_change()`. The watcher will call the bundle's
    `__call__` for each event; we fan out to the individual handlers
    in a deterministic order (cluster.env edit → render → nginx →
    minio).
    """

    def __init__(
        self,
        config: DaemonConfig,
        leader: LeaderElector,
        etcd: EtcdClient,
        topology,  # TopologyWatcher; typed as Any to dodge a circular import
    ):
        """Store deps. `leader` is read at call-time so leadership-only
        handlers always see the latest state. `topology` gives us the
        in-memory mirror of /cluster/topology/peers/ — we read from
        that rather than re-querying etcd, because a topology change
        on a 1->2 grow happens in lockstep with member-add (which
        transiently kills etcd quorum)."""
        self._cfg = config
        self._leader = leader
        self._etcd = etcd
        self._topology = topology
        # Serialise handler runs — re-renders aren't safe to overlap
        # (two writes racing on rendered/<node>/docker-compose.yml).
        self._lock = asyncio.Lock()

    async def __call__(
        self,
        kind: str,
        old: dict[str, Any] | None,
        new: dict[str, Any] | None,
    ) -> None:
        """Top-level fan-out from the watcher."""
        async with self._lock:
            await self._dispatch(kind, old, new)

    async def _dispatch(
        self,
        kind: str,
        old: dict[str, Any] | None,
        new: dict[str, Any] | None,
    ) -> None:
        """Route the event to the right ordered chain of side-effects."""
        log.info("topology change handler: kind=%s", kind)

        # First: edit the local cluster.env's PEER_IPS to match etcd, and
        # re-render. Both reads and writes go through `./milvus-onprem`
        # so we reuse all the existing bash logic instead of re-implementing.
        # If render fails, the rendered/ tree is stale; downstream actions
        # (nginx reload + rolling MinIO recreate) would propagate the old
        # config across the cluster and leave it in a broken state. Abort
        # this dispatch and rely on the next topology change to retry —
        # the next /join's etcd PUT, or the operator running render again,
        # will trigger a fresh handler that re-attempts.
        if not await self._sync_cluster_env_and_render():
            log.warning(
                "render failed; skipping nginx reload + minio recreate "
                "to avoid propagating stale config. Will retry on next "
                "topology event."
            )
            return

        # Second: nginx reload. Cheap, non-disruptive (signal-based).
        await self._reload_nginx()

        # Third: recreate every peer's MinIO sequentially so the
        # cluster keeps quorum throughout. Only the leader drives the
        # sweep — followers' handlers stop here; the leader's HTTP
        # call to /recreate-minio-self is what triggers their recreate
        # in turn. Leader does itself first, then iterates other peers
        # in sorted node-N order (skipping the just-added peer if any
        # — its MinIO will start with the new layout via bootstrap).
        # This replaces the v1 "every peer in parallel" approach which
        # caused a brief cluster-wide MinIO blip on grow / shrink.
        if kind in ("ADDED", "REMOVED") and self._leader.is_leader:
            await self._rolling_minio_recreate(kind=kind, new=new)

    # ── primitive operations ─────────────────────────────────────────

    async def _sync_cluster_env_and_render(
        self,
        override: list[tuple[str, str]] | None = None,
    ) -> bool:
        """Rebuild cluster.env's PEER_IPS / PEER_NAMES from topology, render.

        PEER_IPS and PEER_NAMES are kept in lockstep, sorted by node-N
        suffix. PEER_NAMES is the stable etcd-side identity for each
        peer; without it, role_detect would synthesise names by position
        and break post-remove-node when a low-N peer is removed — the
        survivors' etcd identities don't get re-numbered, but a
        position-based scheme would silently relabel them, leading to
        rendered/<wrong-name>/ on the survivors.

        `override`, when provided, is the [(name, ip), ...] list to
        use for cluster.env / render — bypassing the watcher's mirror.
        Used by the recreate-minio-self path so a fresh-from-etcd read
        can drive the render without polluting the watcher's mirror
        (which would change subsequent watcher events from ADDED to
        UPDATED and silently bypass the rolling-recreate trigger).

        Returns True on success (or trivially on empty topology), False
        if render failed. Caller uses the return value to decide whether
        downstream actions (nginx reload, MinIO recreate) are safe to
        run — they would otherwise propagate stale config.
        """
        cluster_env_host = os.path.join(REPO_PATH, "cluster.env")
        ordered = override if override is not None else self._current_peer_ips_and_names()
        if not ordered:
            log.info("render: topology empty, skipping")
            return True

        new_peer_ips = ",".join(ip for _name, ip in ordered)
        new_peer_names = ",".join(name for name, _ip in ordered)
        await asyncio.to_thread(
            _upsert_kv, cluster_env_host, "PEER_IPS", new_peer_ips
        )
        await asyncio.to_thread(
            _upsert_kv, cluster_env_host, "PEER_NAMES", new_peer_names
        )
        log.info(
            "cluster.env PEER_IPS=%s PEER_NAMES=%s",
            new_peer_ips, new_peer_names,
        )

        rc, out, err = await _run(
            f"cd {shlex.quote(REPO_PATH)} && ./milvus-onprem render"
        )
        if rc != 0:
            log.warning("render failed (rc=%d): %s", rc, err.strip()[:500])
            return False
        log.info("render OK")
        return True

    async def _reload_nginx(self) -> None:
        """Send a signal to milvus-nginx to reload its config.

        `nginx -s reload` is non-disruptive: existing connections drain
        gracefully, new connections use the new upstream block. Skip
        cleanly if there's no nginx container yet (e.g. during initial
        bootstrap before Stage 5).
        """
        rc, out, err = await _run(
            "docker exec milvus-nginx nginx -s reload"
        )
        if rc != 0:
            log.warning("nginx reload failed (rc=%d): %s",
                        rc, err.strip()[:200])
        else:
            log.info("nginx reloaded")

    async def recreate_minio_local(self) -> None:
        """Recreate THIS node's milvus-minio container and wait for
        it to report healthy.

        Why recreate vs restart: `docker restart` keeps the container's
        original create-time command, which means the new MINIO_VOLUMES
        (computed by render after PEER_IPS changed) would never reach
        MinIO. `docker compose up -d --force-recreate` rebuilds the
        container with the new spec.

        Public (no underscore prefix) because the per-peer
        `/recreate-minio-self` route on api.py calls this directly when
        the leader-driven rolling sweep RPCs in.

        We re-render from a FRESH etcd snapshot before the recreate:
        the leader's rolling sweep can RPC us before our own watcher
        has applied the latest topology change (raft replication and
        the watcher's HTTP stream are independent of the leader's RPC
        path). The fresh fetch is passed straight to the render via a
        local override — we deliberately do NOT overwrite the
        watcher's `self._topology.peers` mirror, because that would
        make the watcher reclassify a subsequent ADDED event as
        UPDATED (the dispatch chain only fires rolling-recreate on
        ADDED/REMOVED, so a misclassified UPDATED would silently skip
        the sweep that should have run).
        """
        from .topology import TOPOLOGY_PREFIX
        import json as _json
        raw = await self._etcd.get_prefix(TOPOLOGY_PREFIX)
        fresh: list[tuple[str, str]] = []
        from .joining import _node_sort_key
        decoded: dict[str, dict[str, Any]] = {}
        for k, v in raw.items():
            name = k.removeprefix(TOPOLOGY_PREFIX)
            try:
                decoded[name] = _json.loads(v)
            except _json.JSONDecodeError:
                log.warning("ignoring malformed topology entry %s", name)
        for name in sorted(decoded, key=_node_sort_key):
            ip = decoded[name].get("ip", "")
            if ip:
                fresh.append((name, ip))
        await self._sync_cluster_env_and_render(override=fresh)
        node_dir = f"{REPO_PATH}/rendered/{self._cfg.node_name}"
        cmd = (
            f"docker compose --project-name {shlex.quote(self._cfg.node_name)} "
            f"-f {shlex.quote(node_dir)}/docker-compose.yml "
            f"up -d --force-recreate --no-deps minio"
        )
        rc, out, err = await _run(cmd)
        if rc != 0:
            log.warning("minio recreate failed (rc=%d): %s",
                        rc, err.strip()[:400])
            return
        log.info("minio recreated; waiting for healthy")
        await _wait_minio_healthy(timeout_s=self._cfg.rolling_minio_healthy_wait_s)

        # After topology change, Milvus services on every peer have a
        # newly-rendered milvus.yaml that may list different etcd
        # endpoints (peer added/removed) and a different
        # PULSAR_HOST_IP. milvus reads its yaml only at container
        # startup, so a running Milvus keeps grpc-retrying a now-dead
        # endpoint forever (post remove-node) or doesn't notice an
        # added peer (post join). Bounce the affected Milvus services
        # so they pick up the new yaml. Filter against
        # `docker compose config --services` so we only touch services
        # actually present in this peer's compose. The daemon
        # container is deliberately NOT in the list — recreating the
        # daemon while this method runs would SIGKILL ourselves
        # mid-call (same problem rotate-token's sidecar fix avoids).
        compose_arg = (
            f"--project-name {shlex.quote(self._cfg.node_name)} "
            f"-f {shlex.quote(node_dir)}/docker-compose.yml"
        )
        rc, out, err = await _run(
            f"docker compose {compose_arg} config --services"
        )
        if rc != 0:
            log.warning(
                "docker compose config --services failed post-minio "
                "(rc=%d): %s — skipping Milvus refresh",
                rc, err.strip()[:300],
            )
            return
        present = set(out.split())
        wanted = {
            "mixcoord", "datanode", "querynode",
            "indexnode", "streamingnode", "proxy",
        }
        to_recreate = sorted(present & wanted)
        if not to_recreate:
            return
        cmd = (
            f"docker compose {compose_arg} up -d --force-recreate "
            f"--no-deps {' '.join(to_recreate)}"
        )
        rc, out, err = await _run(cmd)
        if rc != 0:
            log.warning(
                "milvus services recreate after topology change "
                "failed (rc=%d): %s",
                rc, err.strip()[:400],
            )
            return
        log.info("milvus services recreated post topology change: %s",
                 ", ".join(to_recreate))

    async def apply_pulsar_host_change(self, new_pulsar_host: str) -> None:
        """Update PULSAR_HOST in this peer's cluster.env, re-render, and
        recreate the milvus + pulsar services so they pick up the new
        broker address.

        Called by the leader's `migrate-pulsar` worker via the
        `/admin/sync-pulsar-host` endpoint, peer-by-peer:
          - new host first: brings Pulsar up locally
          - other peers next: their Milvus reconnects to the new
            broker (in-flight Pulsar messages on the old host are
            lost — caller documents the maintenance-window
            requirement)
          - old host last: removes its now-orphan Pulsar container
            (the render no longer emits a Pulsar service block when
            this peer isn't the host)

        Idempotent: if PULSAR_HOST already equals new_pulsar_host the
        cluster.env edit is a no-op, but we still re-render + recreate
        so a partially-applied previous run can finish converging.
        """
        cluster_env_host = os.path.join(REPO_PATH, "cluster.env")
        await asyncio.to_thread(
            _upsert_kv, cluster_env_host, "PULSAR_HOST", new_pulsar_host
        )
        log.info("cluster.env PULSAR_HOST=%s", new_pulsar_host)

        rc, out, err = await _run(
            f"cd {shlex.quote(REPO_PATH)} && ./milvus-onprem render"
        )
        if rc != 0:
            raise RuntimeError(
                f"render failed (rc={rc}): {err.strip()[:300]}"
            )
        log.info("render OK after PULSAR_HOST change")

        # Explicitly enumerate which services to recreate. Running an
        # unfiltered `docker compose up -d` would try to recreate the
        # `control-plane` (milvus-onprem-cp) container too — i.e. the
        # daemon running this very code — and SIGKILL it mid-RPC, with
        # the operator's CLI then stuck polling the dead daemon. The
        # rotate-token worker hit the same problem and uses a sidecar
        # to recreate itself; for PULSAR_HOST the daemon doesn't need
        # to recreate at all (its compose entry doesn't depend on
        # PULSAR_HOST), so we just leave it out of the service list.
        #
        # Services that DO need a recreate: the Pulsar singleton itself
        # (appears on the new host, disappears from the old) and every
        # Milvus component (they pick up the new pulsar.address from
        # the regenerated milvus.yaml at startup). etcd / minio /
        # nginx / control-plane are unaffected. Filter against
        # `docker compose config --services` so we don't try to
        # `up` a service that isn't in this peer's rendered compose
        # (e.g. `pulsar` is only on the PULSAR_HOST peer).
        node_dir = f"{REPO_PATH}/rendered/{self._cfg.node_name}"
        compose_arg = (
            f"--project-name {shlex.quote(self._cfg.node_name)} "
            f"-f {shlex.quote(node_dir)}/docker-compose.yml"
        )
        rc, out, err = await _run(
            f"docker compose {compose_arg} config --services"
        )
        if rc != 0:
            raise RuntimeError(
                f"docker compose config --services failed (rc={rc}): "
                f"{err.strip()[:300]}"
            )
        present = set(out.split())
        wanted = {
            "pulsar",
            "mixcoord", "datanode", "querynode",
            "indexnode", "streamingnode", "proxy",
        }
        to_recreate = sorted(present & wanted)
        if not to_recreate:
            log.info(
                "no pulsar-affected services in this peer's compose; "
                "nothing to recreate"
            )
            return

        cmd = (
            f"docker compose {compose_arg} up -d --force-recreate "
            f"--no-deps {' '.join(to_recreate)}"
        )
        rc, out, err = await _run(cmd)
        if rc != 0:
            raise RuntimeError(
                f"docker compose up after PULSAR_HOST change failed "
                f"(rc={rc}): {err.strip()[:400]}"
            )
        log.info(
            "services recreated for PULSAR_HOST=%s: %s",
            new_pulsar_host, ", ".join(to_recreate),
        )

    async def _rolling_minio_recreate(
        self,
        kind: str,
        new: dict[str, Any] | None,
    ) -> None:
        """Leader-driven rolling recreate of every peer's MinIO.

        Sequenced: leader does itself first (we already have the freshest
        rendered/), then iterates every other peer in sorted node-N
        order, HTTP-POSTing each peer's /recreate-minio-self with the
        cluster token. Each call is synchronous — the followers'
        endpoint doesn't return until its local MinIO is back to
        healthy — so the leader naturally waits between peers.

        Why we no longer skip the "just-added" peer: in sequential
        joins, the new joiner's bootstrap renders its compose with the
        post-join PEER_IPS so its MinIO starts with the right command
        and a recreate is redundant. In PARALLEL joins (operator runs
        join on N peers simultaneously), peers added during another
        peer's sweep are stranded: the trigger-event's `new.ip` only
        matches one of them, so subsequent in-flight joiners get
        RPC'd before their daemons are up (RPC fails harmlessly), and
        the just-added peer that triggered THIS sweep gets skipped
        even though by the time the sweep finishes, more peers exist
        than its bootstrap saw. Always recreating everyone is
        idempotent: the just-joined peer's RPC may fail with a
        warning while its daemon is mid-bootstrap, but the next
        topology event drives a fresh sweep that reaches it. Net
        cost is a few extra recreates during scale-out; net benefit
        is correctness under parallel joins.

        Failure of any peer logs a warning and continues — partial
        progress is better than aborting and leaving half the cluster
        on the old MINIO_VOLUMES. The next topology event drives a
        fresh sweep that retries the failed peer.
        """
        # Lazy import — keeps module-load free of httpx if a deployment
        # never reaches this code path (standalone mode etc.).
        import httpx

        # Self first — must be done before we ask peers to do theirs,
        # so the new MINIO_VOLUMES propagates from a known-up MinIO.
        log.info("rolling MinIO recreate: starting on self (%s)",
                 self._cfg.node_name)
        await self.recreate_minio_local()

        # Followers in sorted node-N order so behavior is deterministic.
        from .joining import _node_sort_key

        for name in sorted(self._topology.peers, key=_node_sort_key):
            info = self._topology.peers.get(name) or {}
            ip = info.get("ip")
            if not ip or ip == self._cfg.local_ip:
                continue

            url = f"http://{ip}:{self._cfg.listen_port}/recreate-minio-self"
            log.info("rolling MinIO recreate: -> %s @ %s", name, ip)
            try:
                async with httpx.AsyncClient(
                    timeout=self._cfg.rolling_minio_peer_rpc_timeout_s
                ) as client:
                    resp = await client.post(
                        url,
                        headers={
                            "Authorization": f"Bearer {self._cfg.cluster_token}",
                        },
                    )
                if resp.status_code != 200:
                    log.warning(
                        "rolling MinIO recreate: %s returned HTTP %d: %s",
                        name, resp.status_code, resp.text[:200],
                    )
                else:
                    log.info("rolling MinIO recreate: %s done", name)
            except Exception as e:
                log.warning("rolling MinIO recreate: %s errored: %s", name, e)

        log.info("rolling MinIO recreate: complete")

    def _current_peer_ips(self) -> list[str]:
        """Return peer IPs from the in-memory topology mirror.

        Read from `self._topology.peers` rather than etcd directly: when
        /join lands a 1->2 grow, etcd transiently lacks quorum during
        the join's member-add step, and a fresh etcd read here would
        time out. The mirror was populated by the watcher with the
        current change BEFORE this handler fires, so it's the freshest
        view we can get without going back to etcd.
        """
        # Local import keeps handlers.py decoupled from joining at
        # module load.
        from .joining import _node_sort_key

        peers = self._topology.peers
        return [
            peers[name].get("ip", "")
            for name in sorted(peers, key=_node_sort_key)
            if peers[name].get("ip")
        ]

    def _current_peer_ips_and_names(self) -> list[tuple[str, str]]:
        """Return [(name, ip), ...] from the topology mirror, sorted by
        node-N suffix. Both arrays kept in lockstep when written to
        cluster.env so role_detect can map this peer's NODE_NAME to its
        position without losing identity across remove-node operations.
        """
        from .joining import _node_sort_key

        peers = self._topology.peers
        return [
            (name, peers[name].get("ip", ""))
            for name in sorted(peers, key=_node_sort_key)
            if peers[name].get("ip")
        ]


# ── subprocess + cluster.env edit helpers (sync, run via to_thread) ──


async def _wait_minio_healthy(timeout_s: int = 90) -> bool:
    """Poll `docker inspect milvus-minio` until health=healthy or timeout.

    Used by both the local-node recreate path and the per-peer
    `/recreate-minio-self` route — the rolling sweep relies on this
    blocking until MinIO's distributed-mode quorum has re-formed
    before moving to the next peer.
    """
    deadline = asyncio.get_event_loop().time() + timeout_s
    while asyncio.get_event_loop().time() < deadline:
        rc, out, _ = await _run(
            "docker inspect milvus-minio --format '{{.State.Health.Status}}'"
        )
        if rc == 0 and out.strip() == "healthy":
            return True
        await asyncio.sleep(2)
    log.warning("minio did not return to healthy within %ds", timeout_s)
    return False


async def _run(cmd: str) -> tuple[int, str, str]:
    """Run a shell command, return (rc, stdout, stderr).

    Uses `bash -c` so we get pipes / && / cd inside the cmd string for
    free. We log all of it; nothing here should be user-supplied.
    """
    proc = await asyncio.create_subprocess_shell(
        cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        executable="/bin/bash",
    )
    stdout, stderr = await proc.communicate()
    rc = proc.returncode if proc.returncode is not None else -1
    return rc, stdout.decode(errors="replace"), stderr.decode(errors="replace")


def _upsert_kv(path: str, key: str, value: str) -> None:
    """Atomic-ish KEY=VALUE rewrite of a shell-style env file.

    Mirrors `lib/env.sh:env_upsert_kv`. Writes to a tmp file then
    renames so partial writes don't leave the file half-edited. We
    preserve the original file's UID/GID and mode — important
    because the daemon runs as root in its container, while
    cluster.env on the host is owned by the operator's Linux user.
    Without preserving ownership, the operator's CLI loses read
    access after the daemon edits it.
    """
    st = os.stat(path)
    with open(path, "r") as f:
        lines = f.readlines()

    found = False
    for i, line in enumerate(lines):
        if line.startswith(f"{key}="):
            lines[i] = f"{key}={value}\n"
            found = True
            break
    if not found:
        lines.append(f"{key}={value}\n")

    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        f.writelines(lines)
    os.chmod(tmp, st.st_mode & 0o777)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except PermissionError:
        # Non-root daemon (rare in our setup) — chown will fail; we
        # leave the file as-is and the operator can manually re-chown
        # if it ever drifts. Safer than a half-applied edit.
        log.warning("could not preserve ownership of %s; daemon may not be root", path)
    os.replace(tmp, path)
