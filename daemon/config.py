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
        # Empty env values fall back to Field defaults instead of failing
        # int/bool parsing. Render emits `MILVUS_ONPREM_MINIO_HA_POOL_SIZE=`
        # when the cluster runs the legacy per-host-pool layout (the
        # cluster.env field is unset); without this, pydantic raises on
        # the empty string.
        env_ignore_empty=True,
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

    # Pulsar-host auto-failover. 2.5 only — Pulsar is the messagebus
    # singleton and its host going down stops the whole cluster's reads
    # AND writes. When this flag is true AND the watchdog detects the
    # current PULSAR_HOST is down (PEER_DOWN_ALERT fired), the leader
    # automatically submits a `migrate-pulsar` job to move Pulsar onto
    # the next eligible surviving peer.
    #
    # DEFAULT FALSE because:
    #   - migrate-pulsar drops in-flight Pulsar messages (writes mid-
    #     flight when Pulsar dies are LOST). Operators must accept this
    #     trade-off explicitly.
    #   - A flapping peer (network blip) could trigger an unnecessary
    #     migrate. We require `auto_migrate_pulsar_threshold` (default
    #     30 = ~5 minutes at the default 10s interval) consecutive misses
    #     before triggering, which is much more conservative than the
    #     PEER_DOWN_ALERT threshold (default 6 = 1 minute).
    auto_migrate_pulsar_on_host_failure: bool = Field(
        default=False,
        description=(
            "If true (and MQ_TYPE=pulsar), the daemon auto-fires "
            "migrate-pulsar when the watchdog detects the current "
            "PULSAR_HOST is persistently down. Default false because "
            "migrate-pulsar drops in-flight messages."
        ),
    )
    auto_migrate_pulsar_threshold: int = Field(
        default=30,
        description=(
            "Consecutive watchdog misses on the PULSAR_HOST peer before "
            "auto-migrate fires. Default 30 = ~5 min at 10s interval. "
            "Much higher than watchdog_peer_failure_threshold so a "
            "transient network blip doesn't drop Pulsar."
        ),
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

    # MinIO knobs the bucket-ensure hook needs. Wide-pool clusters
    # (init --ha-cluster-size=N) defer milvus-bucket creation at init
    # because the pool can't write until joins bring it to quorum.
    # Each peer's daemon re-tries the ensure after every rolling
    # MinIO recreate, so the bucket appears the moment the cluster
    # reaches quorum — no operator action required.
    minio_api_port: int = Field(
        default=9000,
        description="Local MinIO API port. Used to probe cluster-health and run mc.",
    )
    minio_access_key: str = Field(
        default="minioadmin",
        description="MinIO root user. Used by `mc alias set local`.",
    )
    minio_secret_key: str = Field(
        default="",
        description=(
            "MinIO root password. Used by `mc alias set local`. The daemon "
            "needs write credentials only to call `mc mb local/milvus-bucket`."
        ),
    )
    minio_ha_pool_size: int = Field(
        default=0,
        description=(
            "If >= 2, the cluster runs the wide-pool MinIO layout and the "
            "bucket-ensure hook activates after every topology change. "
            "0 = legacy per-host-pool layout, no daemon-side bucket logic."
        ),
    )

    @property
    def etcd_endpoint_list(self) -> list[str]:
        """Split the comma-separated `etcd_endpoints` into a list,
        dropping empties and surrounding whitespace."""
        return [e.strip() for e in self.etcd_endpoints.split(",") if e.strip()]
