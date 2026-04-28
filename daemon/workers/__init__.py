"""Job workers — one module per supported job type.

Each module calls `register_handler(type, fn)` at import time, so the
import side-effect is what makes the type known to JobsManager. To add
a new job type:

    1. Drop `<your_type>.py` here with an `async def run_X(ctx):`
    2. Call `register_handler("<your-type>", run_X)` at module level
    3. Add the import below so it's loaded at daemon startup

`daemon/main.py` imports this package once during lifespan.
"""

from . import create_backup   # noqa: F401  -- registers "create-backup"
from . import export_backup   # noqa: F401  -- registers "export-backup"
from . import restore_backup  # noqa: F401  -- registers "restore-backup"
from . import backup_etcd     # noqa: F401  -- registers "backup-etcd"
