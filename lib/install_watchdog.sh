# =============================================================================
# lib/install_watchdog.sh — install/uninstall the milvus-watchdog systemd unit
#
# Used by cmd_install.sh when --with-watchdog is passed. Single-concern so
# cmd_install.sh stays focused on the CLI wrapper + bash-completion path.
#
# Reads SYSTEMD_UNIT_DIR / WATCHDOG_UNIT_NAME defaults from cmd_install.sh
# (sourced before this file by the dispatcher), and uses
# _install_sudo_if_needed from there for the per-target sudo decision.
# =============================================================================

[[ -n "${_INSTALL_WATCHDOG_SH_LOADED:-}" ]] && return 0
_INSTALL_WATCHDOG_SH_LOADED=1

_install_watchdog_unit() {
  local src="$REPO_ROOT/install/$WATCHDOG_UNIT_NAME.tpl"
  local dst="$SYSTEMD_UNIT_DIR/$WATCHDOG_UNIT_NAME"
  [[ -f "$src" ]] || die "missing template: $src"
  command -v systemctl >/dev/null 2>&1 \
    || die "systemctl not found — --with-watchdog requires systemd"

  local s; s="$(_install_sudo_if_needed "$dst")"
  info "==> installing $dst"
  REPO_ROOT="$REPO_ROOT" envsubst '$REPO_ROOT' < "$src" \
    | $s tee "$dst" >/dev/null
  $s chmod 0644 "$dst"
  $s systemctl daemon-reload
  $s systemctl enable --now "$WATCHDOG_UNIT_NAME"
  ok "watchdog enabled — \`journalctl -u $WATCHDOG_UNIT_NAME -f | grep PEER_\`"
}

_uninstall_watchdog_unit() {
  local dst="$SYSTEMD_UNIT_DIR/$WATCHDOG_UNIT_NAME"
  command -v systemctl >/dev/null 2>&1 || {
    info "==> systemctl not found, skipping watchdog removal"
    return 0
  }
  if systemctl list-unit-files "$WATCHDOG_UNIT_NAME" >/dev/null 2>&1 \
       && systemctl is-enabled "$WATCHDOG_UNIT_NAME" >/dev/null 2>&1; then
    local s; s="$(_install_sudo_if_needed "$dst")"
    info "==> disabling $WATCHDOG_UNIT_NAME"
    $s systemctl disable --now "$WATCHDOG_UNIT_NAME" || true
  fi
  if [[ -e "$dst" ]]; then
    local s; s="$(_install_sudo_if_needed "$dst")"
    info "==> removing $dst"
    $s rm -f "$dst"
    $s systemctl daemon-reload
  else
    info "==> $dst not present, skipping"
  fi
}
