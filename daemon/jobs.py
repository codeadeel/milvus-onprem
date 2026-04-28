"""Async-job primitive — generic long-running operations with state in etcd.

Backup, restore, upgrade, remove-node and friends all run as `jobs`. The
operator-facing UX is one CLI call that creates the job + polls for
completion; the daemon handles dispatch, persistence, log capture, and
recovery from leader failover.

Lifecycle:
  client POSTs /jobs ({type, params})
  ─────►  leader (creates Job, writes /cluster/jobs/<uuid>, schedules
          asyncio.Task that runs the registered handler)
  ─────►  worker fn streams stdout into a capped log buffer; periodic
          flushes persist Job state to etcd; final state stored at end

State persistence:
  /cluster/jobs/<uuid>   JSON Job dict (state, progress, last-N log lines,
                         error, started_at, finished_at, owner). Single
                         key per job — keeps things simple at the cost of
                         some etcd value-size pressure on long log tails.

Persistence rate:
  Every 2s while a job is running we re-PUT the Job to etcd, so a poll
  from /jobs/<id> never lags behind reality by more than that window.

Failure modes / recovery:
  - Worker fn raises: state→failed, error captured.
  - Worker fn cancelled (asyncio.CancelledError): state→cancelled.
  - Leader dies mid-job: worker task dies with the leader. New leader sees
    state=running but no living owner; v1.1 just leaves it as a stuck
    "running" entry the operator can clean up. Stage 9+ adds resume
    semantics keyed on the job type.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import asdict, dataclass, field
from typing import Any

from .etcd_client import EtcdClient
from .leader import LeaderElector

log = logging.getLogger("daemon.jobs")

JOBS_PREFIX = "/cluster/jobs/"
LOG_TAIL_LINES = 200          # last N stdout lines kept on the Job
LOG_LINE_CAP_CHARS = 4000     # truncate any single line longer than this


@dataclass
class Job:
    """One long-running operation. Serialised as the etcd value at
    `/cluster/jobs/<id>`."""

    id: str
    type: str
    params: dict[str, Any]
    state: str            # pending | running | done | failed | cancelled
    progress: float       # 0.0 → 1.0; -1 if the worker doesn't track it
    started_at: float     # unix seconds when the job entry was created
    finished_at: float | None
    error: str | None
    owner: str            # node_name of the daemon executing it
    logs: list[str] = field(default_factory=list)

    def to_json(self) -> str:
        """Compact JSON for etcd value storage."""
        return json.dumps(asdict(self), separators=(",", ":"))

    @classmethod
    def from_json(cls, s: str) -> "Job":
        """Inverse of to_json()."""
        return cls(**json.loads(s))


# Worker registration. Each job type has exactly one async handler that
# accepts a JobContext (params + log writer + progress setter).
WorkerFn = Callable[["JobContext"], Awaitable[None]]
_handlers: dict[str, WorkerFn] = {}


def register_handler(job_type: str, fn: WorkerFn) -> None:
    """Register an async worker for `job_type`. Called once at import time
    by each module under `daemon/workers/`."""
    if job_type in _handlers:
        log.warning("re-registering handler for %s — overwriting", job_type)
    _handlers[job_type] = fn


def known_types() -> list[str]:
    """All registered job types — used by /jobs/types and validation."""
    return sorted(_handlers.keys())


@dataclass
class JobContext:
    """Plumbing handed to a worker fn. Reads params via `job.params`;
    appends log lines via `log_writer(line)`; updates progress via
    `progress_setter(p)`. The worker doesn't need to touch etcd directly."""

    job: Job
    log_writer: Callable[[str], None]
    progress_setter: Callable[[float], None]


class JobsManager:
    """Owns the job-execution loop on a single daemon.

    Public API: create / list / get / cancel. Only the leader creates;
    followers 307-redirect at the HTTP layer. Reads (list / get) work on
    any daemon since they're served straight from the etcd mirror.

    Internally:
      - `_running` maps job_id -> the asyncio.Task running it. Used for
        cancellation. Cleared on completion.
      - `_executor()` is the per-job background task that wraps the
        worker fn with state transitions + periodic etcd flushes.
    """

    def __init__(
        self,
        etcd: EtcdClient,
        leader: LeaderElector,
        node_name: str,
    ):
        """Store deps. No I/O at construction; jobs created later via .create()."""
        self._etcd = etcd
        self._leader = leader
        self._node = node_name
        self._running: dict[str, asyncio.Task[None]] = {}

    async def create(self, job_type: str, params: dict[str, Any]) -> Job:
        """Validate + write a new job, kick off its execution task. Returns
        the Job in `pending` state."""
        if job_type not in _handlers:
            raise ValueError(
                f"unknown job type: {job_type!r} (known: {known_types()})"
            )
        if not self._leader.is_leader:
            raise PermissionError(
                "only the leader may create jobs; HTTP layer should 307-redirect"
            )
        jid = str(uuid.uuid4())
        job = Job(
            id=jid,
            type=job_type,
            params=params,
            state="pending",
            progress=0.0,
            started_at=time.time(),
            finished_at=None,
            error=None,
            owner=self._node,
        )
        await self._etcd.put(self._key(jid), job.to_json())
        log.info("created job %s type=%s", jid, job_type)
        # Schedule the executor as an asyncio task so /jobs returns
        # immediately to the caller.
        task = asyncio.create_task(self._execute(job), name=f"job-{jid}")
        self._running[jid] = task
        return job

    async def list_jobs(self, *, state: str | None = None) -> list[Job]:
        """List all known jobs, optionally filtered by state. Most-recent
        first by started_at."""
        all_keys = await self._etcd.get_prefix(JOBS_PREFIX)
        out: list[Job] = []
        for k, v in all_keys.items():
            jid = k.removeprefix(JOBS_PREFIX)
            if "/" in jid:  # ignore future sub-keys (logs/, owner/, etc.)
                continue
            try:
                job = Job.from_json(v)
            except (json.JSONDecodeError, TypeError) as e:
                log.warning("ignoring malformed job %s: %s", jid, e)
                continue
            if state is not None and job.state != state:
                continue
            out.append(job)
        return sorted(out, key=lambda j: j.started_at, reverse=True)

    async def get(self, jid: str) -> Job | None:
        """Return a single job by id, or None if absent."""
        v = await self._etcd.get(self._key(jid))
        if v is None:
            return None
        try:
            return Job.from_json(v)
        except (json.JSONDecodeError, TypeError):
            return None

    async def cancel(self, jid: str) -> bool:
        """Request cancellation of a running job. Returns True if we owned
        the task, False if it wasn't running on this daemon (or had already
        finished)."""
        task = self._running.get(jid)
        if task is None or task.done():
            return False
        task.cancel()
        return True

    def _key(self, jid: str) -> str:
        """Compose the etcd key for a job id."""
        return f"{JOBS_PREFIX}{jid}"

    async def prune_old(self, retention_s: int) -> int:
        """Delete terminated jobs older than `retention_s`.

        Terminated = done | failed | cancelled (anything with a
        `finished_at`). Running/pending jobs are skipped — even if their
        owner died, the operator should clean those up explicitly so
        they don't lose evidence of a stuck job.

        Returns number of jobs deleted. Caller is expected to gate on
        leader status; this method itself is safe to call from any
        daemon (idempotent — etcd delete of a missing key is a no-op).
        """
        cutoff = time.time() - retention_s
        deleted = 0
        for job in await self.list_jobs():
            if job.state not in ("done", "failed", "cancelled"):
                continue
            if job.finished_at is None or job.finished_at >= cutoff:
                continue
            try:
                await self._etcd.delete(self._key(job.id))
                deleted += 1
            except Exception as e:
                log.warning("prune of job %s failed: %s", job.id, e)
        if deleted:
            log.info(
                "pruned %d terminated job(s) older than %ds (cutoff=%d)",
                deleted, retention_s, int(cutoff),
            )
        return deleted

    async def _execute(self, job: Job) -> None:
        """Wrap the worker fn with state transitions + periodic flushes.

        Transitions: pending → running → (done | failed | cancelled).
        Logs and progress are kept on the Job object; a background flusher
        re-PUTs every 2s. Final state is always flushed in the finally
        block.
        """
        handler = _handlers[job.type]

        def log_writer(line: str) -> None:
            text = line.rstrip("\n")
            if len(text) > LOG_LINE_CAP_CHARS:
                text = text[:LOG_LINE_CAP_CHARS] + "…[truncated]"
            job.logs.append(text)
            if len(job.logs) > LOG_TAIL_LINES:
                job.logs = job.logs[-LOG_TAIL_LINES:]

        def progress_setter(p: float) -> None:
            job.progress = max(0.0, min(1.0, p))

        async def periodic_flush() -> None:
            try:
                while True:
                    await asyncio.sleep(2)
                    try:
                        await self._etcd.put(self._key(job.id), job.to_json())
                    except Exception as e:
                        log.warning("job %s flush failed: %s", job.id, e)
            except asyncio.CancelledError:
                pass

        job.state = "running"
        await self._etcd.put(self._key(job.id), job.to_json())

        flusher = asyncio.create_task(periodic_flush(), name=f"flush-{job.id}")
        ctx = JobContext(
            job=job, log_writer=log_writer, progress_setter=progress_setter
        )
        try:
            await handler(ctx)
            job.state = "done"
            job.progress = 1.0
            log.info("job %s completed OK", job.id)
        except asyncio.CancelledError:
            job.state = "cancelled"
            log.info("job %s cancelled", job.id)
            raise
        except Exception as e:
            log.exception("job %s failed: %s", job.id, e)
            job.state = "failed"
            job.error = f"{type(e).__name__}: {e}"
        finally:
            flusher.cancel()
            try:
                await flusher
            except (asyncio.CancelledError, Exception):
                pass
            job.finished_at = time.time()
            try:
                await self._etcd.put(self._key(job.id), job.to_json())
            except Exception as e:
                log.warning("final flush of job %s failed: %s", job.id, e)
            self._running.pop(job.id, None)
