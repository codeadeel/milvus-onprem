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
    listen_port: int = 19500
    lease_ttl_s: int = 15
    keepalive_interval_s: int = 5
    log_level: str = "info"

    @property
    def etcd_endpoint_list(self) -> list[str]:
        """Split the comma-separated `etcd_endpoints` into a list,
        dropping empties and surrounding whitespace."""
        return [e.strip() for e in self.etcd_endpoints.split(",") if e.strip()]
