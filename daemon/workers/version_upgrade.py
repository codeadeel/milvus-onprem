"""Worker for the `version-upgrade` job — rolling Milvus version bump.

Operator triggers `./milvus-onprem upgrade --milvus-version=vX.Y.Z`.
The daemon job orchestrates:

  1. Validate target version format.
  2. Upgrade the LEADER's local Milvus (so if anything is going to
     break, it breaks first on the daemon doing the orchestration —
     fail fast).
  3. For each follower in deterministic order: HTTP-POST to that
     peer's daemon /upgrade-self endpoint. The follower runs the
     same local-upgrade procedure and reports back success or
     failure synchronously. Leader stops the rollout on first error
     (the cluster lands in a mixed-version state; operator decides
     whether to roll back or push forward by hand).

Per-peer local upgrade procedure:
  a. Update MILVUS_IMAGE_TAG in cluster.env via env_upsert_kv.
  b. ./milvus-onprem render to regenerate compose with new tag.
  c. docker compose pull (per-service) so the new image is local
     before we recreate, minimising downtime.
  d. docker compose up -d --force-recreate <milvus-services>:
       2.6: milvus
       2.5: mixcoord proxy querynode datanode indexnode
  e. Wait for container healthy / reachable on Milvus's gRPC port.

Cross-major upgrades (e.g. 2.5 -> 2.6) are deliberately rejected —
they need data migration via backup+restore, not in-place restart.
The check is "major.minor matches the existing tag's major.minor."

Params:
  milvus_version       target tag, e.g. "v2.5.5"
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
from typing import Any

import httpx

from ..jobs import JobContext, register_handler
from ._shell_helpers import run_in_repo

log = logging.getLogger("daemon.workers.version_upgrade")

REPO_PATH = "/repo"
CLUSTER_ENV_PATH = "/etc/milvus-onprem/cluster.env"
HEALTH_TIMEOUT_S = 180  # how long to wait for milvus to come back up


async def run_version_upgrade(ctx: JobContext) -> None:
    """Top-level rolling-upgrade orchestration. Runs on the leader."""
    target = ctx.job.params.get("milvus_version")
    if not target:
        raise ValueError("version-upgrade requires 'milvus_version' param")
    if not re.match(r"^v\d+\.\d+\.\d+$", target):
        raise ValueError(
            f"invalid version {target!r} — expected vMAJOR.MINOR.PATCH "
            f"(e.g. v2.5.5)"
        )

    # Read current state.
    from daemon.main import app
    config = app.state.config
    leader = app.state.leader
    topology = app.state.topology

    if not leader.is_leader:
        raise PermissionError(
            "version-upgrade must run on the leader (HTTP layer should redirect)"
        )

    current = _read_kv("MILVUS_IMAGE_TAG") or "(unknown)"
    ctx.log_writer(f"current MILVUS_IMAGE_TAG: {current}")
    ctx.log_writer(f"target  MILVUS_IMAGE_TAG: {target}")

    if current == target:
        ctx.log_writer("(already at target version — running rolling restart anyway)")
    elif current != "(unknown)":
        # Refuse cross-major-minor in v1.2.
        cur_mm = _major_minor(current)
        tgt_mm = _major_minor(target)
        if cur_mm and tgt_mm and cur_mm != tgt_mm:
            raise ValueError(
                f"refusing cross-major upgrade {current} -> {target}. "
                f"Use backup -> teardown -> re-init at the new version, "
                f"then restore. In-place upgrade is supported only within "
                f"the same major.minor (e.g. v2.5.4 -> v2.5.5)."
            )

    # Decide order. Leader first, then followers in name order.
    leader_name = config.node_name
    leader_ip = config.local_ip
    peers = sorted(topology.peers.items(), key=lambda kv: _node_sort_key(kv[0]))
    sorted_peers = [(n, info["ip"]) for n, info in peers if info.get("ip")]
    # Move leader to the front.
    sorted_peers.sort(key=lambda ni: 0 if ni[0] == leader_name else 1)

    n = len(sorted_peers)
    ctx.log_writer(f"upgrade order: {[name for name, _ in sorted_peers]}")
    ctx.progress_setter(0.05)

    for i, (name, ip) in enumerate(sorted_peers):
        ctx.log_writer("")
        ctx.log_writer(f"[{i+1}/{n}] upgrading {name} @ {ip}")
        if name == leader_name:
            await _upgrade_self(ctx, target)
        else:
            await _upgrade_remote(ctx, ip, config, target)
        ctx.log_writer(f"[{i+1}/{n}] {name} OK")
        ctx.progress_setter(0.05 + (0.95 * (i + 1) / n))

    ctx.log_writer("")
    ctx.log_writer(f"OK rolling upgrade to {target} complete on all {n} peers.")

    # Refresh the cluster-wide version anchor in etcd. lib/render.sh
    # checks this on every render and refuses to render when a peer's
    # cluster.env disagrees with the cluster's canonical version.
    # Resolves QA finding F-R4-C.1 — without the refresh, a partial
    # upgrade or stale anchor could cause render to refuse legitimate
    # operations on already-upgraded peers.
    from daemon.main import CLUSTER_VERSION_KEY
    etcd = app.state.etcd
    try:
        await etcd.put(CLUSTER_VERSION_KEY, target)
        ctx.log_writer(f"updated cluster-version anchor at {CLUSTER_VERSION_KEY} -> {target}")
    except Exception as e:
        ctx.log_writer(f"WARN failed to update cluster-version anchor: {e}")


# ── per-peer local upgrade ───────────────────────────────────────────


async def upgrade_self(ctx_log_writer, target: str) -> None:
    """Local upgrade procedure — also called via /upgrade-self.

    Wraps the steps so both the in-process worker (for the leader)
    and the HTTP handler (for followers) share the same logic.
    `ctx_log_writer` is a callable taking one log line; for HTTP this
    accumulates lines into the response body.
    """
    # 1. Update cluster.env.
    ctx_log_writer(f"updating MILVUS_IMAGE_TAG -> {target} in cluster.env")
    rc, out, err = await _run_repo(
        f"./milvus-onprem render --version >/dev/null 2>&1; "
        f"sed -i 's|^MILVUS_IMAGE_TAG=.*|MILVUS_IMAGE_TAG={target}|' "
        f"{REPO_PATH}/cluster.env"
    )
    if rc != 0:
        raise RuntimeError(
            f"sed cluster.env failed (rc={rc}): {err.strip()[:200]}"
        )

    # 2. Render with the new tag.
    ctx_log_writer("re-rendering templates")
    rc, _, err = await _run_repo("./milvus-onprem render")
    if rc != 0:
        raise RuntimeError(
            f"render failed (rc={rc}): {err.strip()[:200]}"
        )

    # 3. Compose pull so the new image is local before recreate.
    node_name = _read_kv("NODE_NAME")
    compose_file = f"{REPO_PATH}/rendered/{node_name}/docker-compose.yml"
    services = _milvus_services()
    services_arg = " ".join(services)
    ctx_log_writer(f"pulling image {target} for services: {services_arg}")
    rc, out, err = await _run_repo(
        f"docker compose --project-name {node_name} -f {compose_file} "
        f"pull {services_arg}"
    )
    if rc != 0:
        # Pull failures are recoverable — recreate will still try to
        # pull. Just log and continue.
        ctx_log_writer(f"WARN: pull rc={rc} ({err.strip()[:120]}); continuing")

    # 4. Force-recreate the milvus services.
    ctx_log_writer(f"recreating: {services_arg}")
    rc, out, err = await _run_repo(
        f"docker compose --project-name {node_name} -f {compose_file} "
        f"up -d --force-recreate --no-deps {services_arg}"
    )
    if rc != 0:
        raise RuntimeError(
            f"docker compose up --force-recreate failed (rc={rc}): "
            f"{err.strip()[:300]}"
        )

    # 5. Wait for the milvus gRPC port to respond.
    ctx_log_writer("waiting for milvus to come back up")
    deadline = HEALTH_TIMEOUT_S
    elapsed = 0
    port = int(_read_kv("MILVUS_PORT") or "19530")
    while elapsed < deadline:
        rc, _, _ = await _run_repo(f"timeout 2 bash -c '</dev/tcp/127.0.0.1/{port}'")
        if rc == 0:
            ctx_log_writer(f"milvus up on :{port} ({elapsed}s)")
            return
        await asyncio.sleep(3)
        elapsed += 3
    raise RuntimeError(
        f"milvus did not become reachable on :{port} within {deadline}s"
    )


async def _upgrade_self(ctx: JobContext, target: str) -> None:
    """Wrap upgrade_self() with the JobContext's log writer."""
    await upgrade_self(ctx.log_writer, target)


async def _upgrade_remote(
    ctx: JobContext, peer_ip: str, config, target: str
) -> None:
    """POST /upgrade-self on a follower; surface its log + raise on
    non-2xx so the rollout aborts on first failure."""
    url = f"http://{peer_ip}:{config.listen_port}/upgrade-self"
    body = {"milvus_version": target}
    headers = {"Authorization": f"Bearer {config.cluster_token}"}
    ctx.log_writer(f"POST {url}")
    timeout = httpx.Timeout(10.0, read=HEALTH_TIMEOUT_S + 60)
    async with httpx.AsyncClient(timeout=timeout) as c:
        try:
            r = await c.post(url, json=body, headers=headers)
        except httpx.HTTPError as e:
            raise RuntimeError(f"POST {url} failed: {e}") from e
    # Stream the peer's reported log lines into our own buffer.
    if r.status_code != 200:
        raise RuntimeError(
            f"{peer_ip} /upgrade-self returned {r.status_code}: "
            f"{r.text[:500]}"
        )
    try:
        body_json = r.json()
    except Exception:
        raise RuntimeError(f"{peer_ip} /upgrade-self bad JSON: {r.text[:200]}")
    for line in body_json.get("log") or []:
        ctx.log_writer(f"  [{peer_ip}] {line}")
    if body_json.get("error"):
        raise RuntimeError(f"{peer_ip} upgrade failed: {body_json['error']}")


# ── helpers ──────────────────────────────────────────────────────────


async def _run_repo(cmd: str) -> tuple[int, str, str]:
    """Run a shell command from /repo. Returns (rc, stdout, stderr).

    Sets MILVUS_ONPREM_INTERNAL=1 so the bash CLI's multi-version
    render guard (lib/render.sh — F-R4-C.1 fix) skips its etcd check.
    The upgrade flow legitimately renders with a NEW tag while etcd's
    cluster-wide anchor still holds the OLD tag (the worker updates
    the anchor only after the rolling sweep completes); without the
    bypass the worker's own render would refuse mid-upgrade.
    """
    full = f"cd {REPO_PATH} && {cmd}"
    env = {**os.environ, "MILVUS_ONPREM_INTERNAL": "1"}
    proc = await asyncio.create_subprocess_shell(
        full,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        executable="/bin/bash",
        env=env,
    )
    stdout, stderr = await proc.communicate()
    rc = proc.returncode if proc.returncode is not None else -1
    return rc, stdout.decode(errors="replace"), stderr.decode(errors="replace")


def _read_kv(key: str) -> str:
    """Read a single KEY=VALUE from cluster.env via the bind-mount path."""
    try:
        with open(CLUSTER_ENV_PATH) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                if k.strip() == key:
                    return v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return ""


def _major_minor(tag: str) -> str | None:
    """Extract 'X.Y' from a 'vX.Y.Z' style tag; None if unparseable."""
    m = re.match(r"^v?(\d+\.\d+)", tag)
    return m.group(1) if m else None


def _milvus_services() -> list[str]:
    """Service names in the rendered compose to recreate during upgrade.

    Cluster mode (2.5 always; 2.6 distributed):
        per-component containers — mixcoord/proxy/querynode/datanode/
        indexnode (+ streamingnode on 2.6 for woodpecker WAL). Pulsar
        is a singleton not bumped here.
    2.6 standalone:
        a single `milvus` service running `milvus run standalone`.
    """
    tag = _read_kv("MILVUS_IMAGE_TAG")
    mode = _read_kv("MODE") or "standalone"
    if tag.startswith("v2.5"):
        return ["mixcoord", "proxy", "querynode", "datanode", "indexnode"]
    if mode == "distributed":
        return [
            "mixcoord", "proxy", "querynode", "datanode",
            "indexnode", "streamingnode",
        ]
    return ["milvus"]


def _node_sort_key(name: str) -> tuple[int, str]:
    """Order node-1, node-2, ..., node-10 numerically by suffix."""
    m = re.match(r"^node-(\d+)$", name)
    return (int(m.group(1)), name) if m else (10**9, name)


register_handler("version-upgrade", run_version_upgrade)
