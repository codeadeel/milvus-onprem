# =============================================================================
# lib/watchdog.sh — alert-only peer-down watchdog (LEGACY / OPTIONAL)
#
# This is the LEGACY shell-based watchdog from the pre-control-plane era.
# In a distributed deploy the control-plane daemon runs its own watchdog
# (daemon/watchdog.py) which:
#   - polls local containers every 10s and DOES auto-restart unhealthy
#     ones when WATCHDOG_MODE=auto (default), with a 3-restart loop guard
#   - polls peer reachability and emits PEER_DOWN_ALERT / PEER_UP_ALERT
# So in distributed mode this script is unused.
#
# Standalone-mode operators who still want peer-down alerts (e.g., from
# a script running outside the deploy) can run `milvus-onprem watchdog`
# which sources this file. It only emits PEER_DOWN / PEER_UP — there's no
# remediation here because cross-host docker actions need the daemon
# anyway. For the auto-restart behavior, use a distributed deploy.
#
# Polls every PEER ip in PEER_IPS on WATCHDOG_INTERVAL_S (default 5s).
# A peer is "down" when its Milvus TCP port is unreachable. After
# WATCHDOG_FAILURE_THRESHOLD consecutive failures (default 6 → 30s on
# the default interval) we emit a single-line `PEER_DOWN_ALERT` to
# stdout. When the peer comes back we emit a matching `PEER_UP_ALERT`.
#
# Modes (set via WATCHDOG_MODE in cluster.env):
#   monitor (default) — alert only, do nothing else.
#   auto              — same as monitor in this LEGACY script. The real
#                       auto-recovery lives in daemon/watchdog.py and
#                       fires automatically in distributed mode.
# =============================================================================

[[ -n "${_WATCHDOG_SH_LOADED:-}" ]] && return 0
_WATCHDOG_SH_LOADED=1

# watchdog_run — main loop. Caller is responsible for env_require + role_detect.
watchdog_run() {
  local interval="${WATCHDOG_INTERVAL_S:-5}"
  local threshold="${WATCHDOG_FAILURE_THRESHOLD:-6}"
  local mode="${WATCHDOG_MODE:-monitor}"

  case "$mode" in
    monitor|auto) ;;
    *) die "WATCHDOG_MODE=$mode invalid (expected: monitor | auto)" ;;
  esac

  info "==> watchdog starting"
  info "    cluster:   $CLUSTER_NAME ($CLUSTER_SIZE peers)"
  info "    self:      $NODE_NAME ($LOCAL_IP)"
  info "    interval:  ${interval}s"
  info "    threshold: $threshold consecutive failures"
  info "    mode:      $mode"

  # Per-peer state. Indexed by peer IP. Bash assoc arrays are fine here
  # — peer count is small (<=9) and the watchdog is the only writer.
  declare -A fail_count
  declare -A down_since_epoch
  declare -A alerted

  local i ip
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    ip="${PEERS_ARR[$i]}"
    [[ "$ip" == "$LOCAL_IP" ]] && continue
    fail_count[$ip]=0
    down_since_epoch[$ip]=0
    alerted[$ip]=0
  done

  while true; do
    for ((i=0; i<CLUSTER_SIZE; i++)); do
      ip="${PEERS_ARR[$i]}"
      [[ "$ip" == "$LOCAL_IP" ]] && continue
      if _watchdog_peer_reachable "$ip"; then
        # Recovery path: if we previously alerted, emit the up-alert.
        if (( alerted[$ip] )); then
          local now down_for
          now=$(date +%s)
          down_for=$(( now - down_since_epoch[$ip] ))
          _watchdog_alert "PEER_UP_ALERT" "$ip" \
            "consecutive_failures=0" "was_down_for_s=$down_for"
          alerted[$ip]=0
          down_since_epoch[$ip]=0
        fi
        fail_count[$ip]=0
      else
        fail_count[$ip]=$(( fail_count[$ip] + 1 ))
        # Emit exactly once per down-event when we cross the threshold.
        if (( fail_count[$ip] == threshold )); then
          down_since_epoch[$ip]=$(date +%s)
          alerted[$ip]=1
          _watchdog_alert "PEER_DOWN_ALERT" "$ip" \
            "consecutive_failures=${fail_count[$ip]}"
        fi
      fi
    done
    sleep "$interval"
  done
}

# TCP probe — same as cmd_status.sh:_milvus_peer_reachable. We don't
# source that helper here to avoid coupling watchdog to status code.
_watchdog_peer_reachable() {
  local ip="$1"
  timeout 3 bash -c "</dev/tcp/$ip/$MILVUS_PORT" 2>/dev/null
}

# _watchdog_alert <kind> <ip> [extra-kv ...]
# Emits one structured line to stdout (journald). The format is
# <KIND> ts=<iso8601> node=<peer-name> ip=<ip> mode=<mode> [kv...]
# — single-line, space-separated key=value pairs, easy to grep.
_watchdog_alert() {
  local kind="$1" ip="$2"; shift 2
  local node ts
  node="$(_watchdog_peer_node_name "$ip")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s ts=%s node=%s ip=%s mode=%s' \
    "$kind" "$ts" "$node" "$ip" "${WATCHDOG_MODE:-monitor}"
  local kv
  for kv in "$@"; do
    printf ' %s' "$kv"
  done
  printf '\n'
}

# Resolve "node-N" from peer IP using its position in PEER_IPS.
_watchdog_peer_node_name() {
  local target="$1" i
  for ((i=0; i<CLUSTER_SIZE; i++)); do
    if [[ "${PEERS_ARR[$i]}" == "$target" ]]; then
      echo "node-$((i+1))"
      return 0
    fi
  done
  echo "unknown"
}
