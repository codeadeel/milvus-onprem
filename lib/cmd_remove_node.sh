# =============================================================================
# lib/cmd_remove_node.sh — gracefully remove a peer from the cluster
#
# Distributed mode only — routes to the daemon's `remove-node` job. The
# daemon orchestrates: MinIO pool decommission (data movement to other
# pools) → etcd member-remove → topology delete → other peers re-render
# without the leaving peer in their nginx upstream / MinIO server list.
#
# After this command returns successfully, the leaving peer's containers
# are still running but orphaned at the cluster level. Operator follow-
# up: on the leaving VM, run `./milvus-onprem teardown --full --force`
# to clean up local state.
#
# Refuses to run if:
#   - cluster has only 1 peer (would destroy the cluster)
#   - target IP is the current leader (operator should failover first)
#
# Standalone mode rejects this command — there's nothing to remove from
# in a 1-VM deploy.
# =============================================================================

[[ -n "${_CMD_REMOVE_NODE_SH_LOADED:-}" ]] && return 0
_CMD_REMOVE_NODE_SH_LOADED=1

cmd_remove_node() {
  local ip=""
  local force=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip=*)   ip="${1#*=}"; shift ;;
      --ip)     ip="$2"; shift 2 ;;
      --force)  force=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem remove-node --ip=PEER_IP [--force]

Gracefully remove a peer from the running distributed cluster.

  --ip=PEER_IP    The leaving peer's IP. Must match exactly the IP in
                  PEER_IPS / etcd topology.
  --force         Skip the confirmation prompt.

What happens (orchestrated by the daemon as a 'remove-node' job):
  1. MinIO pool decommission — copies the leaving peer's data to
     remaining pools. Fast on small clusters; can take hours on real
     data volumes.
  2. etcd member-remove — clean Raft exit.
  3. Topology entry delete — other peers re-render their templates
     and reload nginx; the leaving peer drops out of the LB and the
     MinIO server list automatically.

Operator follow-up: on the leaving peer, run
  ./milvus-onprem teardown --full --force
to clean up its containers + /data.
EOF
        return 0
        ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  [[ -n "$ip" ]] || die "--ip is required"

  env_require
  role_detect

  if [[ "${MODE:-standalone}" != "distributed" ]]; then
    die "remove-node requires MODE=distributed (nothing to remove from in a single-VM deploy)"
  fi

  # Confirmation. Removing a peer triggers data movement and can take
  # a long time. Operator should know what they're doing.
  if (( ! force )); then
    if [[ -t 0 ]]; then
      echo ""
      echo "About to remove peer ${ip} from cluster ${CLUSTER_NAME}."
      echo "This will:"
      echo "  1. Decommission ${ip}'s MinIO pool (data moves to other pools)"
      echo "  2. Remove ${ip} from etcd Raft"
      echo "  3. Drop ${ip} from every other peer's render + nginx upstream"
      echo ""
      echo "After this completes, the leaving peer's containers are orphaned."
      echo "You'll need to run \`./milvus-onprem teardown --full --force\` on ${ip}."
      echo ""
      read -r -p "Type 'yes' to proceed: " ans
      [[ "$ans" == "yes" ]] || { info "aborted"; return 1; }
    else
      die "non-interactive use requires --force"
    fi
  fi

  _remove_node_via_daemon "$ip"
}

# POST a remove-node job to the right daemon and poll until done.
#
# When the target IS the current leader we can't use the local daemon
# end-to-end: the worker on the local daemon would step itself down,
# forward the job to the new leader, and try to track the forwarded
# job — but as the actual remove progresses, the local etcd is
# removed from cluster membership and the local daemon's /jobs reads
# start hanging. So the CLI orchestrates the failover here:
#   1. read /leader to find the current leader
#   2. if target == leader, POST /admin/step-down on the local daemon,
#      poll /leader until a different peer wins the next term, then
#      POST /jobs directly to that new leader's daemon
#   3. else, fall through to the simple submit-locally path
_remove_node_via_daemon() {
  local ip="$1"
  local local_cp="http://127.0.0.1:${CONTROL_PLANE_PORT:-19500}"
  local token="${CLUSTER_TOKEN:-}"
  [[ -n "$token" ]] || die "CLUSTER_TOKEN missing in cluster.env"

  local cp_url="$local_cp"
  local leader_ip=""
  leader_ip=$(curl -fsS --max-time 5 -H "Authorization: Bearer $token" \
    "$local_cp/leader" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); l=d.get('leader'); print(l['ip'] if l else '')" 2>/dev/null) \
    || true
  if [[ "$leader_ip" == "$ip" ]]; then
    info "target $ip is the current leader — orchestrating failover"
    info "==> POST /admin/step-down on $local_cp"
    curl -fsS --max-time 10 -X POST \
      -H "Authorization: Bearer $token" \
      "$local_cp/admin/step-down" >/dev/null \
      || die "step-down request failed — local daemon unreachable?"
    info "step-down accepted; waiting for a new leader to win the next term"
    local new_leader_ip=""
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
      sleep 3
      new_leader_ip=$(curl -fsS --max-time 5 \
        -H "Authorization: Bearer $token" "$local_cp/leader" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); l=d.get('leader'); print(l['ip'] if l else '')" 2>/dev/null) \
        || true
      if [[ -n "$new_leader_ip" && "$new_leader_ip" != "$ip" ]]; then
        ok "new leader is $new_leader_ip"
        break
      fi
    done
    [[ -n "$new_leader_ip" && "$new_leader_ip" != "$ip" ]] \
      || die "no new leader elected within 30s; aborting remove-node — cluster may need manual intervention"
    cp_url="http://${new_leader_ip}:${CONTROL_PLANE_PORT:-19500}"
  fi

  local body
  body=$(python3 -c "
import json
print(json.dumps({'type':'remove-node','params':{'ip':'$ip'}}))
")
  info "==> POST /jobs (remove-node ip=$ip) on $cp_url"
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
