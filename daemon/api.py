"""FastAPI router — the daemon's HTTP surface.

Stage 2 ships only the minimum to validate the scaffold:
  GET /health   — liveness, no auth (used by container healthcheck)
  GET /version  — daemon version, no auth
  GET /leader   — current leader info, auth-protected
  GET /topology — current peer mirror, auth-protected

Future stages bolt on /join (Stage 4), /status (Stage 6), the jobs
sub-router (Stage 8), etc. Keeping each operation as its own route
function makes the OpenAPI spec readable and the auth boundary
trivial to audit.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import JSONResponse, RedirectResponse
from pydantic import BaseModel, Field

from dataclasses import asdict

from .auth import require_token
from .joining import JoinError, handle_join
from .jobs import known_types
from .leader import LEADER_KEY

router = APIRouter()
log = logging.getLogger("daemon.api")

DAEMON_VERSION = "0.1.0"


class JoinRequest(BaseModel):
    """Body for `POST /join`. Joiner identifies itself by IP; hostname
    is optional metadata only — node-N name is allocated by the leader."""

    ip: str = Field(..., description="Joiner's IPv4 address (peer-reachable).")
    hostname: str | None = Field(default=None, description="Optional joiner hostname.")


class JoinResponse(BaseModel):
    """Body returned from `POST /join` on success."""

    node_name: str
    local_ip: str
    cluster_env: str
    leader_ip: str


class CreateJobRequest(BaseModel):
    """Body for `POST /jobs`. The `type` must be in known_types() — list
    via `GET /jobs/types`. `params` is opaque; each worker validates its
    own shape."""

    type: str = Field(..., description="Registered job type, e.g. 'create-backup'.")
    params: dict[str, Any] = Field(default_factory=dict)


@router.get("/health", tags=["meta"])
async def health(request: Request) -> dict[str, Any]:
    """Liveness probe. Returns this daemon's basic state.

    Intentionally **unauthenticated** — Docker / k8s-style healthchecks
    shouldn't need a token. The information returned is non-sensitive.
    """
    cfg = request.app.state.config
    leader = request.app.state.leader
    topology = request.app.state.topology
    return {
        "status": "ok",
        "node": cfg.node_name,
        "ip": cfg.local_ip,
        "is_leader": leader.is_leader,
        "peer_count": topology.peer_count,
    }


@router.get("/version", tags=["meta"])
async def version() -> dict[str, str]:
    """Static daemon version string."""
    return {"daemon": DAEMON_VERSION}


@router.get("/leader", dependencies=[Depends(require_token)], tags=["cluster"])
async def get_leader(request: Request) -> dict[str, Any]:
    """Return whoever currently holds the leader lease in etcd.

    Reads directly from etcd so the answer is authoritative even when
    this daemon is a follower with a slightly stale local view.
    """
    raw = await request.app.state.etcd.get(LEADER_KEY)
    if raw is None:
        return {"leader": None}
    try:
        return {"leader": json.loads(raw)}
    except json.JSONDecodeError:
        return {"leader": {"raw": raw, "warning": "unparsable"}}


@router.get("/topology", dependencies=[Depends(require_token)], tags=["cluster"])
async def get_topology(request: Request) -> dict[str, Any]:
    """Return this daemon's local mirror of the topology prefix.

    Auth-gated because peer IPs / hostnames are useful for an attacker.
    """
    topology = request.app.state.topology
    return {
        "peer_count": topology.peer_count,
        "peers": topology.peers,
    }


@router.get("/status", dependencies=[Depends(require_token)], tags=["cluster"])
async def get_status(request: Request) -> dict[str, Any]:
    """Cluster-wide status snapshot.

    Aggregates this daemon's view of cluster identity, leader, peer
    membership, and the local node's daemon health. Operator's CLI
    formats this; the daemon just returns the raw shape.
    """
    cfg = request.app.state.config
    leader = request.app.state.leader
    topology = request.app.state.topology

    leader_info_raw = await request.app.state.etcd.get(LEADER_KEY)
    leader_info: dict[str, Any] | None = None
    if leader_info_raw:
        try:
            leader_info = json.loads(leader_info_raw)
        except json.JSONDecodeError:
            leader_info = {"raw": leader_info_raw}

    return {
        "cluster_name": cfg.cluster_name,
        "this_node": {
            "name": cfg.node_name,
            "ip": cfg.local_ip,
            "is_leader": leader.is_leader,
        },
        "leader": leader_info,
        "peer_count": topology.peer_count,
        "peers": [
            {
                "name": name,
                "ip": info.get("ip"),
                "joined_at": info.get("joined_at"),
                "role": info.get("role", "peer"),
            }
            for name, info in sorted(topology.peers.items())
        ],
    }


@router.get("/urls", dependencies=[Depends(require_token)], tags=["cluster"])
async def get_urls(request: Request) -> dict[str, Any]:
    """Connection URLs for clients.

    Returns each peer's Milvus / nginx-LB / MinIO endpoints so an
    operator can hand them to a downstream user without grepping
    cluster.env. Ports are read from the daemon's config (set at
    container start by render).
    """
    cfg = request.app.state.config
    topology = request.app.state.topology

    # Ports come from the daemon's env. CONTROL_PLANE_PORT is always
    # set; others fall back to the project defaults.
    cp_port = cfg.listen_port
    # The daemon doesn't carry milvus / minio / lb ports as fields, so
    # we infer the project defaults. Operator can override via env.
    milvus_port = int(os.environ.get("MILVUS_ONPREM_MILVUS_PORT", "19530"))
    lb_port = int(os.environ.get("MILVUS_ONPREM_NGINX_LB_PORT", "19537"))
    minio_port = int(os.environ.get("MILVUS_ONPREM_MINIO_API_PORT", "9000"))

    peers = []
    for name, info in sorted(topology.peers.items()):
        ip = info.get("ip")
        if not ip:
            continue
        peers.append(
            {
                "node": name,
                "milvus": f"{ip}:{milvus_port}",
                "lb": f"{ip}:{lb_port}",
                "minio_api": f"http://{ip}:{minio_port}",
                "control_plane": f"http://{ip}:{cp_port}",
            }
        )
    return {"peers": peers}


@router.post(
    "/join",
    dependencies=[Depends(require_token)],
    tags=["cluster"],
    response_model=JoinResponse,
)
async def post_join(req: JoinRequest, request: Request) -> Any:
    """Add a new peer to the cluster.

    Leader-only — this is a write operation that mutates etcd
    membership and the topology key prefix, both of which require
    serialisation. Followers see `is_leader=False` and 307-redirect
    the joiner to whoever currently holds the leader lease.

    On success the response carries everything the joiner needs to
    bring up its own etcd / MinIO / Milvus / daemon (its assigned
    node-N, the cluster.env body to write locally, and the leader's
    IP for follow-up calls).
    """
    leader = request.app.state.leader
    etcd = request.app.state.etcd
    config = request.app.state.config

    # If we're not the leader, bounce the joiner to whoever is. This
    # uses 307 (preserve method+body) rather than 302/303 so the
    # POST stays a POST and the joiner doesn't have to retry.
    if not leader.is_leader:
        leader_info_raw = await etcd.get(LEADER_KEY)
        if not leader_info_raw:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="no leader currently; retry shortly",
            )
        try:
            leader_info = json.loads(leader_info_raw)
            redirect_to = (
                f"http://{leader_info['ip']}:{config.listen_port}/join"
            )
        except (json.JSONDecodeError, KeyError) as e:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=f"leader info unparsable: {e}",
            )
        log.info("redirecting /join from %s to leader at %s",
                 req.ip, leader_info["ip"])
        # Include a JSON body explaining the redirect — curl without
        # `--location-trusted` silently swallows 307s with empty bodies
        # (QA finding F4.2). Tools that don't auto-follow 307 will at
        # least see this message in the response.
        return JSONResponse(
            status_code=307,
            headers={"Location": redirect_to},
            content={
                "redirect_to": redirect_to,
                "leader": leader_info["ip"],
                "hint": (
                    "this peer is a follower; POST /join must reach the "
                    "leader. retry against the URL in `redirect_to`, or "
                    "use `curl --location-trusted -X POST ...` (the bash "
                    "CLI does this automatically)."
                ),
            },
        )

    try:
        result = await handle_join(
            etcd=etcd,
            config=config,
            joiner_ip=req.ip,
            joiner_hostname=req.hostname,
        )
    except JoinError as e:
        # Bad joiner input or conflict. 409 = "your request conflicts
        # with current cluster state."
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=str(e),
        )

    return JoinResponse(
        node_name=result.node_name,
        local_ip=result.local_ip,
        cluster_env=result.cluster_env,
        leader_ip=result.leader_ip,
    )


# ─── Jobs ────────────────────────────────────────────────────────────


@router.get("/jobs/types", dependencies=[Depends(require_token)], tags=["jobs"])
async def list_job_types() -> dict[str, Any]:
    """Enumerate registered job types. Useful for CLI / API discovery."""
    return {"types": known_types()}


@router.get("/jobs", dependencies=[Depends(require_token)], tags=["jobs"])
async def list_jobs(
    request: Request,
    state: str | None = None,
) -> dict[str, Any]:
    """List jobs from etcd, optionally filtered by state.

    Reads work on any daemon — etcd is the source of truth and every
    daemon's mirror sees the same view.
    """
    items = await request.app.state.jobs.list_jobs(state=state)
    return {"count": len(items), "jobs": [asdict(j) for j in items]}


@router.get("/jobs/{job_id}", dependencies=[Depends(require_token)], tags=["jobs"])
async def get_job(job_id: str, request: Request) -> dict[str, Any]:
    """Fetch a single job by id. 404 if unknown."""
    job = await request.app.state.jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail=f"job {job_id} not found")
    return asdict(job)


@router.post("/jobs", dependencies=[Depends(require_token)], tags=["jobs"])
async def post_job(req: CreateJobRequest, request: Request) -> Any:
    """Create + schedule a new job.

    Leader-only — worker tasks run on the leader, so a job created on a
    follower would have nowhere to execute. We 307-redirect followers
    to the leader (same pattern as /join).
    """
    leader = request.app.state.leader
    etcd = request.app.state.etcd
    config = request.app.state.config

    if not leader.is_leader:
        leader_info_raw = await etcd.get(LEADER_KEY)
        if not leader_info_raw:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="no leader currently; retry shortly",
            )
        try:
            info = json.loads(leader_info_raw)
            redirect_to = (
                f"http://{info['ip']}:{config.listen_port}/jobs"
            )
            return JSONResponse(
                status_code=307,
                headers={"Location": redirect_to},
                content={
                    "redirect_to": redirect_to,
                    "leader": info["ip"],
                    "hint": (
                        "this peer is a follower; POST /jobs must reach "
                        "the leader. retry against the URL in "
                        "`redirect_to`, or use `curl --location-trusted "
                        "-X POST ...` (the bash CLI does this "
                        "automatically). Without -L curl swallows the "
                        "redirect silently and your write is lost."
                    ),
                },
            )
        except (json.JSONDecodeError, KeyError) as e:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=f"leader info unparsable: {e}",
            )

    try:
        job = await request.app.state.jobs.create(req.type, req.params)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))
    except PermissionError as e:
        raise HTTPException(status_code=409, detail=str(e))

    return asdict(job)


@router.post(
    "/jobs/{job_id}/cancel",
    dependencies=[Depends(require_token)],
    tags=["jobs"],
)
async def cancel_job(job_id: str, request: Request) -> dict[str, Any]:
    """Best-effort cancel. Returns whether the running task was found."""
    cancelled = await request.app.state.jobs.cancel(job_id)
    return {"job_id": job_id, "cancelled": cancelled}


# ─── Internal: rolling upgrade per-peer self-execute ────────────────


class UpgradeSelfRequest(BaseModel):
    """Body for `POST /upgrade-self`. Sent by the leader's
    version-upgrade worker to each follower in turn."""

    milvus_version: str = Field(..., description="Target image tag, e.g. v2.5.5.")


class UpgradeSelfResponse(BaseModel):
    """Body returned from `POST /upgrade-self` once the local upgrade
    has either succeeded or failed."""

    log: list[str]
    error: str | None = None


class RecreateMinioSelfResponse(BaseModel):
    """Result of a `POST /recreate-minio-self` call."""

    healthy: bool
    error: str | None = None


class RotateSelfRequest(BaseModel):
    """Body for `POST /rotate-self`. The OLD bearer token authenticates
    the request; `new_token` is the value the follower should write
    into its cluster.env."""

    new_token: str = Field(..., min_length=32)


class RotateSelfResponse(BaseModel):
    """Body returned from `POST /rotate-self` once cluster.env is
    updated and a self-recreate is scheduled (the daemon will die
    inside RECREATE_DELAY_S seconds — RPC has already returned by
    then)."""

    log: list[str]
    error: str | None = None


class PeerClockResponse(BaseModel):
    """Body returned from `GET /peer/clock`. Used by `preflight --peer`
    to detect inter-peer time skew without resorting to SSH."""

    ts: float


@router.post(
    "/admin/sweep",
    dependencies=[Depends(require_token)],
    tags=["internal"],
)
async def post_admin_sweep(request: Request) -> dict[str, Any]:
    """Trigger an immediate stuck-running + retention sweep.

    Normally runs on a 30s/1h timer (see daemon/main.py). Useful as
    an operator-on-demand action — e.g. after killing a misconfigured
    daemon, force the new leader to clean up the resulting stuck
    `running` job entries instead of waiting for the next scheduled
    sweep. Leader-only; followers redirect via 307 (the bash CLI's
    `milvus-onprem maintenance --prune-etcd-jobs` calls this with
    `curl --location-trusted`).
    """
    leader = request.app.state.leader
    config = request.app.state.config
    jobs_mgr = request.app.state.jobs

    if not leader.is_leader:
        # Same 307 redirect pattern as /jobs.
        etcd = request.app.state.etcd
        leader_info_raw = await etcd.get(LEADER_KEY)
        if not leader_info_raw:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="no leader currently; retry shortly",
            )
        try:
            info = json.loads(leader_info_raw)
            redirect_to = (
                f"http://{info['ip']}:{config.listen_port}/admin/sweep"
            )
            return JSONResponse(
                status_code=307,
                headers={"Location": redirect_to},
                content={
                    "redirect_to": redirect_to,
                    "leader": info["ip"],
                    "hint": "POST /admin/sweep must reach the leader; retry against `redirect_to` or use --location-trusted",
                },
            )
        except (json.JSONDecodeError, KeyError) as e:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail=f"leader info unparsable: {e}",
            )

    pruned_terminated = await jobs_mgr.prune_old(config.jobs_retention_s)
    pruned_stuck = await jobs_mgr.prune_stuck_running(
        config.jobs_heartbeat_timeout_s
    )
    return {
        "pruned_terminated": pruned_terminated,
        "pruned_stuck_running": pruned_stuck,
    }


@router.post(
    "/admin/step-down",
    dependencies=[Depends(require_token)],
    tags=["internal"],
)
async def post_admin_step_down(request: Request) -> dict[str, Any]:
    """Voluntarily release leadership. Used by the operator's CLI to
    orchestrate a leader self-removal (`remove-node --ip=<leader>`)
    without having to ssh into the leader peer.

    Returns 409 if this daemon isn't currently the leader — the CLI
    is expected to have called `/leader` first and direct the
    step-down to the right peer.
    """
    leader = request.app.state.leader
    if not leader.is_leader:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="not currently the leader; step-down rejected",
        )
    stepped = await leader.step_down(cooldown_s=20.0)
    return {"stepped_down": bool(stepped)}


@router.post(
    "/recreate-minio-self",
    dependencies=[Depends(require_token)],
    tags=["internal"],
    response_model=RecreateMinioSelfResponse,
)
async def post_recreate_minio_self(request: Request) -> Any:
    """Recreate this node's milvus-minio container with the freshly
    rendered compose (which now reflects an updated PEER_IPS).

    Called by the leader's `_rolling_minio_recreate` sweep when topology
    changes. Auth-gated by the cluster bearer token; not meant for
    operators directly. Blocks until MinIO is healthy (or 90s timeout)
    so the leader's rolling loop naturally waits between peers."""
    handlers = request.app.state.handlers
    try:
        await handlers.recreate_minio_local()
        # The local recreate has already waited for healthy; if it
        # returned, MinIO is healthy on this node.
        return RecreateMinioSelfResponse(healthy=True, error=None)
    except Exception as e:
        log.exception("recreate-minio-self failed")
        return RecreateMinioSelfResponse(
            healthy=False, error=f"{type(e).__name__}: {e}"
        )


@router.post(
    "/upgrade-self",
    dependencies=[Depends(require_token)],
    tags=["internal"],
    response_model=UpgradeSelfResponse,
)
async def post_upgrade_self(req: UpgradeSelfRequest, request: Request) -> Any:
    """Execute the local upgrade procedure. Called by the leader's
    version-upgrade orchestrator on each follower in turn — the
    follower runs the same steps the leader ran on itself (update
    cluster.env, render, pull, force-recreate, wait-healthy) and
    returns a structured log + optional error so the leader can
    surface peer-specific failures back to the operator.

    Auth-gated by the cluster bearer token; not meant to be called
    by operators directly. The peer-to-peer model exists because
    Docker doesn't expose remote control without out-of-band auth
    (TLS + mTLS, which we deliberately avoid in v1.2)."""
    # Lazy import: avoids a daemon → workers → daemon cycle at module load.
    from .workers.version_upgrade import upgrade_self

    captured: list[str] = []

    def writer(line: str) -> None:
        captured.append(line.rstrip("\n"))

    try:
        await upgrade_self(writer, req.milvus_version)
        return UpgradeSelfResponse(log=captured, error=None)
    except Exception as e:
        log.exception("upgrade-self failed")
        captured.append(f"ERROR: {type(e).__name__}: {e}")
        return UpgradeSelfResponse(log=captured, error=f"{type(e).__name__}: {e}")


@router.post(
    "/rotate-self",
    dependencies=[Depends(require_token)],
    tags=["internal"],
    response_model=RotateSelfResponse,
)
async def post_rotate_self(req: RotateSelfRequest, request: Request) -> Any:
    """Execute the local CLUSTER_TOKEN rotation. Called by the leader's
    rotate-token orchestrator on each follower in parallel.

    The OLD token authenticates this request; the body carries the NEW
    token the follower should write to its cluster.env. The local
    procedure: update cluster.env (preserving host file ownership),
    re-render, schedule a detached self-recreate of the control-plane
    container (which will kill the daemon ~5s after this response is
    returned).

    Auth-gated by the cluster bearer token; not meant to be called by
    operators directly. The CLI's `rotate-token` command is the
    operator-facing entry point and submits the cluster-wide job."""
    from .workers.rotate_token import rotate_self

    captured: list[str] = []

    def writer(line: str) -> None:
        captured.append(line.rstrip("\n"))

    try:
        await rotate_self(writer, req.new_token)
        return RotateSelfResponse(log=captured, error=None)
    except Exception as e:
        log.exception("rotate-self failed")
        captured.append(f"ERROR: {type(e).__name__}: {e}")
        return RotateSelfResponse(log=captured, error=f"{type(e).__name__}: {e}")


@router.get(
    "/peer/clock",
    dependencies=[Depends(require_token)],
    tags=["meta"],
    response_model=PeerClockResponse,
)
async def get_peer_clock() -> Any:
    """Return this peer's current unix time. Used by `preflight --peer`
    to detect inter-peer time skew (etcd Raft is sensitive to >30s
    skew). Cheap, auth-gated; the bearer token already proves the
    caller is cluster-aware."""
    import time
    return PeerClockResponse(ts=time.time())
