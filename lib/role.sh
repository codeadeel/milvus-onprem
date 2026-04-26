# =============================================================================
# lib/role.sh — figure out which node we are within PEER_IPS
#
# Sets globals:
#   PEERS_ARR      bash array of peer IPs (e.g. (10.0.0.10 10.0.0.11 10.0.0.12))
#   PEER_NAMES     bash array of node names (e.g. (node-1 node-2 node-3))
#   CLUSTER_SIZE   integer count of peers
#   NODE_INDEX     1-based index of THIS node in the peer list
#   NODE_NAME      "node-$NODE_INDEX"
#   LOCAL_IP       this node's IP (matches PEERS_ARR[NODE_INDEX-1])
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

  # Allow override for unusual networking setups.
  if [[ -n "${FORCE_NODE_INDEX:-}" ]]; then
    NODE_INDEX="$FORCE_NODE_INDEX"
    LOCAL_IP="${PEERS_ARR[$((NODE_INDEX-1))]}"
    NODE_NAME="node-$NODE_INDEX"
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
      return 0
    fi
  done

  die "could not match any of \`hostname -I\` ($my_ips) against PEER_IPS ($PEER_IPS). Is this VM in the cluster? If you really need to override, set FORCE_NODE_INDEX=N."
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
