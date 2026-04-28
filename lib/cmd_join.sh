# =============================================================================
# lib/cmd_join.sh — join an existing distributed cluster as a new peer
#
# Replaces the pre-control-plane pair/join flow. From a fresh VM:
#
#   ./milvus-onprem join <leader-ip>:19500 <cluster-token>
#
# This POSTs /join to the control-plane daemon (which 307-redirects to
# the leader if hit on a follower). The leader does the orchestration
# end-to-end: etcd member-add, node-N allocation, topology entry, and
# returns a fully-baked cluster.env for this peer to write locally.
#
# After cluster.env is on disk, this script runs host_prep + bootstrap
# locally — no separate init/bootstrap step on joining peers.
# =============================================================================

[[ -n "${_CMD_JOIN_SH_LOADED:-}" ]] && return 0
_CMD_JOIN_SH_LOADED=1

cmd_join() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || $# -lt 2 ]]; then
    _cmd_join_help
    [[ $# -lt 2 ]] && return 1 || return 0
  fi

  local target="$1" token="$2"; shift 2
  local local_ip="" resume=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local-ip=*) local_ip="${1#*=}"; shift ;;
      --resume)     resume=1; shift ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  if [[ -f "$CLUSTER_ENV" ]]; then
    if [[ $resume -eq 1 ]] && grep -q "^ETCD_INITIAL_CLUSTER_STATE=existing" "$CLUSTER_ENV"; then
      info "==> --resume: cluster.env already present (join-originated); skipping /join POST"
      env_load >/dev/null
      host_prep "$DATA_ROOT" "${MODE:-distributed}"
      if [[ "${MODE:-distributed}" == "distributed" ]]; then
        _join_build_daemon_image
      fi
      info "==> resuming bootstrap"
      cmd_bootstrap
      echo ""
      echo "========================================================================"
      echo "  resumed (cluster.env was already on disk; bootstrap re-run)"
      echo "========================================================================"
      echo "  Verify from any node:    ./milvus-onprem status"
      echo "========================================================================"
      return 0
    fi
    if [[ $resume -eq 1 ]]; then
      die "--resume: $CLUSTER_ENV exists but lacks ETCD_INITIAL_CLUSTER_STATE=existing (not from a join). Use teardown then plain join."
    fi
    die "cluster.env already exists at $CLUSTER_ENV — to resume a partial join (e.g. SSH dropped before bootstrap finished) run with --resume; otherwise \`./milvus-onprem teardown --full --force\` first."
  fi

  # Auto-detect our own IP (operator can override with --local-ip if
  # hostname -I returns something we don't want).
  if [[ -z "$local_ip" ]]; then
    local_ip="$(_join_detect_local_ip)" \
      || die "couldn't auto-detect local IP from \`hostname -I\`. Pass --local-ip=<ip> explicitly."
  fi

  info "==> joining cluster via $target (advertising self as $local_ip)"

  # Hit the leader's /join endpoint. -L follows the 307 redirect that
  # a follower would send. -X POST + -d sends the body even after the
  # redirect (curl handles 307 correctly: same method, same body).
  local body
  body=$(printf '{"ip":"%s","hostname":"%s"}' "$local_ip" "$(hostname -s 2>/dev/null || true)")
  local resp http_code
  local resp_file; resp_file="$(mktemp)"
  # `--location-trusted` (vs `-L`) keeps the Authorization header
  # across redirects. Required because followers 307-redirect /join to
  # the current leader, which is on a different host. Safe here: every
  # daemon in the cluster shares the same CLUSTER_TOKEN, so leaking
  # the header to a peer is a no-op. Default `-L` would strip the
  # header on cross-host redirects (curl's anti-credential-leak rule),
  # leaving the leader to reject with 401 missing-bearer-token.
  http_code="$(curl -sS --location-trusted --max-time 60 \
    -o "$resp_file" -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" \
    "http://$target/join" || echo "000")"

  if [[ "$http_code" != "200" ]]; then
    local err; err=$(cat "$resp_file" 2>/dev/null || echo "")
    rm -f "$resp_file"
    die "join request failed (HTTP $http_code): $err"
  fi
  resp="$(cat "$resp_file")"
  rm -f "$resp_file"

  # Parse the response. python3 is required by the project anyway
  # (test/tutorial uses pymilvus); using it here avoids a jq dep.
  local node_name leader_ip cluster_env_body
  node_name=$(_join_parse_field "$resp" node_name)   || die "response missing node_name"
  leader_ip=$(_join_parse_field "$resp" leader_ip)   || die "response missing leader_ip"
  cluster_env_body=$(_join_parse_cluster_env "$resp") \
    || die "response missing cluster_env body"

  ok "leader allocated $node_name; writing cluster.env"
  # bash $(...) strips trailing newlines from command substitution, so
  # `cluster_env_body` is missing the leader's final '\n'. Without
  # restoring it, the next `echo KEY=VAL >> cluster.env` (env_upsert_kv
  # below) lands on the same line as the previous KEY=VAL, mashing two
  # entries together. The %s\n re-adds exactly the one trailing newline
  # the leader emitted.
  printf '%s\n' "$cluster_env_body" > "$CLUSTER_ENV"
  chmod 600 "$CLUSTER_ENV"

  # The leader doesn't (and shouldn't) know the joiner's host repo
  # path. We set it here so the daemon's bind mounts resolve to a
  # real host path on this peer, not the in-container /repo.
  env_upsert_kv HOST_REPO_ROOT "$REPO_ROOT"

  # Sanity-check the file before relying on it.
  grep -q "^PEER_IPS=" "$CLUSTER_ENV" \
    || die "fetched cluster.env doesn't look right (missing PEER_IPS)"
  grep -q "^ETCD_INITIAL_CLUSTER_STATE=existing" "$CLUSTER_ENV" \
    || warn "cluster.env from leader didn't set ETCD_INITIAL_CLUSTER_STATE=existing — joiner etcd may try to bootstrap fresh"

  # Now run the standard local pipeline: load env, prep host, build the
  # daemon image, render templates, bootstrap.
  env_load >/dev/null
  host_prep "$DATA_ROOT" "${MODE:-distributed}"

  if [[ "${MODE:-distributed}" == "distributed" ]]; then
    _join_build_daemon_image
  fi

  info "==> running bootstrap (state=existing for etcd)"
  cmd_bootstrap

  echo ""
  echo "========================================================================"
  echo "  joined as $node_name (leader=$leader_ip)"
  echo "========================================================================"
  echo "  Verify from any node:    ./milvus-onprem status"
  echo "  Verify locally:          docker ps"
  echo "========================================================================"
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# First non-loopback IPv4 from `hostname -I`. Empty on failure.
# (Same logic as cmd_init.sh's helper but kept local to avoid a new lib file.)
_join_detect_local_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i !~ /^127\./) {print $i; exit}}')"
  [[ -n "$ip" ]] || return 1
  printf '%s' "$ip"
}

# Extract a top-level string field from a JSON response. Stdin = response.
# Usage: _join_parse_field <json> <field>
_join_parse_field() {
  local json="$1" field="$2"
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    v = d.get('$field')
    if v is None:
        sys.exit(1)
    print(v)
except Exception:
    sys.exit(1)
"
}

# Cluster_env can contain newlines so we extract it carefully (python
# preserves them; bash command substitution would mangle a `\n` in JSON).
_join_parse_cluster_env() {
  local json="$1"
  printf '%s' "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    sys.stdout.write(d['cluster_env'])
except Exception:
    sys.exit(1)
"
}

# Build the daemon image locally if not already present. Idempotent.
_join_build_daemon_image() {
  local image="${CONTROL_PLANE_IMAGE:-milvus-onprem-cp:dev}"
  if docker image inspect "$image" >/dev/null 2>&1; then
    info "daemon image $image already built"
    return 0
  fi
  info "building daemon image $image (one-time per node)"
  docker build -t "$image" "$REPO_ROOT/daemon/" \
    || die "daemon image build failed — see docker output above"
}

_cmd_join_help() {
  cat <<'EOF'
Usage: milvus-onprem join <host>:<port> <cluster-token> [--local-ip=IP]

Join an existing distributed cluster as a new peer. Run on a fresh VM
(no cluster.env present). The control-plane daemon at <host>:<port>
allocates a node-N name, adds this peer to etcd Raft, and returns a
ready-to-use cluster.env which we write locally before bootstrapping.

ARGS:
  <host>:<port>     Any peer's control-plane endpoint, e.g. 10.0.0.2:19500.
                    Followers 307-redirect to whoever is currently leader.
  <cluster-token>   Shared bearer token printed by `init --mode=distributed`
                    (or read from any existing peer's cluster.env).

OPTIONS:
  --local-ip=IP     Override hostname -I auto-detection.
  --resume          Re-run bootstrap when cluster.env already exists from
                    a previous join attempt that didn't finish (e.g. SSH
                    dropped between cluster.env write and bootstrap
                    completing). Skips the /join HTTP call and proceeds
                    straight to host_prep + bootstrap. Refuses if
                    cluster.env exists but doesn't carry the join
                    marker (ETCD_INITIAL_CLUSTER_STATE=existing).
  -h, --help        Show this help.

After join completes, this node is fully part of the cluster — etcd
member, MinIO drive owner (a separate pool), Milvus replica, control-
plane daemon. No further commands required on the joining node.
EOF
}
