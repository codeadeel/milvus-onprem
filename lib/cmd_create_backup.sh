# =============================================================================
# lib/cmd_create_backup.sh — wrap `milvus-backup create`
#
# Snapshots the live cluster's Milvus data into MinIO at
# milvus-bucket/backup/<name>/. The snapshot includes collection
# schemas, segment data, and (optionally) indexes.
# =============================================================================

[[ -n "${_CMD_CREATE_BACKUP_SH_LOADED:-}" ]] && return 0
_CMD_CREATE_BACKUP_SH_LOADED=1

cmd_create_backup() {
  local name=""
  local collections=""
  local list_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name=*)        name="${1#*=}"; shift ;;
      --name)          name="$2"; shift 2 ;;
      --collections=*) collections="${1#*=}"; shift ;;
      --collections)   collections="$2"; shift 2 ;;
      --list)          list_only=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem create-backup --name=NAME [--collections=A,B,C]
       milvus-onprem create-backup --list

Create a milvus-backup snapshot of the live cluster's data.

  --name=NAME         (required) Backup name. Stored in MinIO under
                      milvus-bucket/backup/<name>/.
  --collections=...   Comma-separated list of collections. Default: all.
  --list              List existing backups instead of creating one.

After creation, the backup lives in MinIO and can be:
  - listed:    milvus-onprem create-backup --list
  - restored:  milvus-onprem restore-backup --skip-upload --name=<name>
  - exported:  docker exec milvus-minio mc cp -r \\
                 local/milvus-bucket/backup/<name>/ /path/in/container
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  env_require
  role_detect

  backup_download_binary

  if (( list_only )); then
    info "==> existing backups in milvus-bucket/backup/"
    backup_run list
    return 0
  fi

  [[ -n "$name" ]] || die "--name is required (or use --list)"

  local args=(create -n "$name")
  [[ -n "$collections" ]] && args+=(--colls "$collections")

  info "==> creating backup '$name'"
  backup_run "${args[@]}"
  ok "backup '$name' created in milvus-bucket/backup/$name/"
}
