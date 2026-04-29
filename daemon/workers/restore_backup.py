"""Worker for the `restore-backup` job type.

Wraps `./milvus-onprem restore-backup`, which loads a previously-
exported backup tree (or one already in MinIO) into the live cluster.

Params (passed through to the bash CLI):
  from               filesystem path of an exported backup tree
  name               backup name in MinIO (alternative to --from)
  rename             optional — comma-separated pairs A:B[,C:D,...]
                     to restore collection A as B (matches the bash
                     CLI's `--rename` flag shape exactly).
  no_restore_index   optional bool
  drop_existing      optional bool
  load               optional bool — load collection after restore
"""

from __future__ import annotations

import logging

from ..jobs import JobContext, register_handler
from ._shell_helpers import run_in_repo

log = logging.getLogger("daemon.workers.restore_backup")


async def run_restore_backup(ctx: JobContext) -> None:
    """Execute the restore-backup CLI; raise on non-zero exit."""
    p = ctx.job.params
    if not (p.get("from") or p.get("name")):
        raise ValueError("restore-backup requires either 'from' or 'name'")

    args = ["./milvus-onprem", "restore-backup"]
    has_from = bool(p.get("from"))
    if has_from:
        args.append(f"--from={p['from']}")
    if (v := p.get("name")):
        args.append(f"--name={v}")
    # `name` without `from` means the backup is already in MinIO (e.g.
    # the operator just ran create-backup, so they know the name).
    # The bash CLI requires --skip-upload to acknowledge that path
    # explicitly; add it on the operator's behalf in this branch.
    if p.get("name") and not has_from:
        args.append("--skip-upload")
    if (v := p.get("rename")):
        args.append(f"--rename={v}")
    if (v := p.get("collections")):
        args.append(f"--collections={v}")
    if p.get("no_restore_index"):
        args.append("--no-restore-index")
    if p.get("drop_existing"):
        args.append("--drop-existing")
    if p.get("load"):
        args.append("--load")

    rc = await run_in_repo(ctx, args)
    if rc != 0:
        raise RuntimeError(
            f"restore-backup CLI exited with rc={rc} — see job logs above"
        )


register_handler("restore-backup", run_restore_backup)
