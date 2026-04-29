# =============================================================================
# lib/cmd_maintenance.sh — operator hygiene actions on a healthy cluster
#
# Bundles the small "I should probably tidy up" actions that accumulate over
# time but don't fit anywhere else: dangling Docker images from daemon
# rebuilds, stale logs, that kind of thing. Resolves QA finding F-Phase1.D
# (dangling images accumulating to ~700 MB after a busy QA day).
#
# The defaults are conservative — nothing destructive happens without
# --confirm. `--dry-run` prints what would be done.
# =============================================================================

[[ -n "${_CMD_MAINTENANCE_SH_LOADED:-}" ]] && return 0
_CMD_MAINTENANCE_SH_LOADED=1

cmd_maintenance() {
  local dry_run=0
  local confirm=0
  local prune_images=0
  local prune_logs=0
  local prune_etcd_jobs=0
  local all=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)         dry_run=1; shift ;;
      --confirm)         confirm=1; shift ;;
      --prune-images)    prune_images=1; shift ;;
      --prune-logs)      prune_logs=1; shift ;;
      --prune-etcd-jobs) prune_etcd_jobs=1; shift ;;
      --all)             all=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: milvus-onprem maintenance [OPTIONS]

Run operator-side hygiene actions. Pick subsets via flags or --all.

  --prune-images       Remove dangling Docker images (typically 100s of MB
                       after each daemon rebuild). Equivalent to:
                         docker image prune -f
  --prune-logs         Truncate per-container Docker JSON logs that have
                       grown unbounded. (Operator must rotate at the docker
                       daemon level for a real fix; this is a one-shot
                       reclaim.)
  --prune-etcd-jobs    Trigger an immediate stuck-running + retention sweep
                       on the leader's daemon (normally runs every 30s /
                       1h, but you may want it now).
  --all                Run every action above.
  --dry-run            Print actions without doing them.
  --confirm            Required to actually run (without it, prints the
                       plan and exits — same as --dry-run).
  -h, --help           Show this help.

The maintenance window is a NO-OP if there's nothing to clean.

Idempotent: safe to run as a cron job. Don't.
EOF
        return 0
        ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  (( all )) && { prune_images=1; prune_logs=1; prune_etcd_jobs=1; }

  if (( ! prune_images && ! prune_logs && ! prune_etcd_jobs )); then
    die "pick at least one of --prune-images / --prune-logs / --prune-etcd-jobs (or --all). See --help."
  fi

  # Lenient env load — maintenance shouldn't fail if cluster.env has
  # validation issues; we only need MODE / CLUSTER_TOKEN /
  # CONTROL_PLANE_PORT for the etcd-jobs path. env_load 2>/dev/null
  # is the same pattern teardown uses.
  env_load 2>/dev/null || true

  if (( ! dry_run && ! confirm )); then
    info "no --confirm passed — running in dry-run mode."
    dry_run=1
  fi

  local action_count=0
  if (( prune_images )); then
    _maint_prune_images "$dry_run" && action_count=$((action_count + 1))
  fi
  if (( prune_logs )); then
    _maint_prune_logs "$dry_run" && action_count=$((action_count + 1))
  fi
  if (( prune_etcd_jobs )); then
    _maint_prune_etcd_jobs "$dry_run" && action_count=$((action_count + 1))
  fi
  ok "maintenance complete ($action_count action(s))"
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

_maint_prune_images() {
  local dry_run="$1"
  local dangling_count
  dangling_count="$(docker images --filter dangling=true --quiet 2>/dev/null | wc -l)"
  if (( dangling_count == 0 )); then
    info "  prune-images: 0 dangling images, nothing to do."
    return 0
  fi
  local size
  size="$(docker images --filter dangling=true --format '{{.Size}}' \
          | awk 'BEGIN{s=0}{n=$1+0; if (index($2,"GB")) n*=1000; if (index($2,"KB")) n/=1000; s+=n}END{printf "%.1f MB", s}')"
  if (( dry_run )); then
    info "  prune-images: would remove $dangling_count dangling image(s) (~$size)"
  else
    info "  prune-images: removing $dangling_count dangling image(s) (~$size)"
    docker image prune -f >/dev/null
    ok "  prune-images: done"
  fi
}

_maint_prune_logs() {
  local dry_run="$1"
  # Sum of per-container log sizes. Path inside docker is engine-specific
  # so we read the canonical /var/lib/docker/containers/*/*.log location.
  local total
  total="$(sudo du -sb /var/lib/docker/containers/*/ 2>/dev/null | awk '{s+=$1}END{print s+0}')"
  if (( dry_run )); then
    info "  prune-logs: would truncate per-container log files (current total: $((total/1024/1024)) MB)"
    return 0
  fi
  info "  prune-logs: truncating per-container log files"
  for f in /var/lib/docker/containers/*/*-json.log; do
    [[ -f "$f" ]] || continue
    sudo truncate -s 0 "$f" 2>/dev/null || true
  done
  ok "  prune-logs: done"
}

_maint_prune_etcd_jobs() {
  local dry_run="$1"
  if [[ "${MODE:-standalone}" != "distributed" ]]; then
    info "  prune-etcd-jobs: skipped (MODE=$MODE — no daemon to ask)"
    return 0
  fi
  local cp_url="http://127.0.0.1:${CONTROL_PLANE_PORT:-19500}"
  local token="${CLUSTER_TOKEN:-}"
  [[ -n "$token" ]] || die "  prune-etcd-jobs: CLUSTER_TOKEN missing"
  if (( dry_run )); then
    info "  prune-etcd-jobs: would call /admin/sweep on $cp_url"
    return 0
  fi
  info "  prune-etcd-jobs: requesting immediate sweep from leader"
  local resp
  resp="$(curl -fsS --location-trusted --max-time 30 \
    -H "Authorization: Bearer $token" \
    -X POST "$cp_url/admin/sweep")" \
    || die "  prune-etcd-jobs: /admin/sweep failed (daemon unreachable?)"
  ok "  prune-etcd-jobs: $resp"
}
