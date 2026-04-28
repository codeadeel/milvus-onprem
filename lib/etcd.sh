# =============================================================================
# lib/etcd.sh — N-node etcd helpers
#
# With proper Raft quorum (N>=3, odd), etcd handles single-member failures
# automatically: lose one member, surviving floor(N/2)+1 maintain quorum
# and accept writes. NO --force-new-cluster gymnastics like the 2-node case.
#
# Helpers split into health / info / membership / data sections.
#
# Expected to be sourced AFTER lib/role.sh (uses LOCAL_IP, PEERS_ARR,
# CLUSTER_SIZE, ETCD_*_PORT, DATA_ROOT).
# =============================================================================

[[ -n "${_ETCD_SH_LOADED:-}" ]] && return 0
_ETCD_SH_LOADED=1


# -----------------------------------------------------------------------------
# Health checks
# -----------------------------------------------------------------------------

# 0 if local etcd's endpoint health passes (linearizable; requires quorum).
etcd_local_health() {
  docker exec milvus-etcd etcdctl \
    --endpoints="http://127.0.0.1:${ETCD_CLIENT_PORT}" \
    --command-timeout=3s endpoint health >/dev/null 2>&1
}

# Linearizable health probe of a peer's etcd. Requires quorum — fails during
# transitional states (e.g. right after `member add` while peer hasn't joined).
# Usage: etcd_peer_health <ip>
etcd_peer_health() {
  local ip="$1"
  docker exec milvus-etcd etcdctl \
    --endpoints="http://${ip}:${ETCD_CLIENT_PORT}" \
    --command-timeout=3s endpoint health >/dev/null 2>&1
}

# TCP probe of the peer's Raft port (2380). Doesn't need quorum or gRPC
# responsiveness — just that etcd is alive and bound. Use this for pre-flights
# where the cluster may legitimately be in a transitional no-quorum state.
# Usage: etcd_peer_reachable <ip>
etcd_peer_reachable() {
  local ip="$1"
  timeout 3 bash -c "</dev/tcp/${ip}/${ETCD_PEER_PORT}" 2>/dev/null
}

# Count of members currently in "started" state. Outputs the count on stdout.
etcd_count_started() {
  etcd_member_list 2>/dev/null \
    | awk -F',' '{gsub(" ", "", $2); print $2}' \
    | grep -c '^started$' || echo 0
}

# 0 if cluster has Raft quorum (>= floor(CLUSTER_SIZE/2)+1 started members).
etcd_quorum_ok() {
  local started_count
  started_count=$(etcd_count_started)
  local quorum=$(( CLUSTER_SIZE / 2 + 1 ))
  (( started_count >= quorum ))
}


# -----------------------------------------------------------------------------
# Cluster info
# -----------------------------------------------------------------------------

# Print the raw member list (one member per line, comma-separated fields).
# Format: <id>, <status>, <name>, <peer-url>, <client-url>, <is-learner>
etcd_member_list() {
  docker exec milvus-etcd etcdctl \
    --endpoints="http://127.0.0.1:${ETCD_CLIENT_PORT}" \
    --command-timeout=5s member list
}

# Print the etcd ID (hex) of the member matching the given name.
# Usage: etcd_member_id_by_name <node-name>     # e.g. etcd_member_id_by_name node-2
etcd_member_id_by_name() {
  local name="$1"
  etcd_member_list | awk -v n="$name" -F',' '{
    gsub(" ", "", $1); gsub(" ", "", $3);
    if ($3 == n) { print $1; exit }
  }'
}


# -----------------------------------------------------------------------------
# Membership operations (scale-out / rejoin)
# -----------------------------------------------------------------------------

# Announce a new member to the cluster. Required BEFORE that member's etcd
# starts with --initial-cluster-state=existing — otherwise etcd refuses to
# accept its handshake.
# Idempotent: skips if a member with the same name already exists.
# Usage: etcd_add_member <name> <peer-url>
etcd_add_member() {
  local name="$1" peer_url="$2"
  if etcd_member_list 2>/dev/null | awk -F',' -v n="$name" '
       {gsub(" ", "", $3); if ($3 == n) found=1}
       END {exit !found}'; then
    info "etcd: member '$name' already in list — skipping"
    return 0
  fi
  info "etcd: adding member '$name' at $peer_url"
  docker exec milvus-etcd etcdctl \
    --endpoints="http://127.0.0.1:${ETCD_CLIENT_PORT}" \
    member add "$name" --peer-urls="$peer_url"
}

# Remove a member by ID. Returns non-zero if member doesn't exist.
# Usage: etcd_remove_member <member-id>
etcd_remove_member() {
  local id="$1"
  info "etcd: removing member $id"
  docker exec milvus-etcd etcdctl \
    --endpoints="http://127.0.0.1:${ETCD_CLIENT_PORT}" \
    member remove "$id"
}


# -----------------------------------------------------------------------------
# Data operations
# -----------------------------------------------------------------------------

# Wipe ${DATA_ROOT}/etcd on this node. Required before rejoining a cluster
# whose state has diverged from this node's stale data. Caller MUST stop the
# etcd container first (etcd holds a lock on the data dir while running).
etcd_wipe_local_data() {
  warn "wiping ${DATA_ROOT}/etcd on this node (rejoin requires a clean dir)"
  sudo rm -rf "${DATA_ROOT}/etcd/"*
  sudo mkdir -p "${DATA_ROOT}/etcd"
  sudo chown -R 1000:1000 "${DATA_ROOT}/etcd"
}

# Snapshot the local etcd store to a file. Cheap insurance — take one
# before any risky operation.
# Usage: etcd_backup [destination-path]    # default /tmp/etcd-snapshot-<ts>.db
etcd_backup() {
  local dst="${1:-/tmp/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db}"
  # Per-call unique snapshot path — concurrent backup-etcd runs (e.g.
  # operator script + daemon-side job) used to race on a shared
  # /etcd-data/snapshot.db: etcdctl writes .db.part then renames to .db,
  # but if two callers share the names, one's rename fails with "no such
  # file or directory". Suffix the temp name with a random token so each
  # call has its own pair of files.
  local tag; tag="$(date +%s)-$$-$RANDOM"
  local container_path="/etcd-data/snapshot-${tag}.db"
  info "etcd: snapshot → $dst"
  docker exec milvus-etcd etcdctl \
    --endpoints="http://127.0.0.1:${ETCD_CLIENT_PORT}" \
    snapshot save "$container_path"
  docker cp "milvus-etcd:${container_path}" "$dst"
  # Clean up via the bind mount, not `docker exec rm`: the official etcd
  # image is distroless and has no `rm` binary, so an in-container delete
  # fails with "exec: \"rm\": executable file not found in $PATH" and
  # `set -e` kills this function before `ok`/`echo "$dst"` can run.
  # /etcd-data inside the container is just ${DATA_ROOT}/etcd on the host.
  sudo rm -f "${DATA_ROOT}/etcd/snapshot-${tag}.db" \
             "${DATA_ROOT}/etcd/snapshot-${tag}.db.part"
  ok "saved to $dst"
  echo "$dst"
}
