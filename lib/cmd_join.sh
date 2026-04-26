# =============================================================================
# lib/cmd_join.sh — fetch cluster.env from the bootstrap node, then bootstrap
#
# Run on every non-bootstrap peer. After the bootstrap node has run
# `milvus-onprem pair` and printed a token, each peer runs:
#
#   milvus-onprem join <bootstrap-ip>:<port> <token>
#
# This fetches cluster.env via HTTP (Bearer auth), validates it, runs host
# prep, then runs bootstrap automatically — no separate init/bootstrap on
# joining nodes.
# =============================================================================

[[ -n "${_CMD_JOIN_SH_LOADED:-}" ]] && return 0
_CMD_JOIN_SH_LOADED=1

cmd_join() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 2 ]]; then
    cat <<EOF
Usage: milvus-onprem join <bootstrap-ip>:<port> <token>

Fetch cluster.env from the bootstrap node and run bootstrap locally.
The bootstrap-ip:port and token come from the bootstrap node's
\`milvus-onprem pair\` output.
EOF
    [[ $# -lt 2 ]] && return 1 || return 0
  fi

  local pair_addr="$1" token="$2"

  if [[ -f "$CLUSTER_ENV" ]]; then
    die "cluster.env already exists at $CLUSTER_ENV — \`milvus-onprem teardown --full --force\` first if you really want to re-join"
  fi

  local url="http://${pair_addr}/cluster.env"
  info "==> fetching cluster.env from $url"
  if ! curl -sf --max-time 30 \
       -H "Authorization: Bearer $token" \
       -o "$CLUSTER_ENV" "$url"; then
    rm -f "$CLUSTER_ENV"
    die "fetch failed — possible causes: bad token, server already exited, port blocked, wrong host"
  fi
  chmod 600 "$CLUSTER_ENV"
  ok "wrote $CLUSTER_ENV"

  # Sanity-check the fetched file before relying on it.
  grep -q "^PEER_IPS=" "$CLUSTER_ENV" \
    || die "fetched file doesn't look like cluster.env (missing PEER_IPS)"

  # Load + validate, prep host, then run the full bootstrap.
  env_require
  role_detect
  role_validate_size

  info "==> joining as $NODE_NAME ($LOCAL_IP)"
  host_prep "$DATA_ROOT"

  info "==> running bootstrap"
  cmd_bootstrap
}
