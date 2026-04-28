"""Bearer-token authentication for the FastAPI daemon.

A single shared `CLUSTER_TOKEN` (set at init, distributed to every
peer in cluster.env) gates all mutating endpoints. Read-only health
endpoints — used by docker / monitoring — are deliberately exempt
so a healthcheck doesn't need credentials.

Constant-time comparison guards against timing side-channels even
though the token is high-entropy enough that this is academic.
"""

from __future__ import annotations

import secrets

from fastapi import Header, HTTPException, Request, status

# Endpoints that don't require auth. Keep this list short and obvious.
PUBLIC_PATHS: frozenset[str] = frozenset(
    {
        "/health",
        "/version",
        "/docs",
        "/redoc",
        "/openapi.json",
    }
)


async def require_token(
    request: Request,
    authorization: str | None = Header(default=None),
) -> None:
    """FastAPI dependency that enforces `Authorization: Bearer <token>`.

    Raises 401 on a missing or malformed header, 403 on a bad token.
    Returns None on success — callers attach this via
    `Depends(require_token)`.
    """
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="missing bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    presented = authorization.split(" ", 1)[1].strip()
    expected: str = request.app.state.config.cluster_token
    if not secrets.compare_digest(presented, expected):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="invalid token",
        )
