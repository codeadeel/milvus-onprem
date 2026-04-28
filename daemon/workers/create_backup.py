"""Worker for the `create-backup` job type.

Reuses `./milvus-onprem create-backup` rather than re-implementing
milvus-backup invocation in Python. The bash command handles the
binary download, YAML config, Pulsar pre-flight (Milvus 2.5), and
strategy flags. We just shell out from inside the daemon container
(which has /repo bind-mounted) and stream the subprocess stdout into
the job's log buffer.

Params (all optional except `name`):
  name           backup name; required
  strategy       passed through to milvus-backup
  collections    comma-separated subset of collections
  milvus_backup_version   override for the binary version
"""

from __future__ import annotations

import logging

from ..jobs import JobContext, register_handler
from ._shell_helpers import run_in_repo

log = logging.getLogger("daemon.workers.create_backup")


async def run_create_backup(ctx: JobContext) -> None:
    """Execute the create-backup CLI; raise on non-zero exit."""
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

    rc = await run_in_repo(ctx, args)
    if rc != 0:
        raise RuntimeError(
            f"create-backup CLI exited with rc={rc} — see job logs above"
        )


register_handler("create-backup", run_create_backup)
