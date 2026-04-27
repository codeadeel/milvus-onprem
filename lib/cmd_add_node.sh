# =============================================================================
# lib/cmd_add_node.sh — orchestrator-side scale-out: add an Nth node
#
# Run on any healthy peer of an existing cluster. Does the parts that
# can be safely automated:
#
#   1. etcd member-add for the new IP (etcd Raft handles online member
#      changes correctly — surviving peers learn via gossip)
#   2. update *this node's* cluster.env: PEER_IPS += <new-ip>
#   3. re-render templates locally
#   4. reload nginx (`nginx -s reload`) so its upstream list picks up
#      the new peer
#
# What it deliberately does NOT do:
#
#   - Touch MinIO. Distributed MinIO takes its server list at startup;
#     growing the pool requires either a coordinated rolling restart of
#     every existing MinIO with the new list, or `mc admin pool add` for
#     a separate-pool expansion. Both are operator-coordinated and out
#     of scope for the MVP.
#   - Update cluster.env on the *other* existing peers. That's what
#     `milvus-onprem update-peers` is for, run once on each.
#   - Run pair / serve cluster.env to the new node. Operator runs
#     `pair` afterwards as usual; the new node uses
#     `milvus-onprem join <orchestrator-ip>:<port> <token> --existing`.
#
# After add-node returns, the operator instruction set is printed.
# `--dry-run` prints what *would* happen without doing anything.
# =============================================================================

[[ -n "${_CMD_ADD_NODE_SH_LOADED:-}" ]] && return 0
_CMD_ADD_NODE_SH_LOADED=1

cmd_add_node() {
  local new_ip="" new_name="" dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --new-ip=*)   new_ip="${1#*=}";   shift ;;
      --new-ip)     new_ip="$2";        shift 2 ;;
      --new-name=*) new_name="${1#*=}"; shift ;;
      --new-name)   new_name="$2";      shift 2 ;;
      --dry-run)    dry_run=1;          shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem add-node --new-ip=<ip> [--new-name=<name>] [--dry-run]

Add a new peer to a running cluster. Run on any healthy existing
peer. Performs etcd member-add for the new IP, updates this node's
cluster.env, re-renders local templates, and reloads nginx.

  --new-ip=IP        (required) IP address of the new peer.
  --new-name=NAME    Override etcd member name. Default: node-<N+1>.
  --dry-run          Print planned actions without executing.

After this command, the operator's remaining steps are printed (and
need to be done in this order):

  1. On every other existing peer: \`milvus-onprem update-peers\`.
  2. MinIO rolling restart on every existing peer (manual).
  3. On this node: \`milvus-onprem pair\` (re-uses existing pair).
  4. On the new VM: \`milvus-onprem join <ip>:<port> <token> --existing\`.

See docs/OPERATIONS.md ("Scale-out") for the full procedure.
EOF
        return 0 ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  [[ -n "$new_ip" ]] || die "--new-ip is required"
  [[ "$new_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "--new-ip=$new_ip doesn't look like an IPv4 address"

  env_require
  role_detect
  role_validate_size

  # Pre-flight: cluster must be healthy enough to accept member-add.
  # Need quorum (ceil(N/2)) of existing peers reachable on etcd.
  _add_node_check_etcd_quorum

  # Refuse if new-ip already in PEER_IPS — that's not "adding", that's
  # "operator confused" or "node lost contact and is being re-added"
  # which is a different recovery flow (TROUBLESHOOTING permanently-lost).
  local current_ips="$PEER_IPS"
  for existing in ${current_ips//,/ }; do
    [[ "$existing" == "$new_ip" ]] \
      && die "$new_ip is already in PEER_IPS. To recover a node that lost its data, see docs/TROUBLESHOOTING.md \"Replacing a permanently-lost node\""
  done

  # Default name = node-<next-index>. Index is 1-based.
  local old_size="$CLUSTER_SIZE"
  local new_size=$((CLUSTER_SIZE + 1))
  [[ -n "$new_name" ]] || new_name="node-$new_size"

  local new_peer_ips="${current_ips},${new_ip}"

  info "==> add-node plan"
  info "    cluster:       $CLUSTER_NAME (size $old_size -> $new_size)"
  info "    new node:      $new_name @ $new_ip"
  info "    orchestrator:  $NODE_NAME ($LOCAL_IP)"
  info "    new PEER_IPS:  $new_peer_ips"
  if (( dry_run )); then
    warn "--dry-run set; no actions will be performed"
  fi

  # Step 1: etcd member-add. This is the only step that affects cluster
  # state globally; everything after it is local re-render + reload.
  info "==> Step 1: etcd member-add for $new_name @ $new_ip:${ETCD_PEER_PORT}"
  if (( dry_run )); then
    info "    would run: docker exec milvus-etcd etcdctl --endpoints=http://127.0.0.1:${ETCD_CLIENT_PORT} \\"
    info "                 member add $new_name --peer-urls=http://${new_ip}:${ETCD_PEER_PORT}"
  else
    local out
    if ! out="$(docker exec milvus-etcd etcdctl --endpoints="http://127.0.0.1:${ETCD_CLIENT_PORT}" \
                 member add "$new_name" --peer-urls="http://${new_ip}:${ETCD_PEER_PORT}" 2>&1)"; then
      die "etcd member-add failed:\n$out"
    fi
    ok "etcd member added"
    echo "$out" | sed 's/^/    /'
  fi

  # Step 2: local cluster.env update (PEER_IPS).
  info "==> Step 2: update local cluster.env (PEER_IPS)"
  if (( dry_run )); then
    info "    would write: PEER_IPS=$new_peer_ips"
  else
    sed -i.bak "s|^PEER_IPS=.*|PEER_IPS=$new_peer_ips|" "$CLUSTER_ENV"
    ok "cluster.env updated (backup: ${CLUSTER_ENV}.bak)"
  fi

  # Step 3: re-render templates so milvus.yaml/nginx.conf/docker-compose
  # see the new peer.
  info "==> Step 3: re-render local templates"
  if (( dry_run )); then
    info "    would run: milvus-onprem render"
  else
    # Re-load: cluster.env on disk is updated, but the PEERS_ARR /
    # CLUSTER_SIZE / PEER_NAMES that role_detect populated at the top
    # of this command are stale. Re-source the env file and re-run
    # role_detect so the in-memory state matches disk before we render.
    # shellcheck disable=SC1090
    source "$CLUSTER_ENV"
    role_detect
    render_all
    ok "rendered"
  fi

  # Step 4: reload nginx so its upstream list picks up the new peer.
  # A reload is non-disruptive — existing connections drain on the old
  # config, new connections see the new upstreams.
  info "==> Step 4: reload nginx"
  if (( dry_run )); then
    info "    would run: docker exec milvus-nginx nginx -s reload"
  else
    if docker exec milvus-nginx nginx -s reload 2>&1; then
      ok "nginx reloaded"
    else
      warn "nginx reload failed — fall back to: docker compose -f rendered/${NODE_NAME}/docker-compose.yml up -d --force-recreate nginx"
    fi
  fi

  echo
  ok "orchestrator side complete"
  echo
  info "==> next steps for the operator (run in order):"
  cat <<EOF

  1. On every OTHER existing peer (not this one), run:
       milvus-onprem update-peers --peer-ips=${new_peer_ips}

  2. (Optional but recommended) Coordinate a MinIO server-list update.
     Distributed MinIO takes its server list at startup, so growing
     the pool requires every existing MinIO to restart with the new
     ${new_size}-server list. Stop/start MinIO on each peer one at a
     time, OR plan a brief MinIO outage. See:
       docs/OPERATIONS.md "Scale-out — MinIO consideration"

  3. On THIS node, run \`milvus-onprem pair\` to serve the updated
     cluster.env to the new node:
       milvus-onprem pair

  4. On the NEW VM (${new_name} @ ${new_ip}), run:
       milvus-onprem join ${LOCAL_IP}:${PAIR_PORT} <token> --existing

EOF
}

# Verify the local etcd considers the cluster healthy enough to accept
# a member-add. etcdctl member-add will refuse below quorum anyway, but
# checking up front gives us a friendlier error.
_add_node_check_etcd_quorum() {
  local out
  if ! out="$(docker exec milvus-etcd etcdctl --endpoints="http://127.0.0.1:${ETCD_CLIENT_PORT}" \
               endpoint health --cluster 2>&1)"; then
    die "local etcd reports unhealthy cluster — refusing to attempt member-add. Check \`milvus-onprem status\` first."
  fi
  if echo "$out" | grep -q "is unhealthy"; then
    warn "etcd reports some unhealthy members:"
    echo "$out" | sed 's/^/    /'
    warn "proceeding anyway — etcd member-add only needs quorum, not full health"
  fi
}
