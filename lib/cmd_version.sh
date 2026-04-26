# =============================================================================
# lib/cmd_version.sh — print version + image tag info
#
# Quick answer to "what version of milvus-onprem / Milvus / etcd / MinIO
# is this cluster running?" — useful for debugging, support, and PRs.
# =============================================================================

[[ -n "${_CMD_VERSION_SH_LOADED:-}" ]] && return 0
_CMD_VERSION_SH_LOADED=1

cmd_version() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        cat <<EOF
Usage: milvus-onprem version

Print version metadata about this CLI install + the configured cluster.
Useful when filing issues or PRs.
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  # CLI version: prefer git describe (tags first, then sha), fall back to
  # the literal "v0-alpha" if not in a git checkout.
  local cli_ver="v0-alpha"
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    cli_ver="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || echo v0-alpha)"
  fi

  echo "milvus-onprem CLI:"
  echo "  version:  $cli_ver"
  echo "  repo:     $REPO_ROOT"
  echo

  # Configured component versions — only available if cluster.env exists.
  if env_load 2>/dev/null; then
    echo "Configured cluster (from cluster.env):"
    echo "  Milvus:        $MILVUS_IMAGE_TAG  (templates/$MILVUS_VERSION/)"
    echo "  etcd:          $ETCD_IMAGE_TAG"
    echo "  MinIO:         $MINIO_IMAGE_TAG"
    echo "  nginx:         $NGINX_IMAGE_TAG"
    [[ "${MQ_TYPE:-}" == "pulsar" ]] && echo "  Pulsar:        $PULSAR_IMAGE_TAG"
    echo "  MQ_TYPE:       ${MQ_TYPE:-(unset)}"
    echo "  CLUSTER_SIZE:  $(echo "$PEER_IPS" | tr ',' '\n' | grep -c .)"
  else
    echo "Configured cluster: cluster.env not found — run \`milvus-onprem init\`."
  fi
  echo

  # Cached external binaries.
  echo "Cached binaries:"
  if [[ -x "${MILVUS_BACKUP_BIN:-}" ]]; then
    local mb_ver
    mb_ver="$("${MILVUS_BACKUP_BIN}" --help 2>&1 | head -1 | awk '{print $1}')"
    echo "  milvus-backup: ${mb_ver:-unknown}  ($MILVUS_BACKUP_BIN)"
  else
    echo "  milvus-backup: not yet downloaded"
  fi
}
