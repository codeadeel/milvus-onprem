"""Worker for the `create-backup` job type.

Reuses the existing `./milvus-onprem create-backup` bash command rather
than re-implementing milvus-backup invocation in Python — that command
already handles the binary download, the YAML config, the Pulsar pre-
flight on Milvus 2.5, and the strategy flags. We just shell out from
inside the daemon container (which has /repo bind-mounted) and stream
the subprocess stdout into the job's log buffer.

The bash command is told it's running under the daemon via the env var
`MILVUS_ONPREM_INTERNAL=1` so it doesn't re-route itself back through
the daemon's HTTP API (recursion guard).

Params accepted (all optional except `name`):
  name           backup name; required (the command will reject missing)
  strategy       passed through to milvus-backup
  collections    comma-separated subset of collections
  milvus_backup_version   override for the binary version
"""

from __future__ import annotations

import asyncio
import logging
import os
import shlex

from ..jobs import JobContext, register_handler

log = logging.getLogger("daemon.workers.create_backup")

REPO_PATH = "/repo"


async def run_create_backup(ctx: JobContext) -> None:
    """Execute the create-backup CLI as a subprocess; stream output."""
    name = ctx.job.params.get("name")
    if not name:
        raise ValueError("create-backup requires a 'name' param")

    args = ["./milvus-onprem", "create-backup", f"--name={name}"]
    if (s := ctx.job.params.get("strategy")):
        args.append(f"--strategy={s}")
    if (c := ctx.job.params.get("collections")):
        args.append(f"--collections={c}")
    if (v := ctx.job.params.get("milvus_backup_version")):
        args.append(f"--milvus-backup-version={v}")

    cmd = " ".join(shlex.quote(a) for a in args)
    full = f"cd {shlex.quote(REPO_PATH)} && {cmd}"

    ctx.log_writer(f"==> running: {cmd}")

    env = {**os.environ, "MILVUS_ONPREM_INTERNAL": "1"}
    proc = await asyncio.create_subprocess_shell(
        full,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,  # merge stderr -> stdout for log capture
        executable="/bin/bash",
        env=env,
    )
    assert proc.stdout is not None

    async for raw in proc.stdout:
        line = raw.decode(errors="replace")
        ctx.log_writer(line)

    rc = await proc.wait()
    if rc != 0:
        raise RuntimeError(
            f"create-backup CLI exited with rc={rc} — see job logs above"
        )


register_handler("create-backup", run_create_backup)
