# =============================================================================
# milvus-onprem control plane daemon — image build
#
# Build context is this directory (`daemon/`). Build from repo root:
#   docker build -t milvus-onprem-cp:dev daemon/
# Run with the env vars from the rendered compose service.
# =============================================================================

FROM python:3.12-slim AS base

# Slim images don't ship `tini`, but uvicorn handles SIGTERM cleanly so
# we don't need an init shim. Tools we install:
#   curl          /health probe + downloads below
#   bash          stage 5 onwards: daemon shells out to render.sh
#   gettext-base  envsubst (used by render.sh)
#   ca-certificates  for HTTPS curl (download docker / compose)
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      curl bash gettext-base ca-certificates sudo \
 && rm -rf /var/lib/apt/lists/*

# Docker CLI + compose plugin. Both are statically-linked single binaries
# from the official Docker release tarball; we don't run the daemon, just
# talk to the host's via the bind-mounted /var/run/docker.sock.
ARG DOCKER_VERSION=27.5.1
ARG COMPOSE_VERSION=v2.30.3
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
      | tar -xz -C /tmp \
 && mv /tmp/docker/docker /usr/local/bin/docker \
 && rm -rf /tmp/docker \
 && mkdir -p /usr/local/libexec/docker/cli-plugins \
 && curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
      -o /usr/local/libexec/docker/cli-plugins/docker-compose \
 && chmod +x /usr/local/libexec/docker/cli-plugins/docker-compose

WORKDIR /app

# Install Python deps first so the layer caches across source edits.
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# Source goes into /app/daemon/ so `python -m daemon.main` works.
COPY __init__.py /app/daemon/
COPY config.py etcd_client.py leader.py topology.py joining.py handlers.py jobs.py auth.py api.py watchdog.py main.py /app/daemon/
# Workers register handlers at import time; the package layout matches
# the source tree so /app/daemon/workers/__init__.py loads them. Includes
# create_backup, export_backup, restore_backup, backup_etcd, remove_node,
# version_upgrade.
COPY workers/ /app/daemon/workers/

EXPOSE 19500

# Container-level healthcheck. The /health endpoint is unauthenticated
# by design so we don't need to plumb the cluster token in here.
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:19500/health || exit 1

ENV PYTHONUNBUFFERED=1
CMD ["python", "-m", "daemon.main"]
