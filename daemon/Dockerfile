# =============================================================================
# milvus-onprem control plane daemon — image build
#
# Build context is this directory (`daemon/`). Build from repo root:
#   docker build -t milvus-onprem-cp:dev daemon/
# Run with the env vars from the rendered compose service.
# =============================================================================

FROM python:3.12-slim AS base

# Slim images don't ship `tini`, but uvicorn handles SIGTERM cleanly so
# we don't need an init shim. We do need curl for the HEALTHCHECK.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps first so the layer caches across source edits.
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# Source goes into /app/daemon/ so `python -m daemon.main` works.
COPY __init__.py /app/daemon/
COPY config.py etcd_client.py leader.py topology.py auth.py api.py main.py /app/daemon/

EXPOSE 19500

# Container-level healthcheck. The /health endpoint is unauthenticated
# by design so we don't need to plumb the cluster token in here.
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS http://127.0.0.1:19500/health || exit 1

ENV PYTHONUNBUFFERED=1
CMD ["python", "-m", "daemon.main"]
