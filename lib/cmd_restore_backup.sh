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
      --from=*)                  from_path="${1#*=}"; shift ;;
      --from)                    from_path="$2"; shift 2 ;;
      --name=*)                  name="${1#*=}"; shift ;;
      --name)                    name="$2"; shift 2 ;;
      --rename=*)                rename_pairs="${1#*=}"; shift ;;
      --rename)                  rename_pairs="$2"; shift 2 ;;
      --milvus-backup-version=*) MILVUS_BACKUP_VERSION="${1#*=}"; export MILVUS_BACKUP_VERSION; shift ;;
      --milvus-backup-version)   MILVUS_BACKUP_VERSION="$2"; export MILVUS_BACKUP_VERSION; shift 2 ;;
      --skip-upload)             skip_upload=1; shift ;;
      --no-restore-index)        restore_index=0; shift ;;
      --show-cached)             version_only=1; shift ;;
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
    from_path="$(cd "$from_path" && pwd)"            # canonical absolute
    [[ -z "$name" ]] && name="$(basename "$from_path")"

    info "==> uploading $from_path → MinIO at milvus-bucket/backup/$name/"
    info "    (this is the slow step for large backups)"

    # mc inside the milvus-minio container can't see host paths. Two-step:
    # docker cp host → container, then mc mirror container → MinIO.
    local container_tmp="/tmp/onprem-import-${name}-$$"
    docker exec milvus-minio mkdir -p "$container_tmp"
    if ! docker cp "${from_path}/." "milvus-minio:${container_tmp}/"; then
      docker exec milvus-minio rm -rf "$container_tmp" 2>/dev/null
      die "docker cp from host into MinIO container failed"
    fi
    if ! minio_mc mirror --quiet "${container_tmp}/" "local/milvus-bucket/backup/${name}/" >/dev/null; then
      docker exec milvus-minio rm -rf "$container_tmp" 2>/dev/null
      die "mc mirror inside MinIO container failed"
    fi
    docker exec milvus-minio rm -rf "$container_tmp" 2>/dev/null
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
                                    [--milvus-backup-version=vX.Y.Z]
                                    [--show-cached]

Import a milvus-backup snapshot into the cluster.

UPLOAD SOURCE (one of):
  --from=PATH                    Filesystem path to a backup dir created
                                 elsewhere. Mirrored into our MinIO
                                 before restore.
  --skip-upload                  The backup is already in our MinIO. Use
                                 with --name.

NAMING:
  --name=NAME                    Backup name. Required with --skip-upload.
                                 Otherwise derived from the basename of
                                 --from.
  --rename=A:B[,...]             Restore collection A as B (rename during
                                 restore).

INDEX:
  --no-restore-index             Skip index rebuild. Faster, but you must
                                 re-create indexes manually afterward.

UPSTREAM BINARY:
  --milvus-backup-version=vX.Y.Z Override the upstream milvus-backup
                                 binary version. Default: v0.5.14. Also
                                 settable via the MILVUS_BACKUP_VERSION
                                 env var. NB: the binary is cached at
                                 ~/milvus-onprem/.local/bin/milvus-backup;
                                 to switch versions, rm the cached binary
                                 first.
  --show-cached                  Print the cached binary's path + version
                                 metadata, then exit. Doesn't run a restore.

Typical 100 GB-from-developer scenario:
  scp -r dev_backup operator@node-1:~/dev_backup
  ssh operator@node-1
  cd ~/milvus-onprem
  ./milvus-onprem restore-backup --from ~/dev_backup
EOF
}
