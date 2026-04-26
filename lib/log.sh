# =============================================================================
# lib/log.sh — console output helpers
#
# Five log levels: info, ok, warn, err, die. Timestamped, colored if stderr
# is a TTY, plain if not (e.g. piped to a log file or systemd journal).
# All output goes to stderr so stdout stays clean for command output.
# =============================================================================

[[ -n "${_LOG_SH_LOADED:-}" ]] && return 0
_LOG_SH_LOADED=1

if [[ -t 2 ]]; then
  _C_RED=$'\033[31m' _C_YEL=$'\033[33m' _C_GRN=$'\033[32m'
  _C_CYN=$'\033[36m' _C_BLD=$'\033[1m'  _C_OFF=$'\033[0m'
else
  _C_RED='' _C_YEL='' _C_GRN='' _C_CYN='' _C_BLD='' _C_OFF=''
fi

_log() {
  # _log <color> <prefix> <msg...>
  local color="$1" prefix="$2"; shift 2
  local ts; ts="$(date +%H:%M:%S)"
  if [[ -n "$prefix" ]]; then
    printf '%s[%s]%s %s%s%s %s\n' \
      "$color" "$ts" "$_C_OFF" "$color" "$prefix" "$_C_OFF" "$*" >&2
  else
    printf '[%s] %s\n' "$ts" "$*" >&2
  fi
}

info() { _log "" "" "$@"; }
ok()   { _log "$_C_GRN" "OK"    "$@"; }
warn() { _log "$_C_YEL" "WARN"  "$@"; }
err()  { _log "$_C_RED" "ERROR" "$@"; }

die() {
  err "$@"
  exit 1
}
