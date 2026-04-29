# =============================================================================
# lib/cmd_migrate_pulsar.sh — move the 2.5 Pulsar singleton to a new peer
#
# Distributed 2.5 only — routes to the daemon's `migrate-pulsar` job.
# Submits to the local daemon (which redirects to leader); the leader's
# worker walks every peer in order, pushing the new PULSAR_HOST and
# triggering each peer to re-render + recreate Milvus + Pulsar
# accordingly.
#
# Sequencing (handled by the worker):
#   1. New host first — Pulsar comes up there
#   2. Other peers — their Milvus reconnects to the new broker
#   3. Old host last — its Pulsar container is removed (the render no
#      longer emits a Pulsar service block when this peer isn't the
#      host) and its Milvus reconnects too
#
# Caveats called out in --help:
#   - Brief unavailability per peer during recreate (~30-60s each).
#   - Lossy: Pulsar topic backlog still pending on the old broker is
#     dropped. Run during a maintenance window with no active inserts.
#   - 2.5-only. 2.6's Woodpecker is per-peer, no singleton to migrate.
# =============================================================================

[[ -n "${_CMD_MIGRATE_PULSAR_SH_LOADED:-}" ]] && return 0
_CMD_MIGRATE_PULSAR_SH_LOADED=1

cmd_migrate_pulsar() {
  local to_node=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to=*)     to_node="${1#*=}"; shift ;;
      --to)       to_node="$2"; shift 2 ;;
      --force)    force=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem migrate-pulsar --to=NODE_NAME [--force]

Move the 2.5 Pulsar singleton from the current PULSAR_HOST to NODE_NAME.

  --to=NODE_NAME   Target peer (e.g. "node-2"). Must already be in the
                   cluster topology.
  --force          Skip the confirmation prompt.

What happens (orchestrated as a 'migrate-pulsar' daemon job):
  1. New host first — its compose gets the Pulsar service block, the
     Pulsar container starts, the worker waits for it to be reachable.
  2. Each non-target peer (other than the current host) — Milvus is
     recreated with the new pulsar.address.
  3. Old host last — its Pulsar container is dropped from the compose
     and Milvus is recreated to point at the new broker.

Caveats:
  * Brief unavailability per peer during recreate. Run during a
    maintenance window with no active inserts.
  * Lossy: any Pulsar topic backlog still pending on the old broker
    is dropped. Topic-drain / Pulsar replication is out of scope.
  * 2.5 only — 2.6 (Woodpecker) has no singleton broker to migrate.

After success, the old host can be removed cleanly with:
  ./milvus-onprem remove-node --ip=<old-host-ip>
EOF
        return 0
        ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  [[ -n "$to_node" ]] || die "--to=NODE_NAME is required"

  env_require
  role_detect

  if [[ "${MODE:-standalone}" != "distributed" ]]; then
    die "migrate-pulsar requires MODE=distributed"
  fi
  if [[ "${MQ_TYPE:-}" != "pulsar" ]]; then
    die "migrate-pulsar is only meaningful for MQ_TYPE=pulsar (Milvus 2.5). MQ_TYPE=${MQ_TYPE:-?}"
  fi

  if (( ! force )); then
    if [[ -t 0 ]]; then
      echo ""
      echo "About to migrate Pulsar from ${PULSAR_HOST:-node-1} to ${to_node}."
      echo "This recreates Milvus + Pulsar across every peer."
      echo "Expect ~30-60s of unavailability per peer."
      echo "Pulsar topic backlog on the old broker will be lost."
      echo ""
      read -r -p "Type 'yes' to proceed: " ans
      [[ "$ans" == "yes" ]] || { info "aborted"; return 1; }
    else
      die "non-interactive use requires --force"
    fi
  fi

  # Operator-side preflight. The daemon worker also preflights, but
  # surfacing a clear error here saves a round-trip and a job-id that
  # the operator would otherwise have to query. Refuse to submit if
  # any peer's reachability check is failing — in particular, a peer
  # that just finished /join may not yet be in the leader's topology
  # mirror, and a half-applied migration is much worse than no
  # migration.
  info "==> preflight: confirming all peers are reachable"
  local status_out
  status_out=$(./milvus-onprem status 2>&1) \
    || die "preflight: \`status\` errored — fix that before migrating"
  if printf '%s' "$status_out" | grep -E '^[[:space:]]*\[FAIL\]' >/dev/null; then
    echo "$status_out" | grep -E 'reachability|FAIL' | head -20
    die "preflight: at least one peer is not reachable. Wait for the cluster to settle (\`./milvus-onprem status\` should show all peers OK), then retry."
  fi
  ok "preflight: all peers reachable"

  _migrate_pulsar_via_daemon "$to_node"
}

_migrate_pulsar_via_daemon() {
  local to_node="$1"
  local cp_url="http://127.0.0.1:${CONTROL_PLANE_PORT:-19500}"
  local token="${CLUSTER_TOKEN:-}"
  [[ -n "$token" ]] || die "CLUSTER_TOKEN missing in cluster.env"

  local body
  body=$(python3 -c "
import json
print(json.dumps({'type':'migrate-pulsar','params':{'to_node':'$to_node'}}))
")
  info "==> POST /jobs (migrate-pulsar to_node=$to_node) on $cp_url"
  local resp
  resp=$(curl -fsS --location-trusted --max-time 30 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" "$cp_url/jobs") \
    || die "POST /jobs failed — daemon unreachable?"
  local job_id
  job_id=$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  ok "job created: $job_id"
  _poll_job "$job_id" "$cp_url" "$token"
}
