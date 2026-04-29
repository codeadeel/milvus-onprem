"""Shared helpers for workers that shell out to bash CLI commands.

The daemon container runs as root by default (so it can talk to the
docker socket). When it shells out to `./milvus-onprem create-backup`
or similar from inside the container, those subprocesses also run as
root and write files (`.local/backup.yaml`, `logs/backup.log`,
`rendered/<node>/...`) under the host's bind-mounted repo path. Those
files end up owned by root on the host, and the operator's CLI —
which runs as the host user — can no longer overwrite them.

`run_in_repo()` centralises the shell-out plus the post-write chown
so every worker that touches the bind-mounted repo gets the
ownership-preservation behaviour for free.
"""

from __future__ import annotations

import asyncio
import logging
import os
import shlex
from collections.abc import Callable
from pathlib import Path

from ..jobs import JobContext

log = logging.getLogger("daemon.workers.shell")

REPO_PATH = "/repo"
# /repo/cluster.env (directory mount) instead of the file mount at
# /etc/milvus-onprem/cluster.env. Atomic-rename writes invalidate
# single-file bind mounts; the directory mount sees new content live.
CLUSTER_ENV_PATH = "/repo/cluster.env"

# Paths under /repo that a worker subprocess might write to. We chown
# these back to the operator's UID/GID after each subprocess exits.
_OWNERSHIP_PATHS = (".local", "logs", "rendered", "cluster.env", "cluster.env.bak")


def _operator_uid_gid() -> tuple[int, int]:
    """Return the (uid, gid) of cluster.env on the host. The daemon
    matches files to that owner so the operator's CLI can keep
    interacting with them."""
    st = os.stat(CLUSTER_ENV_PATH)
    return st.st_uid, st.st_gid


async def run_in_repo(
    ctx: JobContext,
    args: list[str],
    *,
    extra_env: dict[str, str] | None = None,
    on_line: Callable[[str], None] | None = None,
) -> int:
    """Spawn `args` as a subprocess from the bind-mounted /repo directory,
    streaming stdout+stderr into `ctx.log_writer` (and optionally `on_line`),
    then chown any files it wrote back to the operator UID/GID.

    Returns the subprocess exit code; doesn't raise on non-zero — the
    caller decides whether to translate that into a job failure.

    `extra_env` is merged into os.environ for the child. `MILVUS_ONPREM_
    INTERNAL=1` is always set as a recursion guard so the bash CLI runs
    locally instead of routing back through the daemon.
    """
    cmd = " ".join(shlex.quote(a) for a in args)
    full = f"cd {shlex.quote(REPO_PATH)} && {cmd}"
    ctx.log_writer(f"==> running: {cmd}")

    env = {**os.environ, "MILVUS_ONPREM_INTERNAL": "1"}
    if extra_env:
        env.update(extra_env)

    proc = await asyncio.create_subprocess_shell(
        full,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
        executable="/bin/bash",
        env=env,
    )
    assert proc.stdout is not None

    async for raw in proc.stdout:
        line = raw.decode(errors="replace")
        ctx.log_writer(line)
        if on_line is not None:
            try:
                on_line(line)
            except Exception as e:
                log.warning("on_line callback raised: %s", e)

    rc = await proc.wait()

    # Best-effort chown on any paths the subprocess might have touched.
    # We don't fail the job if this fails — the worker already did its
    # main work; the chown is operator-ergonomic, not correctness.
    try:
        await _chown_artifacts()
    except Exception as e:
        log.warning("post-subprocess chown failed: %s", e)

    return rc


async def _chown_artifacts() -> None:
    """Chown the operator-facing paths under /repo back to the operator's
    UID/GID. Skips paths that don't exist."""
    uid, gid = _operator_uid_gid()
    for rel in _OWNERSHIP_PATHS:
        p = Path(REPO_PATH) / rel
        if not p.exists():
            continue
        # Use shell chown -R rather than os.walk for speed on large
        # rendered/ trees.
        proc = await asyncio.create_subprocess_exec(
            "chown", "-R", f"{uid}:{gid}", str(p),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
        _, err = await proc.communicate()
        if proc.returncode != 0:
            log.warning("chown %s: %s", p, err.decode(errors="replace").strip())
