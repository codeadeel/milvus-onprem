# =============================================================================
# lib/cmd_watchdog.sh — `milvus-onprem watchdog`
#
# Long-running peer-down poller. Designed to be the ExecStart of the
# milvus-watchdog.service systemd unit installed by `cmd_install
# --with-watchdog`. Can also be run directly for ad-hoc monitoring.
#
# Configuration via cluster.env (defaults applied by lib/env.sh):
#   WATCHDOG_INTERVAL_S=5         — poll interval per peer
#   WATCHDOG_FAILURE_THRESHOLD=6  — consecutive misses before alert
#   WATCHDOG_MODE=monitor         — monitor | auto (auto-recovery TBD)
# =============================================================================

[[ -n "${_CMD_WATCHDOG_SH_LOADED:-}" ]] && return 0
_CMD_WATCHDOG_SH_LOADED=1

cmd_watchdog() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        cat <<EOF
Usage: milvus-onprem watchdog

Long-running peer-down poller. Polls each peer's Milvus TCP port every
WATCHDOG_INTERVAL_S seconds; emits a PEER_DOWN_ALERT line after
WATCHDOG_FAILURE_THRESHOLD consecutive failures, and a PEER_UP_ALERT
when the peer comes back.

Designed for systemd: \`milvus-onprem install --with-watchdog\` drops a
unit at /etc/systemd/system/milvus-watchdog.service that runs this
under journald. Tail the alerts with:

  journalctl -u milvus-watchdog -f | grep PEER_

Configuration is read from cluster.env (WATCHDOG_INTERVAL_S,
WATCHDOG_FAILURE_THRESHOLD, WATCHDOG_MODE). See docs/CONFIG.md.
EOF
        return 0
        ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  env_require
  role_detect
  watchdog_run
}
