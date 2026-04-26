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
  local strategy=""   # let milvus-backup pick its default unless user overrides

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name=*)                 name="${1#*=}"; shift ;;
      --name)                   name="$2"; shift 2 ;;
      --collections=*)          collections="${1#*=}"; shift ;;
      --collections)            collections="$2"; shift 2 ;;
      --milvus-backup-version=*) MILVUS_BACKUP_VERSION="${1#*=}"; export MILVUS_BACKUP_VERSION; shift ;;
      --milvus-backup-version)   MILVUS_BACKUP_VERSION="$2"; export MILVUS_BACKUP_VERSION; shift 2 ;;
      --strategy=*)             strategy="${1#*=}"; shift ;;
      --strategy)               strategy="$2"; shift 2 ;;
      --list)                   list_only=1; shift ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem create-backup --name=NAME [OPTIONS]
       milvus-onprem create-backup --list

Create a milvus-backup snapshot of the live cluster's data.

  --name=NAME                    (required) Backup name. Stored in MinIO under
                                 milvus-bucket/backup/<name>/.
  --collections=A,B,C            Comma-separated list of collections. Default: all.
  --strategy=STRATEGY            How to handle in-flight data. One of:
                                   bulk_flush     flush everything before backup (default)
                                   serial_flush   flush each collection one at a time
                                   skip_flush     backup what's already flushed; data
                                                  still in the WAL is NOT in the backup
                                   meta_only      schema + indexes, no segment data
                                 Use skip_flush when Pulsar is down on a 2.5 cluster
                                 (Woodpecker on 2.6 doesn't have this concern).
  --milvus-backup-version=vX.Y.Z Override the upstream milvus-backup binary
                                 version. Default: v0.5.14. Also settable via
                                 the MILVUS_BACKUP_VERSION env var.
                                 NB: the binary is cached at
                                 ~/milvus-onprem/.local/bin/milvus-backup;
                                 to switch versions, rm the cached binary first.
  --list                         List existing backups instead of creating one.

After creation, the backup lives in MinIO and can be:
  - listed:    milvus-onprem create-backup --list
  - restored:  milvus-onprem restore-backup --skip-upload --name=<name>
  - exported:  milvus-onprem export-backup --name=<name> --to=<path>
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

  # Pulsar pre-flight (only relevant for Milvus 2.5 with MQ_TYPE=pulsar).
  # Skipped when --strategy is one of skip_flush / meta_only since those
  # don't need to flush through Pulsar.
  if [[ "${MQ_TYPE:-}" == "pulsar" && "$strategy" != "skip_flush" && "$strategy" != "meta_only" ]]; then
    if ! _pulsar_reachable; then
      err "Pulsar broker at ${PULSAR_HOST_IP}:${PULSAR_BROKER_PORT} is unreachable."
      err ""
      err "Milvus 2.5 needs Pulsar for the backup's flush step. Two ways forward:"
      err ""
      err "  1. Fix Pulsar first:"
      err "       ssh to ${PULSAR_HOST}; docker start milvus-pulsar"
      err "       (or 'milvus-onprem up' on that node)"
      err ""
      err "  2. Backup the data already on disk (whatever is still in the Pulsar"
      err "     WAL won't be included; potentially loses very recent writes):"
      err "       milvus-onprem create-backup --name=$name --strategy=skip_flush"
      err ""
      die "aborting"
    fi
  fi

  local args=(create -n "$name")
  [[ -n "$collections" ]] && args+=(--colls "$collections")
  [[ -n "$strategy"    ]] && args+=(--strategy "$strategy")

  info "==> creating backup '$name'${strategy:+ (strategy=$strategy)}"
  backup_run "${args[@]}"
  ok "backup '$name' created in milvus-bucket/backup/$name/"
}

# 0 if the Pulsar singleton's broker port is TCP-reachable. Used as a
# pre-flight before backup operations on Milvus 2.5 clusters.
_pulsar_reachable() {
  timeout 3 bash -c "</dev/tcp/${PULSAR_HOST_IP}/${PULSAR_BROKER_PORT}" 2>/dev/null
}
