# =============================================================================
# lib/cmd_export_backup.sh — copy a backup from MinIO to a filesystem dir
#
# Backups created by `milvus-onprem create-backup` live in MinIO at
# milvus-bucket/backup/<name>/. This command extracts that directory tree
# to anywhere on the host filesystem (USB stick, NFS mount, off-site
# archive, another cluster's import staging).
#
# The exported directory is self-contained — schema metadata + segment
# data + indexes all in one tree. Anyone with `milvus-onprem
# restore-backup --from=<path>` can bring it back, on any cluster.
#
# Implementation: mirror inside milvus-minio container (which has mc
# baked in), then `docker cp` to the host destination. No extra image
# pulls.
# =============================================================================

[[ -n "${_CMD_EXPORT_BACKUP_SH_LOADED:-}" ]] && return 0
_CMD_EXPORT_BACKUP_SH_LOADED=1

cmd_export_backup() {
  local name="" to_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name=*) name="${1#*=}"; shift ;;
      --name)   name="$2"; shift 2 ;;
      --to=*)   to_path="${1#*=}"; shift ;;
      --to)     to_path="$2"; shift 2 ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem export-backup --name=NAME --to=PATH

Copy a milvus-backup snapshot from MinIO to a filesystem directory.
The exported tree is fully self-contained — schema, segments, and
indexes all in one directory. Move it anywhere: USB stick, NFS mount,
off-site cold storage, or another cluster.

  --name=NAME    Backup name in MinIO (run 'milvus-onprem create-backup
                 --list' to see what exists).
  --to=PATH      Destination directory on the host. Will be created if
                 missing. Backup contents go INTO this directory
                 directly (not under a sub-dir named after the backup).

After export, the backup remains in MinIO. Free that space with:
  docker exec milvus-minio mc rm --recursive --force \\
    local/milvus-bucket/backup/NAME

Restore on any cluster (this one or another):
  milvus-onprem restore-backup --from=PATH
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  [[ -n "$name"    ]] || die "--name is required"
  [[ -n "$to_path" ]] || die "--to is required"

  env_require
  role_detect

  # Run LOCALLY regardless of mode (resolves QA finding F-A.1).
  # MinIO is distributed across all peers, so the backup contents are
  # equally accessible from any peer's local milvus-minio container.
  # Routing through /jobs would land the file on the leader's host
  # filesystem instead of the invoking peer's — which is what the
  # operator expects when they pass `--to=/tmp/foo`. By skipping
  # /jobs and doing the docker exec / docker cp here, the file lands
  # on whichever host the operator actually invoked from.
  #
  # Auth implication: this runs as the operator on the host, so they
  # already have cluster.env access and docker socket privileges
  # (same as the local-mode create-backup path). No CLUSTER_TOKEN
  # needed because nothing crosses the network.

  # Cheap pre-flight: verify the backup exists in MinIO before we start
  # creating destination dirs and running mc.
  if ! minio_mc ls "local/milvus-bucket/backup/${name}/" >/dev/null 2>&1; then
    die "backup '${name}' not found in MinIO. Run 'milvus-onprem create-backup --list' to see available backups."
  fi

  mkdir -p "$to_path"
  to_path="$(cd "$to_path" && pwd)"   # canonical absolute path

  info "==> exporting backup '${name}' from MinIO → ${to_path}"

  local container_tmp="/tmp/onprem-export-${name}-$$"

  # Mirror inside the milvus-minio container (mc is baked into the image).
  if ! minio_mc mirror --quiet \
       "local/milvus-bucket/backup/${name}/" "${container_tmp}/" >/dev/null; then
    docker exec milvus-minio rm -rf "${container_tmp}" 2>/dev/null
    die "mirror inside MinIO container failed"
  fi

  # docker cp container:src/. dest/  copies CONTENTS of src into dest
  # (rather than putting src as a subdir under dest).
  if ! docker cp "milvus-minio:${container_tmp}/." "${to_path}/"; then
    docker exec milvus-minio rm -rf "${container_tmp}" 2>/dev/null
    die "docker cp from MinIO container to host failed"
  fi

  docker exec milvus-minio rm -rf "${container_tmp}" 2>/dev/null

  ok "exported to ${to_path}/"
  info ""
  info "to restore on any cluster:"
  info "    milvus-onprem restore-backup --from=${to_path}"
  info ""
  info "to delete this backup from MinIO and free space:"
  info "    docker exec milvus-minio mc rm --recursive --force \\"
  info "      local/milvus-bucket/backup/${name}"
}

# (export-backup runs LOCALLY now — see comment in cmd_export_backup.
# Previously routed via the daemon's /jobs but the file landed on the
# leader's host filesystem, surprising operators on multi-host
# clusters. Keeping just a stub here for any external scripts that
# imported this lib by file path; harmless empty function.)
_export_backup_via_daemon() { :; }
