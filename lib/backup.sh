# =============================================================================
# lib/backup.sh — milvus-backup (Zilliz official CLI) wrapper helpers
#
# We don't reimplement backup. We download the upstream `milvus-backup`
# binary, render a backup.toml from cluster.env, and invoke it.
#
#   download → cache binary in $REPO_ROOT/.local/bin/milvus-backup
#   render   → write backup.toml at $REPO_ROOT/.local/backup.toml
#   run      → ./milvus-backup --config backup.toml <subcommand>
#
# Used by cmd_create_backup and cmd_restore_backup.
# =============================================================================

[[ -n "${_BACKUP_SH_LOADED:-}" ]] && return 0
_BACKUP_SH_LOADED=1

: "${MILVUS_BACKUP_VERSION:=v0.5.14}"
: "${MILVUS_BACKUP_BIN_DIR:=$REPO_ROOT/.local/bin}"
MILVUS_BACKUP_BIN="$MILVUS_BACKUP_BIN_DIR/milvus-backup"


# Download the upstream milvus-backup binary into the cache dir if not
# already there. Idempotent — safe to call from every command.
#
# Asset URL pattern (verified against zilliztech/milvus-backup v0.5.14):
#   .../<vX.Y.Z>/milvus-backup_<X.Y.Z>_<Linux|Darwin>_<x86_64|arm64>.tar.gz
# Note the asset filename embeds the version (without leading `v`) and
# uses capitalized OS + x86_64-style arch — older releases (≤ v0.5.4)
# used a different convention that the upstream switched away from.
backup_download_binary() {
  if [[ -x "$MILVUS_BACKUP_BIN" ]]; then
    info "milvus-backup binary cached at $MILVUS_BACKUP_BIN"
    return 0
  fi

  mkdir -p "$MILVUS_BACKUP_BIN_DIR"

  local arch
  case "$(uname -m)" in
    x86_64)         arch="x86_64" ;;
    aarch64|arm64)  arch="arm64" ;;
    *)              die "unsupported arch: $(uname -m)" ;;
  esac

  local os
  case "$(uname -s)" in
    Linux)   os="Linux" ;;
    Darwin)  os="Darwin" ;;
    *)       die "unsupported OS: $(uname -s)" ;;
  esac

  local ver_clean="${MILVUS_BACKUP_VERSION#v}"
  local url="https://github.com/zilliztech/milvus-backup/releases/download/${MILVUS_BACKUP_VERSION}/milvus-backup_${ver_clean}_${os}_${arch}.tar.gz"

  info "downloading milvus-backup ${MILVUS_BACKUP_VERSION}"
  info "  $url"
  local tmp; tmp="$(mktemp -d)"
  if ! curl -sfL "$url" -o "$tmp/milvus-backup.tgz"; then
    rm -rf "$tmp"
    die "download failed — set MILVUS_BACKUP_VERSION to a known release tag (latest as of $(date +%Y-%m): v0.5.14), or download manually into $MILVUS_BACKUP_BIN"
  fi
  tar -xzf "$tmp/milvus-backup.tgz" -C "$tmp"
  install -m 0755 "$tmp/milvus-backup" "$MILVUS_BACKUP_BIN"
  rm -rf "$tmp"
  ok "milvus-backup installed → $MILVUS_BACKUP_BIN"
}


# Render backup.yaml from current cluster.env values. Points at this
# node's local Milvus + MinIO endpoints (any node works since the cluster
# is symmetric).
#
# YAML format is required by milvus-backup v0.5.x+ — earlier releases
# (<= v0.5.4) used TOML and the same content lived in backup.toml.
#
# Prints the path to the rendered file on stdout.
backup_render_config() {
  local target="${REPO_ROOT}/.local/backup.yaml"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
# milvus-backup config — auto-generated from cluster.env.
# Re-rendered every time backup_render_config is called.

log:
  level: info

milvus:
  address: ${LOCAL_IP}
  port: ${MILVUS_PORT}
  authorizationEnabled: false
  tlsMode: 0
  user: ""
  password: ""

minio:
  # MinIO speaks S3, so cloudProvider = "aws" (Milvus 2.6 dropped 'minio'
  # as a valid value; aws works for any S3-compatible store).
  cloudProvider: aws
  storageType: minio
  address: ${LOCAL_IP}
  port: ${MINIO_API_PORT}
  accessKeyID: ${MINIO_ACCESS_KEY}
  secretAccessKey: ${MINIO_SECRET_KEY}
  useSSL: false
  useIAM: false
  useVirtualHost: false
  bucketName: milvus-bucket
  rootPath: files

  # Backup destination — same MinIO, separate path.
  backupAccessKeyID: ${MINIO_ACCESS_KEY}
  backupSecretAccessKey: ${MINIO_SECRET_KEY}
  backupBucketName: milvus-bucket
  backupRootPath: backup

backup:
  maxSegmentGroupSize: 2G
  parallelism:
    backupCollection: 4
    copydata: 128
    restoreCollection: 2
  keepTempFiles: false
EOF
  echo "$target"
}


# Run milvus-backup with the rendered config, forwarding all args.
# Usage: backup_run <subcommand> [args...]
backup_run() {
  local cfg
  cfg="$(backup_render_config)"
  "$MILVUS_BACKUP_BIN" --config "$cfg" "$@"
}
