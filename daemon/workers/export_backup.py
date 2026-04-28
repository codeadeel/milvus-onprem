"""Worker for the `export-backup` job type.

Wraps `./milvus-onprem export-backup`, which dumps a previously-created
backup from MinIO into a host-filesystem path (binlogs/ + meta/). This
is the operator-initiated step before moving a backup to off-cluster
storage or another cluster.

Params:
  name           backup name (must already exist in MinIO)         REQUIRED
  to             destination path on the daemon host                REQUIRED
                 (note: this is a path inside the daemon container,
                 which is bind-mounted to the host's /repo and
                 /etc/milvus-onprem; arbitrary host paths require an
                 additional bind mount)
"""

from __future__ import annotations

import logging

from ..jobs import JobContext, register_handler
from ._shell_helpers import run_in_repo

log = logging.getLogger("daemon.workers.export_backup")


async def run_export_backup(ctx: JobContext) -> None:
    """Execute the export-backup CLI; raise on non-zero exit."""
    name = ctx.job.params.get("name")
    to = ctx.job.params.get("to")
    if not name:
        raise ValueError("export-backup requires a 'name' param")
    if not to:
        raise ValueError("export-backup requires a 'to' param")

    args = ["./milvus-onprem", "export-backup", f"--name={name}", f"--to={to}"]

    rc = await run_in_repo(ctx, args)
    if rc != 0:
        raise RuntimeError(
            f"export-backup CLI exited with rc={rc} — see job logs above"
        )


register_handler("export-backup", run_export_backup)
