# =============================================================================
# lib/cmd_jobs.sh — operator-facing CLI for the daemon's jobs API.
#
#   ./milvus-onprem jobs list [--state=running|done|failed|cancelled]
#   ./milvus-onprem jobs show <id>
#   ./milvus-onprem jobs cancel <id>
#
# Reads go through the local daemon (any peer's daemon — they all see the
# same etcd-backed view). Writes (cancel, post) go through the leader via
# the daemon's 307-redirect.
# =============================================================================

[[ -n "${_CMD_JOBS_SH_LOADED:-}" ]] && return 0
_CMD_JOBS_SH_LOADED=1

cmd_jobs() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list)         _cmd_jobs_list "$@" ;;
    show)         _cmd_jobs_show "$@" ;;
    cancel)       _cmd_jobs_cancel "$@" ;;
    types)        _cmd_jobs_types "$@" ;;
    -h|--help|"") _cmd_jobs_help; [[ -z "$sub" ]] && return 1 || return 0 ;;
    *) die "unknown jobs subcommand: $sub (try 'jobs --help')" ;;
  esac
}

# ----- list -----------------------------------------------------------------
_cmd_jobs_list() {
  local state=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --state=*) state="${1#*=}"; shift ;;
      --state)   state="$2"; shift 2 ;;
      -h|--help) cat <<EOF
Usage: milvus-onprem jobs list [--state=STATE]

  --state    Filter by state (pending|running|done|failed|cancelled)
EOF
        return 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  env_require
  local cp_url token
  cp_url="$(_jobs_cp_url)"
  token="$(_jobs_token)"

  local url="$cp_url/jobs"
  [[ -n "$state" ]] && url="$url?state=$state"

  curl -fsS --max-time 10 -H "Authorization: Bearer $token" "$url" \
    | python3 -c "
import json, sys, time
d = json.load(sys.stdin)
jobs = d.get('jobs', [])
if not jobs:
    print('(no jobs)')
    sys.exit(0)
print(f'{\"id\":<36}  {\"type\":<16}  {\"state\":<10}  {\"started\":<19}  duration')
for j in jobs:
    s_at = time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(j['started_at']))
    fin = j.get('finished_at')
    if fin:
        dur = f'{int(fin - j[\"started_at\"])}s'
    elif j['state'] == 'running':
        dur = f'{int(time.time() - j[\"started_at\"])}s+'
    else:
        dur = '-'
    print(f'{j[\"id\"]:<36}  {j[\"type\"]:<16}  {j[\"state\"]:<10}  {s_at:<19}  {dur}')
"
}

# ----- show -----------------------------------------------------------------
_cmd_jobs_show() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]]; then
    cat <<EOF
Usage: milvus-onprem jobs show <id>

Show full state of a single job: type, params, state, progress, error,
last 200 log lines.
EOF
    [[ -z "${1:-}" ]] && return 1 || return 0
  fi
  local jid="$1"

  env_require
  local cp_url token
  cp_url="$(_jobs_cp_url)"
  token="$(_jobs_token)"

  curl -fsS --max-time 10 -H "Authorization: Bearer $token" \
    "$cp_url/jobs/$jid" \
    | python3 -c "
import json, sys, time
d = json.load(sys.stdin)
print(f'id:          {d[\"id\"]}')
print(f'type:        {d[\"type\"]}')
print(f'state:       {d[\"state\"]}  (progress: {d[\"progress\"]:.0%})')
print(f'owner:       {d[\"owner\"]}')
print(f'started:     {time.strftime(\"%Y-%m-%dT%H:%M:%S\", time.localtime(d[\"started_at\"]))}')
if d.get('finished_at'):
    print(f'finished:    {time.strftime(\"%Y-%m-%dT%H:%M:%S\", time.localtime(d[\"finished_at\"]))}')
    print(f'duration:    {int(d[\"finished_at\"] - d[\"started_at\"])}s')
if d.get('params'):
    print(f'params:      {json.dumps(d[\"params\"])}')
if d.get('error'):
    print(f'error:       {d[\"error\"]}')
logs = d.get('logs') or []
if logs:
    print(f'--- last {len(logs)} log lines ---')
    for line in logs:
        print(line)
"
}

# ----- cancel ---------------------------------------------------------------
_cmd_jobs_cancel() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "${1:-}" ]]; then
    cat <<EOF
Usage: milvus-onprem jobs cancel <id>

Best-effort cancel. Only works while the job is running on this daemon
(or one we can reach via the leader's redirect).
EOF
    [[ -z "${1:-}" ]] && return 1 || return 0
  fi
  local jid="$1"

  env_require
  local cp_url token
  cp_url="$(_jobs_cp_url)"
  token="$(_jobs_token)"

  curl -fsS --location-trusted --max-time 10 -X POST \
    -H "Authorization: Bearer $token" \
    "$cp_url/jobs/$jid/cancel" \
    | python3 -m json.tool
}

# ----- types ----------------------------------------------------------------
_cmd_jobs_types() {
  env_require
  local cp_url token
  cp_url="$(_jobs_cp_url)"
  token="$(_jobs_token)"
  curl -fsS --max-time 5 -H "Authorization: Bearer $token" "$cp_url/jobs/types" \
    | python3 -c "
import json, sys
d = json.load(sys.stdin)
for t in d.get('types', []):
    print(t)
"
}

# ----- helpers --------------------------------------------------------------
_jobs_cp_url() {
  printf 'http://127.0.0.1:%s' "${CONTROL_PLANE_PORT:-19500}"
}

_jobs_token() {
  [[ -n "${CLUSTER_TOKEN:-}" ]] || die "CLUSTER_TOKEN missing in cluster.env"
  printf '%s' "$CLUSTER_TOKEN"
}

_cmd_jobs_help() {
  cat <<'EOF'
Usage: milvus-onprem jobs <subcommand> [args...]

Subcommands:
  list [--state=STATE]    List jobs from the cluster's etcd
  show <id>               Show one job's full state + recent logs
  cancel <id>             Cancel a running job
  types                   List registered job types

Jobs are async long-running operations (backup, restore, upgrade,
remove-node) that run on the leader daemon and persist state in etcd
so any peer can poll them.
EOF
}
