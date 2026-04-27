# =============================================================================
# lib/cmd_update_peers.sh — propagate a PEER_IPS change to this node
#
# Companion to `add-node`. After the orchestrator peer adds an etcd
# member and updates its own cluster.env, every OTHER existing peer
# runs this command to:
#
#   1. update its local cluster.env with the new PEER_IPS
#   2. re-render templates
#   3. reload nginx so the upstream list picks up the new peer
#
# Like `add-node`, this deliberately does not touch MinIO; that's a
# coordinated rolling restart documented separately.
#
# `--dry-run` prints what would happen without acting.
# =============================================================================

[[ -n "${_CMD_UPDATE_PEERS_SH_LOADED:-}" ]] && return 0
_CMD_UPDATE_PEERS_SH_LOADED=1

cmd_update_peers() {
  local new_ips="" dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --peer-ips=*) new_ips="${1#*=}"; shift ;;
      --peer-ips)   new_ips="$2";      shift 2 ;;
      --dry-run)    dry_run=1;         shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem update-peers --peer-ips=<comma-list> [--dry-run]

Propagate a PEER_IPS change to this peer's cluster.env. Run on every
existing peer (other than the orchestrator) after \`add-node\` has
updated the etcd Raft membership. Re-renders local templates and
reloads nginx so its upstream list picks up the new peer.

  --peer-ips=A,B,C,...   (required) The full new PEER_IPS list,
                         comma-separated, in the same order as
                         orchestrator's cluster.env.
  --dry-run              Print planned actions without executing.

Does NOT touch MinIO. Distributed MinIO requires a coordinated
rolling restart — see docs/OPERATIONS.md "Scale-out".
EOF
        return 0 ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  [[ -n "$new_ips" ]] || die "--peer-ips is required"

  env_require
  role_detect

  # Sanity: this node's IP must still be in the new list. If it isn't,
  # the operator is doing something they probably didn't mean to do
  # (removing this node).
  local found=0
  for ip in ${new_ips//,/ }; do
    [[ "$ip" == "$LOCAL_IP" ]] && found=1
  done
  (( found )) || die "this node's IP ($LOCAL_IP) is not in the new --peer-ips list. Refusing — that would orphan this node from the cluster. To remove a node, see docs/TROUBLESHOOTING.md \"Replacing a permanently-lost node\"."

  if [[ "$PEER_IPS" == "$new_ips" ]]; then
    info "PEER_IPS already matches — nothing to do"
    return 0
  fi

  local new_size
  new_size="$(echo "$new_ips" | tr ',' '\n' | wc -l)"

  info "==> update-peers plan"
  info "    this node:    $NODE_NAME ($LOCAL_IP)"
  info "    old PEER_IPS: $PEER_IPS  (size $CLUSTER_SIZE)"
  info "    new PEER_IPS: $new_ips  (size $new_size)"
  if (( dry_run )); then
    warn "--dry-run set; no actions will be performed"
  fi

  # Step 1: cluster.env update.
  info "==> Step 1: update local cluster.env"
  if (( dry_run )); then
    info "    would write: PEER_IPS=$new_ips"
  else
    sed -i.bak "s|^PEER_IPS=.*|PEER_IPS=$new_ips|" "$CLUSTER_ENV"
    ok "cluster.env updated (backup: ${CLUSTER_ENV}.bak)"
  fi

  # Step 2: re-render with the new PEER_IPS in scope. We re-source the
  # updated cluster.env and re-run role_detect so PEERS_ARR / PEER_NAMES
  # / CLUSTER_SIZE refresh — render relies on those, and they were
  # populated from the OLD PEER_IPS earlier in env_require.
  info "==> Step 2: re-render local templates"
  if (( dry_run )); then
    info "    would run: milvus-onprem render"
  else
    # shellcheck disable=SC1090
    source "$CLUSTER_ENV"
    role_detect
    render_all
    ok "rendered"
  fi

  # Step 3: reload nginx (non-disruptive).
  info "==> Step 3: reload nginx"
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
  ok "update-peers complete on $NODE_NAME"
  info "MinIO server-list change still requires a coordinated rolling restart — see docs/OPERATIONS.md."
}
