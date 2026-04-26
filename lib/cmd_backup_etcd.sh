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

  if [[ -n "$output" ]]; then
    etcd_backup "$output"
  else
    etcd_backup
  fi
}
