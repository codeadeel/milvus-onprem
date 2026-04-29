"""Worker for the `rotate-token` job — atomic cluster-wide CLUSTER_TOKEN rotation.

Operator triggers `./milvus-onprem rotate-token` on any peer. The bash
CLI POSTs the job to its local daemon, which 307s to the leader. The
job orchestrator runs on the leader.

The daemon-coordinated flow is the only supported path. Cross-peer
operations must not use SSH; production peers don't have SSH between
them.

Steps:

  1. Validate target token format (>= 32 chars). The CLI generates
     one if the operator didn't supply.
  2. For each follower IN PARALLEL: HTTP POST /rotate-self with the
     new token in the body and the OLD token in the Authorization
     header. The follower writes cluster.env, re-renders, and
     schedules a delayed self-recreate of its control-plane container
     (so the HTTP response goes back BEFORE the daemon dies). Wait
     for all 200s. Any non-200 aborts the rotation immediately —
     the cluster is left half-rotated and the operator must recover
     by re-running with the same `--new-token` value.
  3. Leader rotates itself (same shared `rotate_self()` logic), then
     schedules its own delayed self-recreate.
  4. Return success. The jobs framework writes `state=done` to etcd
     before this daemon's container dies in the recreate window;
     subsequent watchers see the job as completed.

Verification of the new token across all peers happens client-side
(the bash CLI polls /leader on every peer with the new token after
the dust settles). The job worker doesn't try to verify because by
the end, its OWN daemon is about to die.

Params:
  new_token            target bearer token, >= 32 chars
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import Any

import httpx

from ..handlers import _upsert_kv
from ..jobs import JobContext, register_handler

log = logging.getLogger("daemon.workers.rotate_token")

REPO_PATH = "/repo"
RECREATE_DELAY_S = 5  # detached subprocess waits this long before killing the daemon


async def run_rotate_token(ctx: JobContext) -> None:
    """Top-level rotation orchestration. Runs on the leader."""
    new_token = ctx.job.params.get("new_token") or ""
    if not new_token or len(new_token) < 32:
        raise ValueError(
            "rotate-token requires 'new_token' param of >= 32 chars"
        )

    from daemon.main import app
    config = app.state.config
    leader = app.state.leader
    topology = app.state.topology

    if not leader.is_leader:
        raise PermissionError(
            "rotate-token must run on the leader (HTTP layer should redirect)"
        )

    leader_name = config.node_name
    sorted_peers = sorted(
        ((p["name"], p["ip"]) for p in topology.peers),
        key=lambda ni: _node_sort_key(ni[0]),
    )
    follower_peers = [(n, ip) for n, ip in sorted_peers if n != leader_name]

    ctx.log_writer(f"rotating CLUSTER_TOKEN across {len(sorted_peers)} peer(s)")
    ctx.log_writer(f"leader: {leader_name}; followers: {[n for n, _ in follower_peers]}")
    ctx.progress_setter(0.05)

    # Step 1: fan out to followers in parallel.
    if follower_peers:
        ctx.log_writer("")
        ctx.log_writer("==> rotating followers (parallel)")
        results = await asyncio.gather(
            *[
                _rotate_remote(ctx, ip, name, config, new_token)
                for name, ip in follower_peers
            ],
            return_exceptions=True,
        )
        failures = [
            (name, r)
            for (name, _), r in zip(follower_peers, results)
            if isinstance(r, Exception)
        ]
        if failures:
            for name, exc in failures:
                ctx.log_writer(f"  [{name}] FAILED: {exc}")
            raise RuntimeError(
                f"{len(failures)} follower(s) failed to rotate; "
                f"cluster left half-rotated. Re-run with the same "
                f"--new-token to retry."
            )
        ctx.log_writer(f"  all {len(follower_peers)} follower(s) rotated")

    ctx.progress_setter(0.85)

    # Step 2: leader rotates itself last.
    ctx.log_writer("")
    ctx.log_writer(f"==> rotating leader ({leader_name})")
    await rotate_self(ctx.log_writer, new_token)

    ctx.progress_setter(1.0)
    ctx.log_writer("")
    ctx.log_writer(
        f"OK rotation complete on all {len(sorted_peers)} peer(s). "
        f"Daemons will recreate with the new token in ~{RECREATE_DELAY_S}s."
    )


async def rotate_self(ctx_log_writer, new_token: str) -> None:
    """Local rotation procedure — also called via /rotate-self.

    Updates cluster.env (preserving the host file's owner via _upsert_kv),
    re-renders, and schedules a detached self-recreate of the
    control-plane container. Returns BEFORE the daemon container dies,
    so the HTTP response can land or the job-worker can mark the job
    done.
    """
    cluster_env = os.path.join(REPO_PATH, "cluster.env")

    ctx_log_writer("updating CLUSTER_TOKEN in cluster.env")
    # _upsert_kv stat()s before write and chown()s the new tmp file
    # back to the original UID/GID, so the host operator's CLI keeps
    # ownership of cluster.env after the daemon edits it.
    await asyncio.to_thread(_upsert_kv, cluster_env, "CLUSTER_TOKEN", new_token)

    ctx_log_writer("re-rendering templates")
    rc, _, err = await _run_repo("./milvus-onprem render")
    if rc != 0:
        raise RuntimeError(f"render failed (rc={rc}): {err.strip()[:200]}")

    node_name = _read_kv("NODE_NAME")
    if not node_name:
        raise RuntimeError("rotate-self: NODE_NAME missing from cluster.env after render")
    compose_file = f"{REPO_PATH}/rendered/{node_name}/docker-compose.yml"
    if not os.path.exists(compose_file):
        raise RuntimeError(f"rotate-self: rendered compose missing at {compose_file}")

    # Schedule a detached recreate. Sleep first so the job framework
    # can persist state=done / the HTTP response can return before the
    # daemon container dies.
    ctx_log_writer(f"scheduling self-recreate in {RECREATE_DELAY_S}s")
    cmd = (
        f"sleep {RECREATE_DELAY_S} && "
        f"docker compose --project-name {node_name} -f {compose_file} "
        f"up -d --force-recreate --no-deps control-plane "
        f">/tmp/rotate-recreate.log 2>&1"
    )
    # start_new_session puts the subprocess in its own process group so
    # it survives the daemon's death.
    await asyncio.create_subprocess_shell(
        f"nohup bash -c '{cmd}' </dev/null >/dev/null 2>&1 &",
        executable="/bin/bash",
        start_new_session=True,
    )


async def _rotate_remote(
    ctx: JobContext, peer_ip: str, peer_name: str, config, new_token: str
) -> None:
    """POST /rotate-self on a follower with the OLD bearer token.

    The OLD token authenticates this request; the body carries the
    NEW token the follower should write. Raises on non-2xx so the
    caller can collect failures."""
    url = f"http://{peer_ip}:{config.listen_port}/rotate-self"
    body = {"new_token": new_token}
    headers = {"Authorization": f"Bearer {config.cluster_token}"}
    timeout = httpx.Timeout(10.0, read=30.0)
    ctx.log_writer(f"  [{peer_name}] POST {url}")
    async with httpx.AsyncClient(timeout=timeout) as c:
        try:
            r = await c.post(url, json=body, headers=headers)
        except httpx.HTTPError as e:
            raise RuntimeError(f"POST {url} failed: {e}") from e
    if r.status_code != 200:
        raise RuntimeError(
            f"{peer_ip} /rotate-self returned {r.status_code}: {r.text[:300]}"
        )
    try:
        body_json = r.json()
    except Exception:
        raise RuntimeError(f"{peer_ip} /rotate-self bad JSON: {r.text[:200]}")
    for line in body_json.get("log") or []:
        ctx.log_writer(f"  [{peer_name}] {line}")
    if body_json.get("error"):
        raise RuntimeError(f"{peer_ip} rotate failed: {body_json['error']}")


# ── helpers ──────────────────────────────────────────────────────────


async def _run_repo(cmd: str) -> tuple[int, str, str]:
    """Run a shell command from /repo. Returns (rc, stdout, stderr)."""
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
    """Read a single KEY=VALUE from cluster.env via the rw bind-mount."""
    try:
        with open(f"{REPO_PATH}/cluster.env") as f:
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


def _node_sort_key(name: str) -> tuple[int, str]:
    """Order node-1, node-2, ... numerically by suffix."""
    import re
    m = re.match(r"^node-(\d+)$", name)
    return (int(m.group(1)), name) if m else (10**9, name)


register_handler("rotate-token", run_rotate_token)
