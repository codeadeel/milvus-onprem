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

  PEER_NAMES=()
  local i
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    PEER_NAMES+=("node-$((i+1))")
  done

  _role_resolve_pulsar_host_ip

  # Allow override for unusual networking setups.
  if [[ -n "${FORCE_NODE_INDEX:-}" ]]; then
    NODE_INDEX="$FORCE_NODE_INDEX"
    LOCAL_IP="${PEERS_ARR[$((NODE_INDEX-1))]}"
    NODE_NAME="node-$NODE_INDEX"
    export NODE_INDEX NODE_NAME LOCAL_IP CLUSTER_SIZE
    return 0
  fi

  # Standard path: match `hostname -I` against the list.
  local my_ips
  my_ips="$(hostname -I 2>/dev/null || ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | tr '\n' ' ')"

  for ((i=0; i<CLUSTER_SIZE; i++)); do
    local ip="${PEERS_ARR[$i]}"
    if echo " $my_ips " | grep -q " $ip "; then
      NODE_INDEX=$((i+1))
      LOCAL_IP="$ip"
      NODE_NAME="node-$NODE_INDEX"
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

# Reject even-numbered cluster sizes (no Raft quorum). Allow 1 (standalone).
role_validate_size() {
  case "$CLUSTER_SIZE" in
    1)         return 0 ;;
    3|5|7|9)   return 0 ;;
    *)         die "CLUSTER_SIZE=$CLUSTER_SIZE invalid: must be 1 (standalone) or odd ≥3 (3, 5, 7, 9). PEER_IPS=$PEER_IPS" ;;
  esac
}

role_is_standalone() {
  [[ "$CLUSTER_SIZE" == "1" ]]
}
