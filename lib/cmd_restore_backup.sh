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
  local auto_load=0
  local drop_existing=0

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
      --drop-existing)           drop_existing=1; shift ;;
      --load)                    auto_load=1; shift ;;
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

  # Distributed mode: route via the daemon's /jobs (recursion-guarded).
  # Restore needs the backup data physically present on the daemon-host
  # at $from_path — that's the same host the bash command executes on
  # in standalone mode, so for v1.1 we keep the same model: operator
  # places the export tree on whichever node they run the command from.
  if [[ "${MODE:-standalone}" == "distributed" \
        && "${MILVUS_ONPREM_INTERNAL:-}" != "1" ]]; then
    _restore_backup_via_daemon \
      "$from_path" "$name" "$skip_upload" "$restore_index" \
      "$drop_existing" "$auto_load" "$rename_pairs"
    return $?
  fi

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

  # If --drop-existing, drop any collection in Milvus that's about to be
  # restored. Without this, milvus-backup refuses with
  # "collection already exist". Uses pymilvus when available; warns
  # otherwise (and the restore will likely fail with the upstream error).
  if (( drop_existing )); then
    _restore_drop_existing
  fi

  # milvus-backup v0.5.x renamed --restore_index → --rebuild_index. Use
  # the new flag name; the upstream binary on older versions still
  # accepts --restore_index as a deprecated alias, but we should track
  # the canonical name.
  local args=(restore -n "$name")
  (( restore_index )) && args+=(--rebuild_index)
  [[ -n "$rename_pairs" ]] && args+=(--rename "$rename_pairs")

  info "==> restoring '$name' (this can take 30–60 min for ~100 GB)"
  backup_run "${args[@]}"
  ok "restore complete"

  if (( auto_load )); then
    _restore_auto_load
  else
    info ""
    info "Note: collections are restored but NOT loaded into QueryNode RAM."
    info "Pass --load to auto-load after restore, or call load_collection() yourself."
  fi

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

# Drop every collection that exists in the live cluster. Used by --drop-existing
# so a restore can overwrite collections without milvus-backup refusing.
# Uses pymilvus when available; warns otherwise.
_restore_drop_existing() {
  if ! command -v python3 >/dev/null 2>&1 || \
     ! python3 -c 'import pymilvus' 2>/dev/null; then
    warn "pymilvus not installed — cannot --drop-existing automatically"
    info "install with: pip3 install --user --break-system-packages pymilvus"
    info "or drop manually before retrying restore-backup"
    return 0
  fi

  info "==> --drop-existing: clearing collections in the live cluster"
  python3 - <<PY
from pymilvus import MilvusClient
c = MilvusClient(uri="http://127.0.0.1:${NGINX_LB_PORT}")
cols = c.list_collections()
if not cols:
    print("  (no collections to drop)")
else:
    for col in cols:
        print(f"  dropping {col}...")
        c.drop_collection(col)
    print(f"  dropped {len(cols)} collection(s)")
PY
}


# Auto-load every collection that's currently NotLoaded, with replica_number
# chosen based on cluster size. Uses pymilvus if available; falls back to
# clear instructions if not.
_restore_auto_load() {
  if ! command -v python3 >/dev/null 2>&1 || \
     ! python3 -c 'import pymilvus' 2>/dev/null; then
    warn "pymilvus not installed — skipping --load"
    info "to install: pip3 install --user --break-system-packages pymilvus"
    info "to load manually after install:"
    info "  python3 -c 'from pymilvus import MilvusClient; c=MilvusClient(uri=\"http://127.0.0.1:${NGINX_LB_PORT}\")'"
    info "                              .'.load_collection(\"<NAME>\", replica_number=1)'"
    return 0
  fi

  local replicas=1
  (( CLUSTER_SIZE >= 3 )) && replicas=2

  info "==> loading restored collections (replica_number=$replicas)"
  python3 - <<PY
import sys, time
from pymilvus import MilvusClient

URI = "http://127.0.0.1:${NGINX_LB_PORT}"
REPLICAS = ${replicas}

c = MilvusClient(uri=URI)
cols = c.list_collections()
if not cols:
    print("  (no collections — nothing to load)")
    sys.exit(0)

for col in cols:
    state = c.get_load_state(col).get("state")
    if str(state) == "Loaded" or (hasattr(state, 'name') and state.name == 'Loaded'):
        print(f"  {col}: already loaded — skipping")
        continue
    print(f"  loading {col} (replica_number={REPLICAS})...", flush=True)
    t0 = time.time()
    c.load_collection(col, replica_number=REPLICAS)
    print(f"    done in {time.time()-t0:.1f}s — {c.get_load_state(col)}")

print(f"  loaded {len(cols)} collection(s); ready to query")
PY
  ok "auto-load complete"
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

OVERWRITE:
  --drop-existing                Drop every collection in the live cluster
                                 before restore. Without this flag,
                                 milvus-backup refuses with "collection
                                 already exist" if a target collection is
                                 already there. Requires pymilvus.

POST-RESTORE:
  --load                         After restore, automatically load every
                                 collection into QueryNode RAM with
                                 replica_number=min(2, CLUSTER_SIZE).
                                 Without this flag, collections come back
                                 in NotLoad state and you must call
                                 load_collection() yourself before queries
                                 work. Requires pymilvus on the host.

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

# POST a restore-backup job to the local daemon and poll until done.
# Maps the bash flags onto the worker's params dict.
_restore_backup_via_daemon() {
  local from_path="$1" name="$2" skip_upload="$3" restore_index="$4"
  local drop_existing="$5" auto_load="$6" rename_pairs="${7:-}"
  local cp_url="http://127.0.0.1:${CONTROL_PLANE_PORT:-19500}"
  local token="${CLUSTER_TOKEN:-}"
  [[ -n "$token" ]] || die "CLUSTER_TOKEN missing in cluster.env"

  local body
  body=$(python3 -c "
import json
p = {}
if '''$from_path''':    p['from']   = '''$from_path'''
if '''$name''':         p['name']   = '''$name'''
if '''$rename_pairs''': p['rename'] = '''$rename_pairs'''
if int('''$skip_upload''' or '0'):  p['name'] = p.get('name')  # no-op flag carried in 'name' alone
if int('''$drop_existing''' or '0'): p['drop_existing'] = True
if int('''$auto_load''' or '0'):     p['load']           = True
if int('''$restore_index''' or '0') == 0:
    p['no_restore_index'] = True
print(json.dumps({'type':'restore-backup','params':p}))
")
  info "==> POST /jobs (restore-backup) on $cp_url"
  local resp
  resp=$(curl -fsS --location-trusted --max-time 30 \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -d "$body" "$cp_url/jobs") \
    || die "POST /jobs failed — daemon unreachable?"
  local job_id
  job_id=$(printf '%s' "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  ok "job created: $job_id"
  _poll_job "$job_id" "$cp_url" "$token"
}
