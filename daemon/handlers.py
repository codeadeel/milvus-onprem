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
CLUSTER_ENV_PATH = "/etc/milvus-onprem/cluster.env"  # read-only mount


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
        await self._sync_cluster_env_and_render()

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

    async def _sync_cluster_env_and_render(self) -> None:
        """Rebuild cluster.env's PEER_IPS list from etcd, then render.

        Reads the current PEER_IPS from cluster.env (mounted read-only —
        we have to use a write workflow), updates if topology disagrees,
        and re-runs render. The render step is the existing bash code,
        invoked via subprocess; it picks up the new PEER_IPS and
        regenerates rendered/<this-node>/*.

        The `_LIVE_CLUSTER_ENV` host-side path is the same file that
        the daemon mounts read-only. We make the edit using the host's
        own filesystem permissions via `sudo` from a shell script
        executed via docker — no, simpler: we open the host file
        directly through /repo/cluster.env which IS mounted read-write
        as part of the /repo bind mount.
        """
        cluster_env_host = os.path.join(REPO_PATH, "cluster.env")
        topology_ips = self._current_peer_ips()
        if not topology_ips:
            log.info("render: topology empty, skipping")
            return

        new_peer_ips = ",".join(topology_ips)
        await asyncio.to_thread(
            _upsert_kv, cluster_env_host, "PEER_IPS", new_peer_ips
        )
        log.info("cluster.env PEER_IPS=%s", new_peer_ips)

        rc, out, err = await _run(
            f"cd {shlex.quote(REPO_PATH)} && ./milvus-onprem render"
        )
        if rc != 0:
            log.warning("render failed (rc=%d): %s", rc, err.strip()[:500])
            return
        log.info("render OK")

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
        """
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
        await _wait_minio_healthy(timeout_s=90)

    async def _rolling_minio_recreate(
        self,
        kind: str,
        new: dict[str, Any] | None,
    ) -> None:
        """Leader-driven rolling recreate of every peer's MinIO.

        Sequenced: leader does itself first (we already have the freshest
        rendered/), then iterates other peers in sorted node-N order,
        HTTP-POSTing each peer's /recreate-minio-self with the cluster
        token. Each call is synchronous — the followers' endpoint
        doesn't return until its local MinIO is back to healthy — so
        the leader naturally waits between peers.

        Skips:
          - The just-added peer (kind=ADDED, new.ip): its MinIO starts
            fresh with the right MINIO_VOLUMES via bootstrap, no need
            to recreate.
          - The leader itself (handled inline above the loop, not via
            self-RPC).

        Failure of any peer logs a warning and continues — partial
        progress is better than aborting and leaving half the cluster
        on the old MINIO_VOLUMES. The next topology event will retry
        any missed peer.
        """
        # Lazy import — keeps module-load free of httpx if a deployment
        # never reaches this code path (standalone mode etc.).
        import httpx

        skip_ip = (new or {}).get("ip") if kind == "ADDED" else None

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
            if ip == skip_ip:
                log.info("rolling MinIO recreate: skipping new peer %s "
                         "(its MinIO starts with the right layout)", name)
                continue

            url = f"http://{ip}:{self._cfg.listen_port}/recreate-minio-self"
            log.info("rolling MinIO recreate: -> %s @ %s", name, ip)
            try:
                async with httpx.AsyncClient(timeout=180.0) as client:
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
    cluster.env on the host is owned by `adeel`. Without preserving
    ownership, the operator's CLI loses read access after the daemon
    edits it.
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
