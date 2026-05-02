# =============================================================================
# lib/cmd_bootstrap.sh — full deploy: render + up + wait + bucket create
#
# Idempotent — safe to re-run. Designed to be the single command operators
# run after `init` (and after distributing cluster.env to all peers via
# pair/join, when running multi-node).
#
# Stages:
#   1. render templates for this node
#   2. start etcd container
#   3. start MinIO container
#   3a. start Pulsar broker      (Milvus 2.5 only, on PULSAR_HOST)
#   4. start Milvus
#   5. start nginx LB
#   6. wait for full cluster convergence (only if not standalone)
#   7. create the milvus-bucket if it doesn't exist
#
# The Pulsar sub-stage is a no-op for 2.6 (Woodpecker is embedded) and
# for non-PULSAR_HOST peers in a 2.5 cluster (they connect across the
# network to the singleton).
# =============================================================================

[[ -n "${_CMD_BOOTSTRAP_SH_LOADED:-}" ]] && return 0
_CMD_BOOTSTRAP_SH_LOADED=1

cmd_bootstrap() {
  env_require
  role_detect
  role_validate_size

  info "==> bootstrap on $NODE_NAME (cluster=$CLUSTER_NAME, size=$CLUSTER_SIZE)"

  # Re-prep host dirs. After `teardown --data` (or `--full`) wipes
  # /data/{etcd,minio,milvus,pulsar}, docker bind-mounts re-create the
  # paths as root:root on next container start, which makes the
  # UID-1000 etcd/minio and UID-10000 pulsar containers crash with
  # AccessDenied. host_prep is idempotent — safe on a clean cluster too.
  host_prep "$DATA_ROOT" "${MODE:-standalone}"

  # --- Stage 1: render --------------------------------------------------
  info "==> Stage 1/7: render templates"
  render_all

  # --- Stage 2: start etcd ----------------------------------------------
  info "==> Stage 2/7: start etcd"
  dc up -d etcd
  _wait_for "local etcd" 60 etcd_local_health \
    || warn "etcd not healthy locally — may still be forming quorum (normal until all peers up)"

  # --- Stage 3: start MinIO ---------------------------------------------
  info "==> Stage 3/7: start MinIO"
  dc up -d minio

  # In distributed mode, MinIO needs all peers reachable to form a cluster.
  # In standalone mode, it's healthy immediately. Both waits below are
  # `|| warn`-guarded: under multi-node `pair`/`join` the peer-side
  # bootstrap reaches Stage 3 before the bootstrap-node's own MinIO is
  # up, so a missed deadline is normal — bootstrap is idempotent and
  # downstream stages catch up on the next run.
  if role_is_standalone; then
    _wait_for "local MinIO" 60 minio_local_healthy \
      || warn "local MinIO not healthy yet — re-run bootstrap once it is"
  else
    info "  distributed MinIO — waiting for all peers to reach :${MINIO_API_PORT}"
    _wait_peers_minio_reachable 120 \
      || warn "not all peers reachable on :${MINIO_API_PORT} yet — proceeding; re-run bootstrap once they are"
    _wait_for "MinIO cluster health" 120 minio_cluster_healthy \
      || warn "MinIO cluster not yet healthy — may need more peers up"
  fi

  # --- Stage 3a: start Pulsar (2.5 only, on PULSAR_HOST) ----------------
  # Milvus 2.5 needs Pulsar reachable before its coordinators come up;
  # otherwise rootcoord/datacoord loop on "find no available rootcoord"
  # and the container never reports healthy. Pulsar is a singleton on
  # PULSAR_HOST, so only that one node actually starts it; other peers
  # in a multi-node 2.5 cluster connect across the network.
  if [[ "${MQ_TYPE:-}" == "pulsar" && "$NODE_NAME" == "${PULSAR_HOST:-node-1}" ]]; then
    info "==> Stage 3a/7: start Pulsar (singleton on $NODE_NAME)"
    dc up -d pulsar
    # Pulsar's own healthcheck has a 90s start_period; the broker port
    # usually accepts TCP within ~30-60s. We just need it reachable
    # before Milvus's coordinators try to dial it.
    _wait_for "Pulsar broker @${PULSAR_HOST_IP:-127.0.0.1}:${PULSAR_BROKER_PORT}" 180 \
              _pulsar_broker_reachable \
      || warn "Pulsar not reachable yet — Milvus may need a few restarts to catch up"
  fi

  # --- Stage 4: start Milvus + nginx ------------------------------------
  # Service set varies by (MILVUS_VERSION, MODE):
  #   2.5 (any mode):           cluster mode — mixcoord + proxy + querynode + datanode + indexnode
  #   2.6 standalone:           single `milvus run standalone`
  #   2.6 distributed:          cluster mode + streamingnode (woodpecker WAL)
  info "==> Stage 4/7: start Milvus"
  if [[ "$MILVUS_VERSION" == "2.5" ]]; then
    dc up -d mixcoord proxy querynode datanode indexnode
  elif [[ "${MODE:-standalone}" == "distributed" ]]; then
    # 2.6 dropped the separate indexnode server type — index-build runs
    # inside datanode now. cluster mode = mixcoord + 3 workers + streamingnode.
    dc up -d mixcoord proxy querynode datanode streamingnode
  else
    dc up -d milvus
  fi

  info "==> Stage 5/7: start nginx LB"
  dc up -d nginx

  # --- Stage 5a: control-plane daemon (distributed mode only) -----------
  # The daemon container is included in the rendered compose only when
  # MODE=distributed. It depends on etcd (already up) and runs the
  # leader election + topology watch + HTTP API. Standalone deploys
  # don't have a daemon at all, so this stage is a no-op for them.
  if [[ "${MODE:-standalone}" == "distributed" ]]; then
    info "==> Stage 5a/7: start control-plane daemon"
    dc up -d control-plane
    _wait_for "control-plane @127.0.0.1:${CONTROL_PLANE_PORT:-19500}" 60 \
      _control_plane_local_health \
      || warn "control plane not healthy yet — \`docker logs milvus-onprem-cp\` for details"
  fi

  # --- Stage 6: convergence ---------------------------------------------
  if role_is_standalone; then
    info "==> Stage 6/7: standalone — skipping cluster-wide convergence wait"
  else
    info "==> Stage 6/7: wait for cluster-wide convergence"
    if ! cmd_wait --timeout-s=300; then
      warn "cluster did not fully converge in 5 min — check \`milvus-onprem status\` on each peer"
      warn "if peers haven't been bootstrapped yet, that's expected — re-run bootstrap once they are"
    fi
  fi

  # --- Stage 7: create the bucket Milvus expects ------------------------
  # On a JOINER in distributed mode, the bucket was already created by
  # the leader at init time; the leader's MinIO pool replicates to
  # every peer so the bucket is visible cluster-wide. Trying to create
  # it here is racy — a joiner's local MinIO can be in a transient
  # "Expected N endpoints, seen M" state during the leader's rolling
  # recreate (which only finishes AFTER the joiner's bootstrap has
  # already moved past this stage), and `mc` commands against a
  # not-yet-quorate local MinIO time out / fail. Skip the ensure on
  # joiners; only the very first peer (init) creates the bucket.
  #
  # Wide-pool init (--ha-cluster-size=N): MinIO can't reach pool
  # quorum until at least one other peer joins, so bucket creation
  # is deferred. The leader's daemon retries the ensure after every
  # rolling-recreate (cf. handlers.recreate_minio_local), so the
  # bucket appears automatically once joins bring the wide pool to
  # quorum — no operator action needed beyond running `join` from
  # each remaining peer.
  info "==> Stage 7/7: ensure milvus-bucket exists in MinIO"
  local ha_size="${MINIO_HA_POOL_SIZE:-0}"
  [[ "$ha_size" =~ ^[0-9]+$ ]] || ha_size=0
  if [[ "${MODE:-standalone}" == "distributed" \
        && "${ETCD_INITIAL_CLUSTER_STATE:-new}" == "existing" ]]; then
    info "(joiner: bucket already exists in cluster MinIO from init; skipping)"
  elif (( ha_size >= 2 )) && (( CLUSTER_SIZE < ha_size )); then
    warn "wide MinIO pool (--ha-cluster-size=$ha_size) needs $ha_size peers to reach quorum; have $CLUSTER_SIZE"
    info "bucket creation deferred — run \`./milvus-onprem join\` from each remaining peer; the daemon ensures the bucket automatically once quorum forms"
  elif minio_local_healthy; then
    minio_create_milvus_bucket
  else
    warn "local MinIO not healthy yet — bucket creation skipped; re-run bootstrap once cluster forms"
  fi

  ok "bootstrap complete on $NODE_NAME"
  info "verify with: milvus-onprem status"
  info "exercise with: milvus-onprem smoke   (once tests/ phase is in place)"
}

# Probe the local control-plane daemon's /health endpoint. Used by the
# Stage 5a wait-loop to confirm the daemon came up cleanly.
_control_plane_local_health() {
  curl -fsS -m 2 "http://127.0.0.1:${CONTROL_PLANE_PORT:-19500}/health" >/dev/null
}

# Wait up to <secs> seconds for <fn> to return 0. Prints OK/FAIL.
# Usage: _wait_for <label> <secs> <fn> [args...]
_wait_for() {
  local label="$1" timeout="$2"; shift 2
  local i
  for ((i=0; i<timeout; i++)); do
    if "$@" >/dev/null 2>&1; then
      ok "$label OK"
      return 0
    fi
    sleep 1
  done
  warn "$label not ready after ${timeout}s"
  return 1
}

_wait_peers_minio_reachable() {
  local timeout="$1" i ip start
  start=$(date +%s)
  while (( $(date +%s) - start < timeout )); do
    local all_up=1
    for ((i=0; i<CLUSTER_SIZE; i++)); do
      ip="${PEERS_ARR[$i]}"
      if ! minio_peer_reachable "$ip"; then
        all_up=0
        break
      fi
    done
    (( all_up )) && return 0
    sleep 2
  done
  return 1
}

# Pulsar broker TCP probe — used during bootstrap to gate Milvus startup
# behind a reachable broker. We probe the resolved PULSAR_HOST_IP rather
# than the literal `pulsar` hostname so it works on host networking.
_pulsar_broker_reachable() {
  local ip="${PULSAR_HOST_IP:-127.0.0.1}"
  timeout 3 bash -c "</dev/tcp/$ip/${PULSAR_BROKER_PORT}" 2>/dev/null
}
