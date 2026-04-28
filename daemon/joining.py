"""Leader-side logic for `POST /join` — adding a new peer to the cluster.

When a new VM runs `./milvus-onprem join <leader-ip>:19500 <token>`, its
HTTP request lands on whichever daemon receives it. Followers 307-
redirect to the current leader; the leader serialises join handling
under an asyncio lock and orchestrates:

  1. Validate the joiner isn't already a peer.
  2. Allocate the next `node-N` name (atomic via etcd transaction
     semantics — we count existing topology entries, then write the
     new one with `put_if_absent` to detect concurrent allocations).
  3. Ask etcd to add the peer to its Raft membership.
  4. Persist the topology entry under /cluster/topology/peers/<name>.
  5. Build a cluster.env tailored for the joiner: shared values from
     this leader's local cluster.env, with NODE_NAME, LOCAL_IP, and
     PEER_IPS substituted for the new peer.

Returns a `JoinResult` the API layer serialises into JSON. Joiner-side
code (cmd_join.sh) writes the cluster.env contents verbatim, runs
host_prep + render + bootstrap, and the joiner's etcd starts with
state=existing because cluster.env carries that flag.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .config import DaemonConfig
from .etcd_client import EtcdClient
from .topology import TOPOLOGY_PREFIX

log = logging.getLogger("daemon.joining")

# Bind-mount target inside the daemon container — the leader reads
# cluster.env from here when building the joiner's copy.
CLUSTER_ENV_PATH = Path("/etc/milvus-onprem/cluster.env")

# Single async lock — one /join handled at a time per leader to avoid
# racing on node-name allocation or partial etcd member state.
_join_lock = asyncio.Lock()

# Keys we strip from the leader's cluster.env when copying values to a
# joiner — these are per-peer values that we re-set explicitly. The
# joiner's cmd_join.sh sets HOST_REPO_ROOT to its own host path; the
# leader's value would be wrong (or accidentally identical, which is
# brittle to depend on).
_PER_PEER_KEYS = frozenset({
    "PEER_IPS",
    "NODE_NAME",
    "LOCAL_IP",
    "ETCD_INITIAL_CLUSTER_STATE",
    "HOST_REPO_ROOT",
})


@dataclass(frozen=True)
class JoinResult:
    """The leader's response to a successful /join request."""

    node_name: str
    local_ip: str
    cluster_env: str
    leader_ip: str


class JoinError(Exception):
    """Raised when /join can't proceed (bad input, conflict, etcd failure).

    The HTTP layer turns this into a 4xx with a useful message.
    """


async def handle_join(
    etcd: EtcdClient,
    config: DaemonConfig,
    joiner_ip: str,
    joiner_hostname: str | None = None,
) -> JoinResult:
    """Top-level entry point. Holds the join lock for the whole flow."""
    if not _is_valid_ipv4(joiner_ip):
        raise JoinError(f"invalid joiner IP: {joiner_ip!r}")

    async with _join_lock:
        return await _do_join(etcd, config, joiner_ip, joiner_hostname)


async def _do_join(
    etcd: EtcdClient,
    config: DaemonConfig,
    joiner_ip: str,
    joiner_hostname: str | None,
) -> JoinResult:
    """The serialised happy-path. Each step writes etcd state forward
    so a leader-failover mid-join can pick up where we left off."""
    existing = await etcd.get_prefix(TOPOLOGY_PREFIX)
    parsed: dict[str, dict[str, Any]] = {}
    for k, v in existing.items():
        name = k.removeprefix(TOPOLOGY_PREFIX)
        try:
            parsed[name] = json.loads(v)
        except json.JSONDecodeError:
            log.warning("ignoring malformed topology entry %s", name)

    # Idempotent re-join by IP. If this IP is already in topology, return
    # the existing allocation rather than erroring — supports the
    # operator's `./milvus-onprem join … --resume` UX after an
    # SSH-dropped or otherwise interrupted first join. The leader still
    # had us in etcd + topology, so we rebuild a fresh cluster_env body
    # from current state (peer list may have changed since last call)
    # and return it. Skips member-add (already a member) and the
    # topology PUT (already written).
    for name, info in parsed.items():
        if info.get("ip") == joiner_ip:
            log.info(
                "idempotent re-join: %s already registered as %s; "
                "returning fresh cluster_env without re-adding to etcd",
                joiner_ip, name,
            )
            existing_peer_ips = _ordered_peer_ips_after_join(
                {k: v for k, v in parsed.items() if k != name},
                name,
                joiner_ip,
            )
            cluster_env_text = _build_joiner_cluster_env(
                leader_env=_read_cluster_env(),
                node_name=name,
                local_ip=joiner_ip,
                all_peer_ips=existing_peer_ips,
            )
            return JoinResult(
                node_name=name,
                local_ip=joiner_ip,
                cluster_env=cluster_env_text,
                leader_ip=config.local_ip,
            )

    new_name = _allocate_next_name(parsed.keys())
    log.info("allocating %s for joiner %s", new_name, joiner_ip)

    # Order matters here: etcd member-add transiently breaks quorum on a
    # 1->2 grow (the new member can't vote yet, leaving 1-of-2). So we
    # do every etcd write that needs quorum FIRST, then call member-add
    # LAST and never touch etcd again from this handler — the joiner
    # bringing up its own etcd is what restores quorum.

    # 1. Persist topology entry while we still have quorum.
    info_value = json.dumps(
        {
            "name": new_name,
            "ip": joiner_ip,
            "hostname": joiner_hostname,
            "joined_at": time.time(),
            "role": "peer",
        }
    )
    written = await etcd.put_if_absent(
        TOPOLOGY_PREFIX + new_name, info_value
    )
    if not written:
        # Concurrent allocation race — defensive log only; the lock
        # should prevent this in practice.
        log.warning("topology entry for %s already exists at write time", new_name)

    # 2. Compute the post-add peer list locally so we can build the
    # joiner's cluster.env without needing another etcd call after
    # member-add. We know exactly what the membership will look like.
    all_peer_ips = _ordered_peer_ips_after_join(parsed, new_name, joiner_ip)
    cluster_env_text = _build_joiner_cluster_env(
        leader_env=_read_cluster_env(),
        node_name=new_name,
        local_ip=joiner_ip,
        all_peer_ips=all_peer_ips,
    )

    # 3. etcd member-add. Quorum drops here on a 1->2 grow until the
    # joiner's etcd contacts the cluster; that's expected. Failure
    # rolls back the topology entry so the next /join retry doesn't
    # see a half-registered peer.
    peer_url = f"http://{joiner_ip}:{config.etcd_peer_port}"
    try:
        await etcd.member_add([peer_url])
    except Exception as e:
        log.warning(
            "etcd member-add failed for %s; rolling back topology entry",
            new_name,
        )
        try:
            await etcd.delete(TOPOLOGY_PREFIX + new_name)
        except Exception as cleanup_err:
            log.warning("rollback delete also failed: %s", cleanup_err)
        raise JoinError(f"etcd member-add failed: {e}") from e

    log.info("join complete: %s @ %s now in cluster", new_name, joiner_ip)
    return JoinResult(
        node_name=new_name,
        local_ip=joiner_ip,
        cluster_env=cluster_env_text,
        leader_ip=config.local_ip,
    )


# ── helpers ──────────────────────────────────────────────────────────


def _is_valid_ipv4(ip: str) -> bool:
    """Loose IPv4 sanity check — catches obvious typos, doesn't validate
    the host actually exists."""
    if not re.match(r"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$", ip):
        return False
    return all(0 <= int(part) <= 255 for part in ip.split("."))


def _allocate_next_name(existing_names) -> str:
    """Pick the smallest unused `node-N` integer suffix.

    We don't just count — peers can be removed later and we want to
    reuse the gap, so the names stay short and predictable.
    """
    used = set()
    for name in existing_names:
        m = re.match(r"^node-(\d+)$", name)
        if m:
            used.add(int(m.group(1)))
    n = 1
    while n in used:
        n += 1
    return f"node-{n}"


def _read_cluster_env() -> dict[str, str]:
    """Parse the bind-mounted cluster.env into a {key: value} dict.

    Trims `KEY=VALUE` lines, ignores comments, strips surrounding quotes.
    Lines with malformed syntax are silently skipped — cluster.env is
    operator-managed, so we err on lenient.
    """
    if not CLUSTER_ENV_PATH.exists():
        raise JoinError(
            f"daemon can't read {CLUSTER_ENV_PATH}; check the bind mount in compose"
        )
    out: dict[str, str] = {}
    for line in CLUSTER_ENV_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        v = v.strip().strip('"').strip("'")
        if k:
            out[k] = v
    return out


def _ordered_peer_ips_after_join(
    existing_topology: dict[str, dict[str, Any]],
    new_name: str,
    joiner_ip: str,
) -> list[str]:
    """Compute the post-join PEER_IPS list, sorted by node-N suffix.

    Replaces the older "read etcd's member-add response" path because
    we now build cluster.env BEFORE calling member-add (to avoid the
    etcd-quorum window). The topology mirror plus the just-allocated
    name + joiner IP is enough to know the final ordering.
    """
    combined: dict[str, str] = {}
    for name, info in existing_topology.items():
        ip = info.get("ip", "")
        if ip:
            combined[name] = ip
    combined[new_name] = joiner_ip

    return [combined[name] for name in sorted(combined, key=_node_sort_key)]


def _node_sort_key(name: str) -> tuple[int, str]:
    """Order `node-1, node-2, ..., node-10` correctly (numeric suffix)."""
    m = re.match(r"^node-(\d+)$", name)
    return (int(m.group(1)), name) if m else (10**9, name)


def _build_joiner_cluster_env(
    leader_env: dict[str, str],
    node_name: str,
    local_ip: str,
    all_peer_ips: list[str],
) -> str:
    """Render the joiner's cluster.env file content.

    Copies the shared values from the leader's cluster.env, overrides
    the per-peer fields, and forces ETCD_INITIAL_CLUSTER_STATE=existing
    so the joiner's etcd joins the running Raft instead of trying to
    bootstrap a fresh cluster.
    """
    lines: list[str] = []
    lines.append("# =============================================================================")
    lines.append("# milvus-onprem cluster.env (joiner copy)")
    lines.append(f"# Issued by leader at {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
    lines.append("# =============================================================================")
    lines.append("")
    lines.append(f"NODE_NAME={node_name}")
    lines.append(f"LOCAL_IP={local_ip}")
    lines.append(f"PEER_IPS={','.join(all_peer_ips)}")
    lines.append("ETCD_INITIAL_CLUSTER_STATE=existing")
    lines.append("")

    # Pass shared keys through verbatim. Keep cluster.env's section
    # ordering reasonable but not identical — joiner re-renders it as
    # needed anyway.
    for k, v in leader_env.items():
        if k in _PER_PEER_KEYS:
            continue
        lines.append(f"{k}={v}")
    lines.append("")
    return "\n".join(lines)
