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
from typing import Any

from fastapi import APIRouter, Depends, Request

from .auth import require_token
from .leader import LEADER_KEY

router = APIRouter()

DAEMON_VERSION = "0.1.0"


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
