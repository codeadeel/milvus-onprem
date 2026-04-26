# =============================================================================
# lib/cmd_smoke.sh — wrap test/smoke-test.py with cluster-aware defaults
#
# Saves the user from having to type the verbose form:
#
#   REPLICAS=1 python3 test/smoke-test.py
#
# In particular, REPLICAS auto-derives from CLUSTER_SIZE so smoke "just
# works" on standalone (REPLICAS=1) and on HA (REPLICAS=min(2, N)).
# =============================================================================

[[ -n "${_CMD_SMOKE_SH_LOADED:-}" ]] && return 0
_CMD_SMOKE_SH_LOADED=1

cmd_smoke() {
  local rows="" dim="" coll=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rows=*) rows="${1#*=}"; shift ;;
      --rows)   rows="$2"; shift 2 ;;
      --dim=*)  dim="${1#*=}"; shift ;;
      --dim)    dim="$2"; shift 2 ;;
      --collection=*) coll="${1#*=}"; shift ;;
      --collection)   coll="$2"; shift 2 ;;
      -h|--help)
        cat <<EOF
Usage: milvus-onprem smoke [OPTIONS]

Run the end-to-end smoke test (creates a temp collection, inserts vectors,
loads with the right replica_number for this cluster, runs ANN + hybrid
searches, drops the collection). Replicas auto-derived from CLUSTER_SIZE:

  CLUSTER_SIZE=1   ->  replica_number=1
  CLUSTER_SIZE>=3  ->  replica_number=2

  --rows=N            Number of test vectors to insert. Default: 1000.
  --dim=N             Vector dimension. Default: 768.
  --collection=NAME   Test collection name. Default: smoke_test.

Equivalent to running test/smoke-test.py with the right env vars.
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  env_require
  role_detect
  role_validate_size

  local replicas=1
  (( CLUSTER_SIZE >= 3 )) && replicas=2

  info "==> running smoke test (CLUSTER_SIZE=$CLUSTER_SIZE -> replica_number=$replicas)"

  local script="$REPO_ROOT/test/smoke-test.py"
  [[ -f "$script" ]] || die "smoke-test.py not found at $script"

  if ! command -v python3 >/dev/null 2>&1 || \
     ! python3 -c 'import pymilvus' 2>/dev/null; then
    die "pymilvus not installed. Run: pip3 install --user --break-system-packages -r test/requirements.txt"
  fi

  # Build env vars as an array so empty optional flags don't corrupt
  # the command line. (The `${var:+...}` line-continuation form parses
  # weirdly when several optionals are simultaneously empty.)
  local -a envs=(
    "REPLICAS=$replicas"
    "MILVUS_URI=http://127.0.0.1:${NGINX_LB_PORT}"
  )
  [[ -n "$rows" ]] && envs+=("NUM_ROWS=$rows")
  [[ -n "$dim"  ]] && envs+=("DIM=$dim")
  [[ -n "$coll" ]] && envs+=("MILVUS_COLL=$coll")

  env "${envs[@]}" python3 "$script"
}
