# =============================================================================
# lib/role.sh — figure out which node we are within PEER_IPS
#
# Sets globals:
#   PEERS_ARR        bash array of peer IPs (e.g. (10.0.0.10 10.0.0.11 10.0.0.12))
#   PEER_NAMES       bash array of node names (e.g. (node-1 node-2 node-3))
#   CLUSTER_SIZE     integer count of peers
#   NODE_INDEX       1-based index of THIS node in the peer list
#   NODE_NAME        "node-$NODE_INDEX"
#   LOCAL_IP         this node's IP (matches PEERS_ARR[NODE_INDEX-1])
#   PULSAR_HOST_IP   IP of the PULSAR_HOST node (only meaningful when
#                    MQ_TYPE=pulsar — used by urls/status/create-backup).
#
# Detection: matches `hostname -I` against PEER_IPS. Override possible via
# FORCE_NODE_INDEX env var (split-horizon NAT, ip-discovery weirdness).
#
# Expected to be sourced AFTER env_require.
# =============================================================================

[[ -n "${_ROLE_SH_LOADED:-}" ]] && return 0
_ROLE_SH_LOADED=1

role_detect() {
  IFS=',' read -ra PEERS_ARR <<< "$PEER_IPS"
  CLUSTER_SIZE="${#PEERS_ARR[@]}"

  # PEER_NAMES is the parallel array to PEER_IPS — the etcd-side name
  # for each peer. Prefer the cluster.env-persisted value (kept in
  # lockstep with topology by the daemon and by cmd_init/cmd_join);
  # fall back to position-synthesised "node-1, node-2, ..." for
  # bootstrap before the first peer is registered. Synthesising
  # post-remove is wrong because it shifts indices when a peer with
  # a low N is removed (e.g. removing node-1 from {node-1,2,3,4}
  # would relabel the survivors as 1,2,3 and break the etcd cluster
  # identity on any fresh container start).
  # cluster.env sets PEER_NAMES as a comma-separated string via env_load
  # (bash env files can't carry arrays). Split it into the array form
  # the rest of the codebase expects. If unset (older cluster.env from
  # a deploy before this field existed, or during very early bootstrap),
  # synthesise positional names — fine for fresh init / first join, NOT
  # safe to use after any remove-node has shifted etcd identities.
  local _peer_names_csv="${PEER_NAMES:-}"
  PEER_NAMES=()
  local i
  if [[ -n "$_peer_names_csv" ]]; then
    IFS=',' read -ra PEER_NAMES <<< "$_peer_names_csv"
    if [[ "${#PEER_NAMES[@]}" -ne "${CLUSTER_SIZE}" ]]; then
      die "PEER_NAMES (${#PEER_NAMES[@]} entries) and PEER_IPS (${CLUSTER_SIZE} entries) length mismatch in cluster.env. Re-render after fixing — re-init if cluster.env is unrecoverable."
    fi
  else
    for ((i=0; i<CLUSTER_SIZE; i++)); do
      PEER_NAMES+=("node-$((i+1))")
    done
  fi

  _role_resolve_pulsar_host_ip

  # Allow override for unusual networking setups.
  if [[ -n "${FORCE_NODE_INDEX:-}" ]]; then
    NODE_INDEX="$FORCE_NODE_INDEX"
    LOCAL_IP="${PEERS_ARR[$((NODE_INDEX-1))]}"
    NODE_NAME="${PEER_NAMES[$((NODE_INDEX-1))]}"
    export NODE_INDEX NODE_NAME LOCAL_IP CLUSTER_SIZE
    return 0
  fi

  # If cluster.env already pins NODE_NAME (set by init/join, kept by
  # the daemon when topology changes), trust it and just locate the
  # corresponding entry in PEER_NAMES to derive NODE_INDEX. This is
  # the common path post-init; the position-based scan below is only
  # the fallback for bootstrap and FORCE_NODE_INDEX edge cases.
  if [[ -n "${NODE_NAME:-}" ]]; then
    for ((i=0; i<CLUSTER_SIZE; i++)); do
      if [[ "${PEER_NAMES[$i]}" == "$NODE_NAME" ]]; then
        NODE_INDEX=$((i+1))
        # LOCAL_IP from cluster.env wins when set; else infer from
        # the matched position.
        : "${LOCAL_IP:=${PEERS_ARR[$i]}}"
        export NODE_INDEX NODE_NAME LOCAL_IP CLUSTER_SIZE
        return 0
      fi
    done
    die "NODE_NAME=$NODE_NAME not found in PEER_NAMES (${PEER_NAMES[*]}). cluster.env is out of sync with topology — re-render after fixing."
  fi

  # Bootstrap path: no NODE_NAME yet. Match `hostname -I` against the
  # peer-IP list to figure out which peer this VM is.
  local my_ips
  my_ips="$(hostname -I 2>/dev/null || ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"

  for ((i=0; i<CLUSTER_SIZE; i++)); do
    local ip="${PEERS_ARR[$i]}"
    if echo " $my_ips " | grep -q " $ip "; then
      NODE_INDEX=$((i+1))
      LOCAL_IP="$ip"
      NODE_NAME="${PEER_NAMES[$i]}"
      export NODE_INDEX NODE_NAME LOCAL_IP CLUSTER_SIZE
      return 0
    fi
  done

  die "could not match any of \`hostname -I\` ($my_ips) against PEER_IPS ($PEER_IPS). Is this VM in the cluster? If you really need to override, set FORCE_NODE_INDEX=N."
}

# Resolve PULSAR_HOST (e.g. "node-1") to its peer IP. Lifted out of
# render.sh so that any command (urls, status, bootstrap, create-backup)
# can rely on PULSAR_HOST_IP after role_detect runs — not just renders.
# Default to first peer if PULSAR_HOST doesn't match anything sensible.
_role_resolve_pulsar_host_ip() {
  PULSAR_HOST_IP=""
  local i
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    if [[ "${PEER_NAMES[$i]}" == "${PULSAR_HOST:-node-1}" ]]; then
      PULSAR_HOST_IP="${PEERS_ARR[$i]}"
      break
    fi
  done
  [[ -z "$PULSAR_HOST_IP" ]] && PULSAR_HOST_IP="${PEERS_ARR[0]}"
  export PULSAR_HOST_IP
}

# Validate runtime cluster size. The "odd-only" rule is enforced at init
# time (cmd_init.sh) — by the time we get here, an even size is necessarily
# a transient mid-scale-out state (e.g. 3 -> 4 between add-node and the
# next add-node that takes us to 5). Raft tolerates floor(N/2)+1 quorum
# at any N >= 1; even is just a worse capacity-planning point, not broken.
# So we allow it with a warning, and only die on size 0 or negative.
role_validate_size() {
  case "$CLUSTER_SIZE" in
    1) return 0 ;;
    [0-9]|[0-9][0-9])
      if (( CLUSTER_SIZE < 1 )); then
        die "CLUSTER_SIZE=$CLUSTER_SIZE invalid: must be >= 1. PEER_IPS=$PEER_IPS"
      fi
      if (( CLUSTER_SIZE % 2 == 0 )); then
        warn "CLUSTER_SIZE=$CLUSTER_SIZE is even — transient mid-scale-out state? Raft tolerates this but capacity is worse than the next-lower odd size. Plan another add-node to reach the next odd size."
      fi
      return 0
      ;;
    *) die "CLUSTER_SIZE=$CLUSTER_SIZE invalid: must be a positive integer. PEER_IPS=$PEER_IPS" ;;
  esac
}

role_is_standalone() {
  [[ "$CLUSTER_SIZE" == "1" ]]
}
