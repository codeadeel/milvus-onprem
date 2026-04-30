# =============================================================================
# lib/cmd_backup_etcd.sh — quick etcd snapshot
#
# Wraps lib/etcd.sh's etcd_backup() helper. Cheap insurance — take one
# before any risky operation (failover, scale-out, version bump, restore).
# Output is a single .db file that etcdutl can restore from later.
# =============================================================================

[[ -n "${_CMD_BACKUP_ETCD_SH_LOADED:-}" ]] && return 0
_CMD_BACKUP_ETCD_SH_LOADED=1

cmd_backup_etcd() {
  local output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output=*) output="${1#*=}"; shift ;;
      --output)   output="$2"; shift 2 ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem backup-etcd [--output=PATH]

Take a snapshot of the local etcd store.

  --output=PATH    Where to write the .db file.
                   Default: /tmp/etcd-snapshot-YYYYMMDD-HHMMSS.db

To restore, copy the .db file to the recovering node and use etcdutl
(see docs/TROUBLESHOOTING.md, "etcd snapshot restore" — coming in Phase F).
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  env_require
  role_detect

  # Distributed mode: route via daemon /jobs.
  if [[ "${MODE:-standalone}" == "distributed" \
        && "${MILVUS_ONPREM_INTERNAL:-}" != "1" ]]; then
    _backup_etcd_via_daemon
    return $?
  fi

  if [[ -n "$output" ]]; then
    etcd_backup "$output"
  else
    etcd_backup
  fi
}

# POST a backup-etcd job to the local daemon and poll until done.
_backup_etcd_via_daemon() {
  local cp_url="http://127.0.0.1:${CONTROL_PLANE_PORT:-19500}"
  local token="${CLUSTER_TOKEN:-}"
  [[ -n "$token" ]] || die "CLUSTER_TOKEN missing in cluster.env"

  info "==> POST /jobs (backup-etcd) on $cp_url"
  local resp
  resp=$(cp_post_job "$cp_url/jobs" "$token" '{"type":"backup-etcd","params":{}}')
  local job_id
  job_id=$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  ok "job created: $job_id"
  _poll_job "$job_id" "$cp_url" "$token"
}
