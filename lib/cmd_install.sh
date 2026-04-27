# =============================================================================
# lib/cmd_install.sh — drop the CLI on PATH + bash completion
#
# Installs:
#   $INSTALL_PREFIX/milvus-onprem        — wrapper that execs $REPO_ROOT/milvus-onprem
#   $COMPLETION_DIR/milvus-onprem        — bash completion rules
#
# Both paths can be overridden for non-root or testing setups via the
# --prefix / --completion-dir flags or INSTALL_PREFIX / COMPLETION_DIR
# env vars. Whether or not we sudo for each is decided per-target by
# probing the parent dir's writability — so a user-writable PATH (e.g.
# `--prefix=$HOME/.local/bin`) installs without sudo.
#
# `uninstall` removes the same two artifacts and leaves the working tree
# alone; for data wipe see `teardown --full`.
# =============================================================================

[[ -n "${_CMD_INSTALL_SH_LOADED:-}" ]] && return 0
_CMD_INSTALL_SH_LOADED=1

: "${INSTALL_PREFIX:=/usr/local/bin}"
: "${COMPLETION_DIR:=/etc/bash_completion.d}"
: "${CLI_NAME:=milvus-onprem}"
: "${SYSTEMD_UNIT_DIR:=/etc/systemd/system}"
: "${WATCHDOG_UNIT_NAME:=milvus-watchdog.service}"

cmd_install() {
  local prefix="$INSTALL_PREFIX"
  local comp_dir="$COMPLETION_DIR"
  local with_watchdog=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix=*)         prefix="${1#*=}"; shift ;;
      --prefix)           prefix="$2"; shift 2 ;;
      --completion-dir=*) comp_dir="${1#*=}"; shift ;;
      --completion-dir)   comp_dir="$2"; shift 2 ;;
      --with-watchdog)    with_watchdog=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem install [--prefix=DIR] [--completion-dir=DIR] [--with-watchdog]

Drop a wrapper for this repo's CLI on PATH, plus bash completion.
With --with-watchdog, also install and enable the milvus-watchdog
systemd unit (alerts on peer-down via journald).

After install you can run \`milvus-onprem <cmd>\` from any directory; the
wrapper just execs the script in this repo, so \`git pull\` here updates
the system-wide CLI too.

Defaults:
  --prefix=$INSTALL_PREFIX
  --completion-dir=$COMPLETION_DIR
  systemd unit dir = $SYSTEMD_UNIT_DIR (with --with-watchdog)

Examples:
  # System-wide (will sudo if needed):
  milvus-onprem install

  # System-wide + alert-mode watchdog:
  milvus-onprem install --with-watchdog

  # Per-user, no sudo:
  milvus-onprem install --prefix=\$HOME/.local/bin --completion-dir=\$HOME/.bash_completion.d

To remove: milvus-onprem uninstall [--with-watchdog]
EOF
        return 0
        ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  local wrapper_src="$REPO_ROOT/install/$CLI_NAME.wrapper.tpl"
  local completion_src="$REPO_ROOT/install/$CLI_NAME.bash-completion"
  [[ -f "$wrapper_src"    ]] || die "missing template: $wrapper_src (is the install/ dir intact?)"
  [[ -f "$completion_src" ]] || die "missing template: $completion_src"

  local wrapper_dst="$prefix/$CLI_NAME"
  local completion_dst="$comp_dir/$CLI_NAME"

  info "==> install layout"
  info "  REPO_ROOT       = $REPO_ROOT"
  info "  CLI wrapper     = $wrapper_dst"
  info "  bash completion = $completion_dst"

  # --- 1. CLI wrapper ---------------------------------------------------
  local sudo_wrap; sudo_wrap="$(_install_sudo_if_needed "$wrapper_dst")"
  info "==> installing $wrapper_dst"
  if [[ ! -d "$prefix" ]]; then
    $sudo_wrap mkdir -p "$prefix"
  fi
  REPO_ROOT="$REPO_ROOT" envsubst '$REPO_ROOT' < "$wrapper_src" \
    | $sudo_wrap tee "$wrapper_dst" >/dev/null
  $sudo_wrap chmod 0755 "$wrapper_dst"

  # --- 2. bash completion -----------------------------------------------
  local sudo_comp; sudo_comp="$(_install_sudo_if_needed "$completion_dst")"
  info "==> installing $completion_dst"
  if [[ ! -d "$comp_dir" ]]; then
    $sudo_comp mkdir -p "$comp_dir"
  fi
  $sudo_comp install -m 0644 "$completion_src" "$completion_dst"

  if (( with_watchdog )); then
    _install_watchdog_unit
  fi

  ok "install complete"
  info ""
  info "next:"
  info "  - open a new shell (or \`source $completion_dst\`) to pick up completion"
  info "  - run \`$CLI_NAME help\` from anywhere"
  if (( with_watchdog )); then
    info "  - watchdog: \`journalctl -u $WATCHDOG_UNIT_NAME -f | grep PEER_\`"
  fi
  info "  - to remove: \`$CLI_NAME uninstall\`"
}

cmd_uninstall() {
  local prefix="$INSTALL_PREFIX"
  local comp_dir="$COMPLETION_DIR"
  local with_watchdog=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --prefix=*)         prefix="${1#*=}"; shift ;;
      --prefix)           prefix="$2"; shift 2 ;;
      --completion-dir=*) comp_dir="${1#*=}"; shift ;;
      --completion-dir)   comp_dir="$2"; shift 2 ;;
      --with-watchdog)    with_watchdog=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem uninstall [--prefix=DIR] [--completion-dir=DIR] [--with-watchdog]

Remove the system-wide wrapper and bash completion installed by
\`milvus-onprem install\`. With --with-watchdog, also disable and remove
the milvus-watchdog systemd unit. Doesn't touch the working tree,
containers, or data — for that, see \`teardown --full\`.
EOF
        return 0
        ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  local wrapper_dst="$prefix/$CLI_NAME"
  local completion_dst="$comp_dir/$CLI_NAME"

  if (( with_watchdog )); then
    _uninstall_watchdog_unit
  fi

  if [[ -e "$wrapper_dst" ]]; then
    local s; s="$(_install_sudo_if_needed "$wrapper_dst")"
    info "==> removing $wrapper_dst"
    $s rm -f "$wrapper_dst"
  else
    info "==> $wrapper_dst not present, skipping"
  fi

  if [[ -e "$completion_dst" ]]; then
    local s; s="$(_install_sudo_if_needed "$completion_dst")"
    info "==> removing $completion_dst"
    $s rm -f "$completion_dst"
  else
    info "==> $completion_dst not present, skipping"
  fi

  ok "uninstall complete"
}

# Echo "sudo" if we'd need root to write to <path>'s parent dir, "" otherwise.
# Caller uses the result unquoted: `$sudo_var cp src dst`.
_install_sudo_if_needed() {
  local p="$1"
  local parent; parent="$(dirname "$p")"
  # If parent doesn't exist yet, walk up to the nearest existing ancestor
  # to decide whether mkdir would need sudo.
  while [[ ! -d "$parent" && "$parent" != "/" ]]; do
    parent="$(dirname "$parent")"
  done
  if [[ -w "$parent" ]]; then
    echo ""
  else
    echo "sudo"
  fi
}
