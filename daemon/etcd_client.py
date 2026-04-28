"""Thin async client for the etcd v3 HTTP gateway.

Why not python-etcd3 / etcd3 / etcd3-py? All three are unmaintained or
very intermittently maintained. The etcd v3 HTTP gateway is built into
every etcd 3.x release, ships JSON over HTTP, and gives us everything
we need (lease, kv, txn, watch). httpx handles connection pooling and
async streaming for us.

Conventions:
  - Keys and values are bytes/strings on the wire and base64-encoded in
    JSON. We hide that here; callers pass plain str.
  - One client wraps many endpoints; we round-robin and fail over on
    connection error.
  - Watches are async generators.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
from collections.abc import AsyncIterator
from typing import Any

import httpx

log = logging.getLogger("daemon.etcd")


def _b64(s: str) -> str:
    """Base64-encode a UTF-8 string for an etcd JSON request body."""
    return base64.b64encode(s.encode()).decode()


def _b64dec(s: str) -> str:
    """Decode an etcd response field back into a UTF-8 string."""
    return base64.b64decode(s).decode()


def _prefix_end(prefix: str) -> str:
    """Compute the exclusive `range_end` for a prefix scan.

    Etcd treats range queries as `[key, range_end)`. To scan a prefix
    we need the next-larger string. For ASCII paths "increment the
    last byte" is correct and avoids wraparound concerns.
    """
    if not prefix:
        return ""
    return prefix[:-1] + chr(ord(prefix[-1]) + 1)


class EtcdClient:
    """Async client over the etcd v3 HTTP gateway.

    One client wraps multiple endpoints and round-robins on connection
    error so a follower-side daemon stays useful when a peer's etcd is
    flaky. Not thread-safe (everything is asyncio); fine for our daemon
    which runs everything on a single event loop.
    """

    def __init__(self, endpoints: list[str], timeout_s: float = 5.0):
        """Initialise with one or more `http://host:port` endpoints."""
        if not endpoints:
            raise ValueError("at least one etcd endpoint required")
        self._endpoints = endpoints
        self._idx = 0
        self._http = httpx.AsyncClient(timeout=timeout_s)

    async def close(self) -> None:
        """Tear down the underlying HTTP client cleanly."""
        await self._http.aclose()

    # ── transport ────────────────────────────────────────────────────

    def _url(self, path: str) -> str:
        """Build a full URL against the currently-preferred endpoint."""
        ep = self._endpoints[self._idx % len(self._endpoints)]
        return f"{ep.rstrip('/')}{path}"

    async def _post(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        """POST JSON to etcd, failing over to the next endpoint on error.

        Tries each endpoint in turn (one round) and raises if all fail.
        Bumps the round-robin index on failure so subsequent calls
        prefer the still-healthy endpoint.
        """
        last_err: Exception | None = None
        for _ in range(len(self._endpoints)):
            url = self._url(path)
            try:
                r = await self._http.post(url, json=body)
                r.raise_for_status()
                return r.json()
            except (httpx.HTTPError, httpx.TimeoutException) as e:
                last_err = e
                self._idx += 1
        raise RuntimeError(f"etcd: all endpoints failed: {last_err}")

    # ── leases ───────────────────────────────────────────────────────

    async def lease_grant(self, ttl_s: int) -> int:
        """Grant a new lease with the given TTL, in seconds. Returns lease ID."""
        r = await self._post("/v3/lease/grant", {"TTL": ttl_s})
        return int(r["ID"])

    async def lease_keepalive(self, lease_id: int) -> int:
        """Single keep-alive ping. Returns remaining TTL.

        Raises RuntimeError if the lease has expired or never existed
        (etcd signals this by omitting `TTL` from the response).
        """
        r = await self._post("/v3/lease/keepalive", {"ID": lease_id})
        if "result" in r:
            r = r["result"]
        ttl = r.get("TTL")
        if ttl is None:
            raise RuntimeError(f"lease {lease_id} not found / expired")
        return int(ttl)

    async def lease_revoke(self, lease_id: int) -> None:
        """Revoke a lease; all keys attached to it are deleted immediately."""
        await self._post("/v3/lease/revoke", {"ID": lease_id})

    # ── cluster membership ───────────────────────────────────────────

    async def member_add(self, peer_urls: list[str]) -> dict[str, Any]:
        """Add a learner / voting member to the etcd Raft cluster.

        Returns the full response from etcd, including:
          - `member`: the new member entry (id, name=<empty>, peerURLs)
          - `members`: every member's entry post-update — used by the
            joiner to compute its --initial-cluster argument

        The new member is `unstarted` until its etcd process starts
        with `--initial-cluster-state=existing` and connects.
        """
        return await self._post(
            "/v3/cluster/member/add",
            {"peerURLs": peer_urls},
        )

    async def member_list(self) -> list[dict[str, Any]]:
        """Return the etcd Raft membership as a list of member dicts.

        Useful for sanity checks and for computing `--initial-cluster`
        strings without re-issuing a member-add.
        """
        r = await self._post("/v3/cluster/member/list", {})
        return r.get("members") or []

    # ── kv ───────────────────────────────────────────────────────────

    async def put(
        self, key: str, value: str, lease_id: int | None = None
    ) -> None:
        """Unconditionally set `key` to `value`, optionally tied to a lease."""
        body: dict[str, Any] = {"key": _b64(key), "value": _b64(value)}
        if lease_id is not None:
            body["lease"] = lease_id
        await self._post("/v3/kv/put", body)

    async def get(self, key: str) -> str | None:
        """Fetch a single key's value, or None if absent."""
        r = await self._post("/v3/kv/range", {"key": _b64(key)})
        kvs = r.get("kvs") or []
        if not kvs:
            return None
        return _b64dec(kvs[0]["value"])

    async def get_prefix(self, prefix: str) -> dict[str, str]:
        """Range-scan all keys under `prefix`. Returns `{key: value}`."""
        body = {"key": _b64(prefix), "range_end": _b64(_prefix_end(prefix))}
        r = await self._post("/v3/kv/range", body)
        out: dict[str, str] = {}
        for kv in r.get("kvs") or []:
            out[_b64dec(kv["key"])] = _b64dec(kv["value"])
        return out

    async def delete(self, key: str) -> None:
        """Delete a single key. No error if it doesn't exist."""
        await self._post("/v3/kv/delete_range", {"key": _b64(key)})

    # ── transactions (CAS) ───────────────────────────────────────────

    async def put_if_absent(
        self, key: str, value: str, lease_id: int | None = None
    ) -> bool:
        """Atomic create-or-skip. Returns True if we set it, False if it
        already existed.

        Used by the leader-elector to claim `/cluster/leader`: every
        candidate runs this with their own lease, exactly one wins.
        """
        request_put: dict[str, Any] = {"key": _b64(key), "value": _b64(value)}
        if lease_id is not None:
            request_put["lease"] = lease_id
        body = {
            "compare": [
                {
                    "result": "EQUAL",
                    "target": "CREATE",
                    "key": _b64(key),
                    "create_revision": "0",
                }
            ],
            "success": [{"request_put": request_put}],
            "failure": [],
        }
        r = await self._post("/v3/kv/txn", body)
        return bool(r.get("succeeded", False))

    # ── watches ──────────────────────────────────────────────────────

    async def watch_prefix(
        self, prefix: str, *, start_revision: int | None = None
    ) -> AsyncIterator[dict[str, Any]]:
        """Yield watch events for keys under `prefix`.

        Streams indefinitely, reconnecting with backoff on transport
        errors. Pass `start_revision` to replay history from a given
        point (useful after a daemon restart). Each yielded event dict:

            {"type": "PUT"|"DELETE", "key": str,
             "value": str | None, "rev": int}

        Caller breaks the loop to stop watching; the underlying HTTP
        stream is then cleaned up by the async context manager.
        """
        create_request: dict[str, Any] = {
            "key": _b64(prefix),
            "range_end": _b64(_prefix_end(prefix)),
        }
        if start_revision is not None:
            create_request["start_revision"] = str(start_revision)
        req = {"create_request": create_request}

        while True:
            url = self._url("/v3/watch")
            try:
                async with self._http.stream(
                    "POST",
                    url,
                    json=req,
                    timeout=httpx.Timeout(5.0, read=None),
                ) as r:
                    r.raise_for_status()
                    async for line in r.aiter_lines():
                        if not line:
                            continue
                        try:
                            msg = json.loads(line)
                        except json.JSONDecodeError:
                            log.warning("watch: bad json line: %r", line[:200])
                            continue
                        result = msg.get("result", {})
                        for ev in result.get("events") or []:
                            yield self._normalise_event(ev)
            except (httpx.HTTPError, httpx.TimeoutException) as e:
                log.warning("watch stream broken (%s); reconnecting in 2s", e)
                self._idx += 1
                await asyncio.sleep(2)

    @staticmethod
    def _normalise_event(ev: dict[str, Any]) -> dict[str, Any]:
        """Flatten the etcd watch wire format into a friendlier shape."""
        kv = ev.get("kv") or {}
        key_b64 = kv.get("key", "")
        value_b64 = kv.get("value")
        return {
            "type": ev.get("type", "PUT"),  # etcd omits type field for PUT
            "key": _b64dec(key_b64) if key_b64 else "",
            "value": _b64dec(value_b64) if value_b64 else None,
            "rev": int(kv.get("mod_revision", 0)) if kv else 0,
        }
