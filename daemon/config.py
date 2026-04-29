"""Daemon config — env vars set by docker-compose at render time.

Single source. No fallback to cluster.env (the daemon doesn't read it
directly; render translates cluster.env into the env vars below before
the container starts).
"""

from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class DaemonConfig(BaseSettings):
    """All daemon settings, loaded from `MILVUS_ONPREM_*` environment
    variables at startup. Pydantic validates types and presence of the
    required fields; missing required vars cause an immediate fail-fast
    on container start, which is what we want."""

    model_config = SettingsConfigDict(
        env_prefix="MILVUS_ONPREM_",
        case_sensitive=False,
        extra="ignore",
    )

    cluster_name: str = Field(..., description="Logical cluster ID.")
    node_name: str = Field(..., description="This peer's stable name, e.g. 'node-1'.")
    local_ip: str = Field(..., description="This peer's IP, used in leader-info value.")
    cluster_token: str = Field(..., description="Shared bearer token for HTTP auth.")
    etcd_endpoints: str = Field(
        ...,
        description="Comma-separated etcd HTTP endpoints, e.g. http://10.0.0.2:2379.",
    )
    etcd_peer_port: int = Field(
        default=2380,
        description=(
            "etcd Raft peer port. Used by /join to compute the joiner's "
            "peerURL when calling member-add."
        ),
    )
    listen_port: int = 19500
    lease_ttl_s: int = 15
    keepalive_interval_s: int = 5
    log_level: str = "info"

    # Watchdog (stage 12) — see daemon/watchdog.py.
    watchdog_mode: str = Field(
        default="auto",
        description="auto = auto-restart local unhealthy containers; monitor = alerts only.",
    )
    watchdog_interval_s: int = Field(
        default=10,
        description="Seconds between watchdog ticks (local + peer probes).",
    )
    watchdog_unhealthy_threshold: int = Field(
        default=3,
        description="Consecutive unhealthy ticks before auto-restart fires.",
    )
    watchdog_peer_failure_threshold: int = Field(
        default=6,
        description="Consecutive peer-probe failures before PEER_DOWN_ALERT fires.",
    )
    watchdog_restart_loop_window_s: int = Field(
        default=300,
        description="Window (s) within which N restarts trip the loop guard.",
    )
    watchdog_restart_loop_max: int = Field(
        default=3,
        description="Max auto-restarts per container in the loop-window.",
    )

    # Job retention.
    jobs_retention_s: int = Field(
        default=30 * 24 * 3600,
        description=(
            "Age beyond which terminated jobs (done/failed/cancelled) are "
            "deleted from etcd. Default 30 days. Running/pending jobs are "
            "never pruned regardless of age."
        ),
    )
    jobs_prune_interval_s: int = Field(
        default=3600,
        description="Seconds between leader-side retention sweeps. Default 1h.",
    )
    jobs_heartbeat_timeout_s: int = Field(
        default=60,
        description=(
            "If a `running` job's owner heartbeat is older than this, the "
            "leader's stuck-job sweep marks it `failed`. Heartbeats are "
            "written every ~2s by the owner's periodic flusher; default "
            "60s = ~30 flush cycles missed. Lift if your jobs hold the "
            "GIL through long blocking calls."
        ),
    )
    jobs_stuck_sweep_interval_s: int = Field(
        default=30,
        description=(
            "Seconds between leader-side stuck-running sweeps. Faster than "
            "the retention sweep so a stuck job becomes visible to the "
            "operator within ~1 sweep + heartbeat_timeout."
        ),
    )

    rolling_minio_peer_rpc_timeout_s: float = Field(
        default=180.0,
        description=(
            "Per-peer RPC timeout for /recreate-minio-self during a "
            "leader-driven rolling MinIO sweep. Lift on slow disks."
        ),
    )
    rolling_minio_healthy_wait_s: int = Field(
        default=90,
        description=(
            "Maximum seconds to wait for a recreated MinIO container "
            "to report healthy before the rolling sweep moves on."
        ),
    )

    @property
    def etcd_endpoint_list(self) -> list[str]:
        """Split the comma-separated `etcd_endpoints` into a list,
        dropping empties and surrounding whitespace."""
        return [e.strip() for e in self.etcd_endpoints.split(",") if e.strip()]
