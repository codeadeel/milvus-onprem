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
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import RedirectResponse
from pydantic import BaseModel, Field

from .auth import require_token
from .joining import JoinError, handle_join
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
        return RedirectResponse(url=redirect_to, status_code=307)

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
