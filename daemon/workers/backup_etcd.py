"""Worker for the `backup-etcd` job type.

Wraps `./milvus-onprem backup-etcd`, which writes a Raft-consistent
etcd snapshot (the cluster's metadata: collection schemas, segment
indices, MinIO bucket pointers) into MinIO. This is complementary to
`create-backup`, which dumps the actual segment data — together they
form a full disaster-recovery snapshot.

Params: none currently (the bash command takes none).
"""

from __future__ import annotations

import logging

from ..jobs import JobContext, register_handler
from ._shell_helpers import run_in_repo

log = logging.getLogger("daemon.workers.backup_etcd")


async def run_backup_etcd(ctx: JobContext) -> None:
    """Execute the backup-etcd CLI; raise on non-zero exit."""
    args = ["./milvus-onprem", "backup-etcd"]
    rc = await run_in_repo(ctx, args)
    if rc != 0:
        raise RuntimeError(
            f"backup-etcd CLI exited with rc={rc} — see job logs above"
        )


register_handler("backup-etcd", run_backup_etcd)
