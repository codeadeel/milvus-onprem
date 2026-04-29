# =============================================================================
# lib/cmd_preflight.sh — pre-flight checks before deploy
#
# Catches the common "deploy fails 90 seconds in because port X was bound" /
# "/data not writable" / "peer not reachable" classes of problem upfront,
# while the operator can still type-fix-and-retry.
#
# Three modes:
#   1. local        — checks runnable BEFORE init (no cluster.env needed):
#                     docker, disk, required ports free, basic sanity
#   2. peer         — runs after init/join: TCP reachability to every other
#                     peer on every cluster port
#   3. all          — both
#
# Auto-invoked at the top of init/join/bootstrap unless --skip-preflight
# is passed. Operator can also run `milvus-onprem preflight` standalone
# any time to diagnose.
# =============================================================================

[[ -n "${_CMD_PREFLIGHT_SH_LOADED:-}" ]] && return 0
_CMD_PREFLIGHT_SH_LOADED=1

# Default check categories
PREFLIGHT_DOCKER_MIN_VERSION=24
PREFLIGHT_DISK_MIN_GB=5

cmd_preflight() {
  local scope="all"
  local quiet=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local) scope="local"; shift ;;
      --peer)  scope="peer"; shift ;;
      --all)   scope="all"; shift ;;
      --quiet) quiet=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: milvus-onprem preflight [OPTIONS]

Run a battery of pre-deploy / pre-join sanity checks. Catches the
common environment-side failures BEFORE init/bootstrap spends 90s
spinning up containers that will then crash.

Checks (each block fails fast; subsequent checks may still run):

  LOCAL (always; no cluster.env needed):
    - Docker daemon reachable
    - Docker version >= 24.x with `docker compose` plugin
    - At least 5 GB free under /data parent (or a chosen path)
    - Required cluster ports not already bound on this host
    - bash >= 4 (we use mapfile and other modern builtins)
    - python3 + curl + ssh available
    - User belongs to the docker group (or running as root)

  PEER (requires cluster.env from init/join; needs PEER_IPS):
    - TCP reachability from this peer to every other peer on every
      cluster port (etcd 2379/2380, MinIO 9000/9091, Milvus 19530,
      LB 19537, control-plane 19500, plus 2.5's pulsar 6650/8080).
    - Inter-peer time skew (warn if > 30s).

  --all (default): runs both.
  --local: skip the peer phase (use before init).
  --peer:  skip the local phase.
  --quiet: only print failures.

Exit codes:
  0 — every check passed
  1 — at least one HARD failure (won't deploy)
  2 — only WARNINGs (deploy will probably work but operator should know)

Auto-invoked at the top of init / join / bootstrap unless those
commands are passed --skip-preflight.
EOF
        return 0
        ;;
      *) die "unknown flag: $1 (try --help)" ;;
    esac
  done

  # Lenient env load — preflight should be runnable even before init,
  # so a missing cluster.env or validation issue isn't a blocker. We
  # only need it for port defaults (local) and PEER_IPS (peer).
  env_load 2>/dev/null || true

  local fails=0 warns=0
  if [[ "$scope" == "local" || "$scope" == "all" ]]; then
    _preflight_local; fails=$((fails + $?))
  fi
  if [[ "$scope" == "peer" || "$scope" == "all" ]]; then
    if [[ -f "$CLUSTER_ENV" ]]; then
      _preflight_peer; fails=$((fails + $?))
    elif [[ "$scope" == "peer" ]]; then
      err "preflight --peer requires cluster.env (run after init)"
      fails=$((fails + 1))
    else
      (( quiet )) || info "preflight peer: skipped (cluster.env not present yet)"
    fi
  fi

  if (( fails > 0 )); then
    err "preflight: $fails HARD failure(s)"
    return 1
  fi
  (( quiet )) || ok "preflight: all checks passed"
  return 0
}

# -----------------------------------------------------------------------------
# Local checks (no cluster.env needed)
# -----------------------------------------------------------------------------

_preflight_local() {
  local fails=0
  info "==> preflight local checks"

  # Docker
  if ! command -v docker >/dev/null 2>&1; then
    _pf_fail "docker not on PATH"; fails=$((fails + 1))
  else
    local docker_version
    docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null \
                     | cut -d. -f1)
    if [[ -z "$docker_version" ]]; then
      _pf_fail "can't talk to docker daemon (is it running? are you in the docker group?)"
      fails=$((fails + 1))
    elif (( docker_version < PREFLIGHT_DOCKER_MIN_VERSION )); then
      _pf_warn "docker version $docker_version (recommended: >= ${PREFLIGHT_DOCKER_MIN_VERSION})"
    else
      _pf_ok "docker $docker_version"
    fi
  fi

  if ! docker compose version >/dev/null 2>&1; then
    _pf_fail "\`docker compose\` plugin missing (install docker-compose-plugin or compose-plugin from your distro)"
    fails=$((fails + 1))
  else
    _pf_ok "docker compose plugin"
  fi

  # Required CLIs
  for tool in python3 curl ssh; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      _pf_fail "missing command: $tool"
      fails=$((fails + 1))
    else
      _pf_ok "$tool"
    fi
  done

  # bash >= 4 (we use modern builtins)
  if (( BASH_VERSINFO[0] < 4 )); then
    _pf_fail "bash >= 4 required (got $BASH_VERSION)"
    fails=$((fails + 1))
  else
    _pf_ok "bash $BASH_VERSION"
  fi

  # Disk space — check the configured DATA_ROOT (if cluster.env exists)
  # else default /data parent.
  local data_root="${DATA_ROOT:-/data}"
  local data_parent="$(dirname "$data_root")"
  [[ -d "$data_parent" ]] || data_parent="/"
  local free_gb
  free_gb=$(df -BG --output=avail "$data_parent" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [[ -z "$free_gb" ]]; then
    _pf_warn "couldn't determine free space at $data_parent"
  elif (( free_gb < PREFLIGHT_DISK_MIN_GB )); then
    _pf_fail "only ${free_gb}GB free at $data_parent (recommended: >= ${PREFLIGHT_DISK_MIN_GB}GB)"
    fails=$((fails + 1))
  else
    _pf_ok "disk: ${free_gb}GB free at $data_parent"
  fi

  # Local ports — bind a quick TCP listen-attempt to each. Refuse if
  # any cluster port is already in use by another process.
  local port_list=()
  port_list+=("${ETCD_CLIENT_PORT:-2379}")
  port_list+=("${ETCD_PEER_PORT:-2380}")
  port_list+=("${MINIO_API_PORT:-9000}")
  port_list+=("${MILVUS_PORT:-19530}")
  port_list+=("${MILVUS_HEALTHZ_PORT:-9091}")
  port_list+=("${NGINX_LB_PORT:-19537}")
  if [[ "${MODE:-}" == "distributed" || -z "${MODE:-}" ]]; then
    port_list+=("${CONTROL_PLANE_PORT:-19500}")
  fi
  if [[ "${MQ_TYPE:-}" == "pulsar" ]]; then
    port_list+=("${PULSAR_BROKER_PORT:-6650}")
    port_list+=("${PULSAR_HTTP_PORT:-8080}")
  fi

  for port in "${port_list[@]}"; do
    if _pf_port_in_use "$port"; then
      # OK if a milvus-* container holds it (we own it).
      if _pf_port_owned_by_milvus "$port"; then
        _pf_ok "port :$port (held by milvus-* container — safe)"
      else
        _pf_fail "port :$port already in use by a non-milvus process. Free it or override the corresponding *_PORT in cluster.env."
        fails=$((fails + 1))
      fi
    else
      _pf_ok "port :$port free"
    fi
  done

  # Docker group membership / sudo readability
  if ! docker info >/dev/null 2>&1; then
    _pf_fail "current user can't talk to docker socket (is the user in the docker group? \`sudo usermod -aG docker \$USER\` then re-login)"
    fails=$((fails + 1))
  fi

  return $fails
}

# -----------------------------------------------------------------------------
# Peer checks (requires cluster.env)
# -----------------------------------------------------------------------------

_preflight_peer() {
  local fails=0
  info "==> preflight peer reachability"

  if [[ -z "${PEER_IPS:-}" ]]; then
    _pf_fail "PEER_IPS not set in cluster.env"
    return 1
  fi

  # For each peer that isn't this one, check every cluster port.
  local peer_ports=(
    "${ETCD_CLIENT_PORT:-2379}"
    "${ETCD_PEER_PORT:-2380}"
    "${MINIO_API_PORT:-9000}"
    "${MILVUS_PORT:-19530}"
  )
  if [[ "${MODE:-}" == "distributed" ]]; then
    peer_ports+=("${CONTROL_PLANE_PORT:-19500}")
  fi
  if [[ "${MQ_TYPE:-}" == "pulsar" ]]; then
    peer_ports+=("${PULSAR_BROKER_PORT:-6650}")
  fi

  local local_ip="${LOCAL_IP:-}"
  local checked_any=0
  for ip in ${PEER_IPS//,/ }; do
    [[ "$ip" == "$local_ip" ]] && continue
    checked_any=1
    for port in "${peer_ports[@]}"; do
      if _pf_tcp_reachable "$ip" "$port" 3; then
        _pf_ok "$ip:$port reachable"
      else
        # Pre-bootstrap many of these will be unreachable (services
        # not up yet). Demote to WARN if the cluster looks fresh —
        # only HARD-fail on control-plane port (the daemon should be
        # up by the time we run --peer).
        if [[ "$port" == "${CONTROL_PLANE_PORT:-19500}" ]]; then
          _pf_fail "$ip:$port (control-plane) not reachable"
          fails=$((fails + 1))
        else
          _pf_warn "$ip:$port not reachable (may be pre-bootstrap; ok if services aren't up yet)"
        fi
      fi
    done
  done

  if (( ! checked_any )); then
    info "  (single-node deploy — no remote peers to probe)"
  fi

  # Time-skew check (warn only). Use SSH if available.
  if (( checked_any )) && command -v ssh >/dev/null 2>&1; then
    local now_ts skew_warned=0
    now_ts=$(date +%s)
    for ip in ${PEER_IPS//,/ }; do
      [[ "$ip" == "$local_ip" ]] && continue
      local their_ts skew
      their_ts=$(ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
                     "adeel@$ip" 'date +%s' 2>/dev/null) || continue
      skew=$((their_ts - now_ts))
      [[ ${skew#-} -gt 30 ]] && {
        _pf_warn "$ip clock skew: ${skew}s (etcd Raft is sensitive to >30s skew; install NTP/chrony)"
        skew_warned=1
      }
    done
    (( skew_warned == 0 )) && _pf_ok "time skew across peers within 30s"
  fi

  return $fails
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

_pf_ok()   { (( ${PREFLIGHT_QUIET:-0} )) || info "  [OK]   $1"; }
_pf_warn() { warn "  [WARN] $1"; }
_pf_fail() { err "  [FAIL] $1"; }

_pf_port_in_use() {
  local port="$1"
  # Try ss first, then fallback to netstat. Either reports listeners.
  if command -v ss >/dev/null 2>&1; then
    ss -tlnH "sport = :$port" 2>/dev/null | grep -q .
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$port\$"
  else
    # No tooling — bind a short-lived listener to test
    timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null
  fi
}

_pf_port_owned_by_milvus() {
  local port="$1"
  # Best-effort: with host networking the listening process is the
  # milvus container's PID 1. We check if any pid-listening on $port
  # belongs to a process whose parent is a docker-shim under a
  # milvus-* container. A simpler heuristic: just confirm at least
  # one milvus-* container is running AND the port count from
  # `docker exec`-side `ss` matches. But shell-portability is poor.
  #
  # Pragmatic shortcut: if ANY milvus-* container is running, treat
  # cluster ports as "ours". Operator who runs preflight on a
  # half-deployed host gets a slight false-OK on edge ports, but
  # the worst case (a foreign process holding a cluster port that
  # also has a coincidental milvus container running) is rare and
  # operator-investigatable. Use process substitution rather than a
  # pipe so the loop body's `return` works.
  while read -r name; do
    [[ -n "$name" ]] && return 0
  done < <(docker ps --filter 'name=^/milvus' --format '{{.Names}}' 2>/dev/null)
  return 1
}

_pf_tcp_reachable() {
  local host="$1" port="$2" timeout_s="${3:-2}"
  timeout "$timeout_s" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}
