# =============================================================================
# lib/cmd_restore_backup.sh — wrap `milvus-backup restore` + handle upload
#
# Two upload paths:
#   1. --from=PATH   (most common) — backup data sits in a filesystem dir
#                                    on this VM. We mc-mirror it into
#                                    MinIO first, then run restore.
#   2. --skip-upload --name=NAME    — backup is already in our MinIO
#                                    (e.g. previous create-backup run).
#                                    We just run restore.
# =============================================================================

[[ -n "${_CMD_RESTORE_BACKUP_SH_LOADED:-}" ]] && return 0
_CMD_RESTORE_BACKUP_SH_LOADED=1

cmd_restore_backup() {
  local from_path=""
  local name=""
  local rename_pairs=""
  local skip_upload=0
  local restore_index=1
  local version_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from=*)            from_path="${1#*=}"; shift ;;
      --from)              from_path="$2"; shift 2 ;;
      --name=*)            name="${1#*=}"; shift ;;
      --name)              name="$2"; shift 2 ;;
      --rename=*)          rename_pairs="${1#*=}"; shift ;;
      --rename)            rename_pairs="$2"; shift 2 ;;
      --skip-upload)       skip_upload=1; shift ;;
      --no-restore-index)  restore_index=0; shift ;;
      --version)           version_only=1; shift ;;
      -h|--help)
        _restore_backup_help
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  if (( version_only )); then
    info "MILVUS_BACKUP_VERSION = $MILVUS_BACKUP_VERSION"
    info "MILVUS_BACKUP_BIN     = $MILVUS_BACKUP_BIN"
    [[ -x "$MILVUS_BACKUP_BIN" ]] && "$MILVUS_BACKUP_BIN" --help 2>/dev/null | head -1
    return 0
  fi

  env_require
  role_detect

  backup_download_binary

  # Resolve name
  if (( skip_upload )); then
    [[ -n "$name" ]] || die "--name required when --skip-upload (the data is already in MinIO)"
  else
    [[ -n "$from_path" ]] || die "--from is required (or use --skip-upload --name)"
    [[ -d "$from_path" ]] || die "$from_path does not exist or isn't a directory"
    [[ -z "$name" ]] && name="$(basename "$from_path")"

    info "==> uploading $from_path → MinIO at milvus-bucket/backup/$name/"
    info "    (this is the slow step for large backups)"
    minio_mc mirror "$from_path" "local/milvus-bucket/backup/$name/"
    ok "upload complete"
  fi

  local args=(restore -n "$name")
  (( restore_index )) && args+=(--restore_index)
  [[ -n "$rename_pairs" ]] && args+=(--rename "$rename_pairs")

  info "==> restoring '$name' (this can take 30–60 min for ~100 GB)"
  backup_run "${args[@]}"
  ok "restore complete"

  cat <<EOF

Verify with pymilvus:

  python3 - <<'PY'
  from pymilvus import MilvusClient
  c = MilvusClient(uri="http://127.0.0.1:${NGINX_LB_PORT}")
  print("collections:", c.list_collections())
  for col in c.list_collections():
      print(f"  {col}: {c.get_collection_stats(col)}")
  PY
EOF
}

_restore_backup_help() {
  cat <<EOF
Usage: milvus-onprem restore-backup [--from=PATH | --skip-upload --name=NAME]
                                    [--rename=A:B[,C:D,...]]
                                    [--no-restore-index]
                                    [--version]

Import a milvus-backup snapshot into the cluster.

UPLOAD SOURCE (one of):
  --from=PATH            Filesystem path to a backup dir created elsewhere.
                         Mirrored into our MinIO before restore.
  --skip-upload          The backup is already in our MinIO. Use with --name.

NAMING:
  --name=NAME            Backup name. Required with --skip-upload.
                         Otherwise derived from the basename of --from.
  --rename=A:B[,...]     Restore collection A as B (rename during restore).

INDEX:
  --no-restore-index     Skip index rebuild. Faster, but you must
                         re-create indexes manually afterward.

OTHER:
  --version              Print the milvus-backup binary version + path.

Typical 100 GB-from-developer scenario:
  scp -r dev_backup operator@node-1:~/dev_backup
  ssh operator@node-1
  cd ~/milvus-onprem
  ./milvus-onprem restore-backup --from ~/dev_backup
EOF
}
