# =============================================================================
# lib/cmd_init.sh — first-run setup for one node.
#
# Two modes:
#   standalone   single VM, single-instance services. No control plane.
#                Backwards-compatible with the pre-control-plane deploys.
#   distributed  HA-ready. Cluster-mode services from N=1, control-plane
#                daemon, MinIO with 4 drives ready for `mc admin pool add`
#                when peers join.
#
# init writes cluster.env, runs host_prep, builds the daemon image (for
# distributed), renders templates, brings the stack up, and prints the
# CLUSTER_TOKEN + a join hint. Operator's job is just `init` then
# (for distributed) `join` from each new VM.
# =============================================================================

[[ -n "${_CMD_INIT_SH_LOADED:-}" ]] && return 0
_CMD_INIT_SH_LOADED=1

cmd_init() {
  # Flags. Most have sensible defaults; the only required input from the
  # operator is the deploy mode, which we'll prompt for if absent.
  local mode=""
  local milvus_image_tag=""
  local cluster_name="milvus-onprem"
  local minio_secret_key=""
  local cluster_token=""
  local data_root="/data"
  local local_ip=""
  local milvus_port="" lb_port="" etcd_client_port="" etcd_peer_port=""
  local minio_api_port="" control_plane_port=""
  local ha_cluster_size=""
  local overwrite=0
  local force=0
  local skip_bootstrap=0
  local skip_preflight=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode=*)                mode="${1#*=}"; shift ;;
      --mode)                  mode="$2"; shift 2 ;;
      --milvus-version=*)      milvus_image_tag="${1#*=}"; shift ;;
      --milvus-image-tag=*)    milvus_image_tag="${1#*=}"; shift ;;  # alias
      --cluster-name=*)        cluster_name="${1#*=}"; shift ;;
      --minio-secret-key=*)    minio_secret_key="${1#*=}"; shift ;;
      --cluster-token=*)       cluster_token="${1#*=}"; shift ;;
      --data-root=*)           data_root="${1#*=}"; shift ;;
      --local-ip=*)            local_ip="${1#*=}"; shift ;;
      --milvus-port=*)         milvus_port="${1#*=}"; shift ;;
      --lb-port=*)             lb_port="${1#*=}"; shift ;;
      --etcd-client-port=*)    etcd_client_port="${1#*=}"; shift ;;
      --etcd-peer-port=*)      etcd_peer_port="${1#*=}"; shift ;;
      --minio-api-port=*)      minio_api_port="${1#*=}"; shift ;;
      --control-plane-port=*)  control_plane_port="${1#*=}"; shift ;;
      --ha-cluster-size=*)     ha_cluster_size="${1#*=}"; shift ;;
      --ha-cluster-size)       ha_cluster_size="$2"; shift 2 ;;
      --overwrite)             overwrite=1; shift ;;
      --force)                 force=1; shift ;;
      --skip-bootstrap)        skip_bootstrap=1; shift ;;
      --skip-preflight)        skip_preflight=1; shift ;;
      -h|--help)               _cmd_init_help; return 0 ;;
      *) die "unknown flag: $1 (try: milvus-onprem init --help)" ;;
    esac
  done

  # Resolve the mode — flag wins; otherwise prompt; default standalone.
  mode="$(_init_resolve_mode "$mode")"

  # Pre-flight (skippable). Catches the obvious environment issues
  # (no docker, port already bound, /data not writable, etc.) BEFORE
  # we spend 90s spinning up containers that will then fail.
  if (( ! skip_preflight )); then
    MODE="$mode" cmd_preflight --local || \
      die "preflight failed — fix the issues above (or pass --skip-preflight to override)"
  fi

  # Validate cluster-name: only safe characters that won't corrupt
  # cluster.env when sourced as bash (QA finding F-B4.1: spaces in
  # the name silently produced a malformed file that errored at
  # parse time with "command not found"). Allow letters, digits,
  # underscore, hyphen, period — strict but covers all reasonable
  # cluster IDs.
  if ! [[ "$cluster_name" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    die "--cluster-name=\"$cluster_name\" must match ^[A-Za-z0-9_.-]+$ (no spaces or shell metacharacters); strict validation prevents corrupting cluster.env"
  fi

  # Refuse to clobber an existing cluster.env unless asked.
  if [[ -f "$CLUSTER_ENV" && "$overwrite" -ne 1 ]]; then
    die "cluster.env already exists at $CLUSTER_ENV — pass --overwrite to replace it (or run \`milvus-onprem teardown --full\` first)"
  fi

  # Even with --overwrite, refuse if the daemon container is running.
  # An operator who runs `init --overwrite` against a live cluster
  # silently wipes the canonical cluster.env, breaking peer auth and
  # trampling the cluster's PEER_IPS / CLUSTER_TOKEN. (QA finding
  # F-B4.3: we caught this the hard way during a QA pass.) The
  # `--force` escape hatch lets operators who genuinely want to
  # reset still do so without first running teardown.
  if [[ "$overwrite" -eq 1 && "$force" -ne 1 ]] && \
     docker ps --filter 'name=^milvus-onprem-cp$' --format '{{.Names}}' 2>/dev/null \
       | grep -q '.'; then
    die "milvus-onprem-cp is RUNNING — refusing to clobber cluster.env on a live cluster. Run \`./milvus-onprem teardown --full --force\` first, or pass \`--force\` to override (this WILL break the running cluster's daemon auth)."
  fi

  # Self-IP detection. Operator can override via --local-ip if hostname -I
  # returns something we don't want (multi-NIC hosts, VPN interfaces, etc.).
  if [[ -z "$local_ip" ]]; then
    local_ip="$(_init_detect_local_ip)" \
      || die "couldn't auto-detect local IP from \`hostname -I\`. Pass --local-ip=<ip> explicitly."
  fi

  # Pre-flight: --data-root must be on a sane path. QA finding
  # F-B4.2: pointing init at e.g. /proc/sys/kernel used to print
  # mkdir errors but continue. Hard-block on filesystems where
  # mkdir is structurally impossible (/proc, /sys, /dev). For
  # ordinary paths the parent might be / or a system dir; host_prep
  # handles `sudo mkdir -p` + `sudo chown`, so a path that's not
  # currently writable by us is fine as long as we can sudo.
  case "$data_root" in
    /proc/*|/sys/*|/dev/*)
      die "--data-root=$data_root is on a virtual filesystem ($data_root) that doesn't accept regular file/directory writes. Pick a real-storage path (default /data; alternatives /var/lib/milvus, ~/milvus-data)."
      ;;
  esac
  # Sanity: must be absolute.
  case "$data_root" in
    /*) ;;
    *) die "--data-root=$data_root must be absolute (start with '/')" ;;
  esac

  # Stale milvus-etcd session anchors from a previous deploy (the
  # singleton keys at by-dev/meta/session/{rootcoord,datacoord,...})
  # outlive their containers. A fresh init that reuses the etcd data
  # dir inherits them pointing at an old peer; the new mixcoord can't
  # claim the singletons (leases still considered held) and Milvus
  # fails every op with "find no available mixcoord". Force teardown.
  if [[ "$force" -ne 1 ]]; then
    local _stale=()
    for sub in etcd minio milvus pulsar; do
      [[ -d "$data_root/$sub" ]] && _stale+=("$data_root/$sub")
    done
    if (( ${#_stale[@]} > 0 )); then
      die "$data_root has data from a previous deploy (${_stale[*]}). Run \`./milvus-onprem teardown --data --force\` first to wipe it. (Pass \`--force\` to init to reuse the data dirs anyway — NOT recommended; stale milvus-etcd session keys break the new cluster's coordinator election.)"
    fi
  fi

  # Surviving etcd peers from a previous cluster — if any peer still has
  # this host configured at https://<this>:2380 as their etcd peer, their
  # raft processes will keep heartbeating us. A freshly-bootstrapped etcd
  # has lastIndex=1 and panics on the first heartbeat carrying commit>1
  # (`tocommit(N) is out of range [lastIndex(1)]`), then crashloops.
  # Listen briefly on the etcd-peer-port and refuse if any non-local IP
  # connects — that's a surviving peer's raft retry. Distributed only.
  if [[ "$mode" == "distributed" && "$force" -ne 1 ]]; then
    local _peer_etcd_port="${ETCD_PEER_PORT:-2380}"
    local _stale_peers _rc=0
    _stale_peers="$(_init_detect_stale_peer_heartbeats "$local_ip" "$_peer_etcd_port" 5)" || _rc=$?
    case "$_rc" in
      0) info "no surviving etcd peers detected on :$_peer_etcd_port" ;;
      2) warn "couldn't bind :$_peer_etcd_port to check for stale peer heartbeats (port busy locally — preflight should have caught this); skipping BUG-C check" ;;
      *) die "detected inbound etcd peer-protocol connections from: ${_stale_peers:-<unknown>} on :$_peer_etcd_port. Those peers still have this host configured as their etcd peer — once init brings up the new etcd, their raft heartbeats will panic it (\`tocommit out of range\`). Run \`./milvus-onprem teardown --full --force\` on each of those peers FIRST, then re-run init. (Pass \`--force\` to bypass — NOT recommended; the new etcd will crashloop within seconds.)" ;;
    esac
  fi

  # Default the Milvus image tag if not given.
  : "${milvus_image_tag:=v2.6.11}"

  # Generate secrets that need to exist on disk before bootstrap.
  local generated_secret=0 generated_token=0
  if [[ -z "$minio_secret_key" ]]; then
    minio_secret_key="$(_gen_secret_key)"
    generated_secret=1
  fi
  if [[ "$mode" == "distributed" && -z "$cluster_token" ]]; then
    cluster_token="$(_gen_secret_key 32)"  # longer for token
    generated_token=1
  fi

  # Validate --ha-cluster-size. Only meaningful for distributed mode;
  # an integer >= 2 declares the initial peer count that MinIO should
  # treat as one wide erasure-coded pool. Anything else (unset, 1, 0,
  # non-numeric) falls back to legacy per-host pools.
  if [[ -n "$ha_cluster_size" ]]; then
    [[ "$ha_cluster_size" =~ ^[0-9]+$ ]] \
      || die "--ha-cluster-size must be a positive integer (got: $ha_cluster_size)"
    (( ha_cluster_size >= 2 )) \
      || die "--ha-cluster-size must be >= 2 to enable cross-host erasure parity (got: $ha_cluster_size)"
    [[ "$mode" == "distributed" ]] \
      || die "--ha-cluster-size only applies to --mode=distributed (got --mode=$mode)"
  fi

  info "==> init: mode=$mode, node-1=$local_ip, milvus=$milvus_image_tag"
  _init_write_cluster_env \
    "$mode" "$local_ip" "$cluster_name" "$milvus_image_tag" \
    "$minio_secret_key" "$cluster_token" "$data_root" \
    "$milvus_port" "$lb_port" "$etcd_client_port" "$etcd_peer_port" \
    "$minio_api_port" "$control_plane_port" "$ha_cluster_size"
  ok "wrote $CLUSTER_ENV"

  if (( generated_secret )); then
    warn "generated MINIO_SECRET_KEY: $minio_secret_key"
  fi

  # Reload our own shell's view of the env now that cluster.env exists.
  env_load >/dev/null
  host_prep "$DATA_ROOT" "$mode"

  # Build the daemon image locally. Cheap on rebuild thanks to layer cache.
  if [[ "$mode" == "distributed" ]]; then
    _init_build_daemon_image
  fi

  if (( skip_bootstrap )); then
    ok "init complete (--skip-bootstrap). Run \`milvus-onprem bootstrap\` to start services."
    _init_print_summary "$mode" "$local_ip" "$cluster_token" "$generated_token"
    return 0
  fi

  # bootstrap = render + dc up + wait for convergence + post-up tasks.
  cmd_bootstrap

  _init_print_summary "$mode" "$local_ip" "$cluster_token" "$generated_token"
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Prompt for the deploy mode if not passed via flag. Default standalone.
_init_resolve_mode() {
  local m="$1"
  if [[ -n "$m" ]]; then
    case "$m" in
      standalone|distributed) printf '%s' "$m" ;;
      *) die "invalid --mode=$m (expected: standalone | distributed)" ;;
    esac
    return
  fi

  # Non-interactive (no TTY)? Default standalone silently.
  if [[ ! -t 0 ]]; then
    printf 'standalone'
    return
  fi

  echo ""
  echo "Deploy mode:"
  echo "  1) standalone   — single VM, single-instance services, no HA"
  echo "  2) distributed  — HA-ready: control-plane daemon, cluster-mode"
  echo "                    services, grow by running \`join\` from new VMs"
  echo ""
  local ans
  while true; do
    read -r -p "Select [1=standalone / 2=distributed] (default: 1): " ans
    case "${ans:-1}" in
      1|s|standalone)  printf 'standalone';  return ;;
      2|d|distributed) printf 'distributed'; return ;;
      *) echo "  please enter 1, 2, standalone, or distributed" ;;
    esac
  done
}

# First non-loopback IPv4 from `hostname -I`. Empty on failure.
_init_detect_local_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $i !~ /^127\./) {print $i; exit}}')"
  [[ -n "$ip" ]] || return 1
  printf '%s' "$ip"
}

# Generate a secret of the given length (default 18 bytes -> 36 hex chars).
# Hex output keeps the secret leading-dash-free, which matters for
# downstream tools (mc CLI, curl headers, etc.) that parse a leading `-`
# as a flag. Hex also avoids `=` / `+` / `/` from base64.
_gen_secret_key() {
  local bytes="${1:-18}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    head -c "$bytes" /dev/urandom | od -An -vtx1 | tr -d ' \n'
  fi
}

# Listen on the local etcd-peer-port for `duration` seconds and report
# any non-loopback / non-self source IP that initiates a TCP connection
# during that window. Used by init to detect surviving peers from a
# previous cluster whose etcd processes still consider this host their
# raft peer (BUG-C: their heartbeats will panic our fresh single-node
# etcd within seconds with `tocommit out of range`).
#
# Returns 0 (and prints nothing) when no remote connections arrive.
# Returns non-zero (and prints the comma-separated list of source IPs
# to stdout) when at least one remote peer connects. On bind failure
# (port already in use locally), returns non-zero with a synthetic
# `<bind-failed>` token so the caller can surface a clear error.
_init_detect_stale_peer_heartbeats() {
  local local_ip="$1" port="$2" duration="${3:-5}"
  python3 - "$local_ip" "$port" "$duration" <<'PYEOF'
"""Bind to :port for `duration` seconds and report remote connect-attempts.

Standalone helper invoked by lib/cmd_init.sh. Exits 0 with no output
when only loopback/self contacts the port; exits 1 with a comma-
separated list of distinct remote source IPs otherwise. On bind
failure, exits 2 with the literal token `<bind-failed>` so the bash
caller can distinguish setup errors from actual stale-peer hits.
"""
import socket, sys, time

local_ip, port, duration = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
seen = set()

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("0.0.0.0", port))
except OSError:
    sys.stdout.write("<bind-failed>")
    sys.exit(2)
s.listen(64)
s.settimeout(0.25)

deadline = time.monotonic() + duration
try:
    while time.monotonic() < deadline:
        try:
            conn, addr = s.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        src = addr[0]
        if src not in ("127.0.0.1", local_ip, "0.0.0.0"):
            seen.add(src)
        try:
            conn.close()
        except OSError:
            pass
finally:
    try:
        s.close()
    except OSError:
        pass

if seen:
    sys.stdout.write(",".join(sorted(seen)))
    sys.exit(1)
sys.exit(0)
PYEOF
}

# Build the control-plane daemon image. Always invoked; docker's layer
# cache handles the no-change case in milliseconds, but a previous
# version of this function early-returned on `image inspect` success
# which left stale code in the running container after daemon source
# edits — every code change required `docker rmi` + re-init by hand.
_init_build_daemon_image() {
  local image="${CONTROL_PLANE_IMAGE:-milvus-onprem-cp:dev}"
  info "building daemon image $image (uses docker layer cache when unchanged)"
  docker build -t "$image" "$REPO_ROOT/daemon/" \
    || die "daemon image build failed — see docker output above"
}

# Write cluster.env for both standalone and distributed modes.
_init_write_cluster_env() {
  local mode="$1" local_ip="$2" cluster_name="$3" image_tag="$4"
  local secret="$5" token="$6" data_root="$7"
  local milvus_port="$8" lb_port="$9" etcd_client="${10}" etcd_peer="${11}"
  local minio_api="${12}" cp_port="${13}" ha_cluster_size="${14}"

  {
    echo "# ============================================================================="
    echo "# milvus-onprem cluster.env"
    echo "# Generated by 'milvus-onprem init' at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Mode: $mode"
    echo "# ============================================================================="
    echo ""
    echo "# Deploy shape. Don't change post-init; teardown + re-init to switch."
    echo "MODE=$mode"
    echo ""
    echo "# Topology — comma-separated IPs and the matching etcd-side"
    echo "# names of every peer. At init we know only this node; the"
    echo "# daemon (distributed mode) keeps both lists in sync as peers"
    echo "# join via etcd. PEER_IPS and PEER_NAMES are parallel arrays —"
    echo "# they must stay the same length, in the same order, sorted by"
    echo "# node-N suffix. For standalone, both stay as a single entry."
    echo "PEER_IPS=$local_ip"
    echo "PEER_NAMES=node-1"
    echo "CLUSTER_NAME=$cluster_name"
    echo ""
    echo "# Stable per-peer values. NODE_NAME / LOCAL_IP / HOST_REPO_ROOT are"
    echo "# rewritten when this file is distributed to a joining peer."
    echo "NODE_NAME=node-1"
    echo "LOCAL_IP=$local_ip"
    echo "# Host filesystem path of this repo. Used as the bind-mount SOURCE"
    echo "# for the control-plane daemon's /repo and cluster.env mounts. This"
    echo "# must be the HOST path, not the in-container path — otherwise the"
    echo "# daemon's re-render from inside the container would substitute"
    echo "# /repo as the source and docker would silently bind empty dirs."
    echo "HOST_REPO_ROOT=$REPO_ROOT"
    echo ""
    echo "# MinIO credentials (must match across all peers)."
    echo "MINIO_ACCESS_KEY=minioadmin"
    echo "MINIO_SECRET_KEY=$secret"
    echo "MINIO_REGION=us-east-1"
    if [[ -n "$token" ]]; then
      echo ""
      echo "# Shared bearer token for the control-plane daemon. KEEP SECRET."
      echo "CLUSTER_TOKEN=$token"
    fi
    echo ""
    echo "# Container image versions. Bumping the patch (e.g. v2.6.12) is safe;"
    echo "# bumping major.minor changes which templates/<version>/ directory is used."
    echo "MILVUS_IMAGE_TAG=$image_tag"
    echo "ETCD_IMAGE_TAG=v3.5.25"
    echo "MINIO_IMAGE_TAG=RELEASE.2024-05-28T17-19-04Z"
    echo "NGINX_IMAGE_TAG=1.27-alpine"
    echo ""
    echo "# Data root — all on-disk state under here."
    echo "DATA_ROOT=$data_root"
    [[ -n "$milvus_port"  ]] && echo "MILVUS_PORT=$milvus_port"
    [[ -n "$lb_port"      ]] && echo "NGINX_LB_PORT=$lb_port"
    [[ -n "$etcd_client"  ]] && echo "ETCD_CLIENT_PORT=$etcd_client"
    [[ -n "$etcd_peer"    ]] && echo "ETCD_PEER_PORT=$etcd_peer"
    [[ -n "$minio_api"    ]] && echo "MINIO_API_PORT=$minio_api"
    [[ -n "$cp_port"      ]] && echo "CONTROL_PLANE_PORT=$cp_port"
    if [[ -n "$ha_cluster_size" ]]; then
      echo ""
      echo "# MinIO HA pool size — set at init time, frozen for the life of"
      echo "# the cluster. The first N peers form one erasure-coded pool"
      echo "# that tolerates loss of any single host. Peers joining after"
      echo "# the first N land in additional per-host pools (no cross-host"
      echo "# parity for their share of writes). Unset = legacy per-host"
      echo "# pools (no host-loss tolerance, but join-time scale-out is"
      echo "# trivially safe). See docs/FAILOVER.md."
      echo "MINIO_HA_POOL_SIZE=$ha_cluster_size"
    fi
    echo ""
    echo "# Defaults applied automatically (uncomment to override):"
    echo "# MQ_TYPE=woodpecker          # 2.6: woodpecker only.   2.5: pulsar only"
    echo "# MILVUS_HEALTHZ_PORT=9091"
    echo "# MINIO_CONSOLE_PORT=9001"
    echo "# CONTROL_PLANE_IMAGE=milvus-onprem-cp:dev"
  } > "$CLUSTER_ENV"
  chmod 600 "$CLUSTER_ENV"
}

# Final operator-facing summary. For distributed, includes the join hint
# the operator copies/pastes onto the next VM.
_init_print_summary() {
  local mode="$1" local_ip="$2" token="$3" generated_token="$4"

  echo ""
  echo "========================================================================"
  echo "  milvus-onprem $mode deploy complete"
  echo "========================================================================"
  echo ""
  echo "  Milvus:            $local_ip:${MILVUS_PORT:-19530}"
  echo "  Milvus LB:         $local_ip:${NGINX_LB_PORT:-19537}"
  echo "  MinIO API:         $local_ip:${MINIO_API_PORT:-9000}"
  if [[ "$mode" == "distributed" ]]; then
    echo "  Control plane:     $local_ip:${CONTROL_PLANE_PORT:-19500}"
    echo ""
    echo "  Cluster token:     $token"
    if (( generated_token )); then
      echo "    (auto-generated; KEEP SECRET — required to add new peers)"
    fi
    echo ""
    echo "  To add a peer, run on a fresh VM:"
    echo "      ./milvus-onprem join $local_ip:${CONTROL_PLANE_PORT:-19500} $token"
  fi
  echo ""
  echo "  Verify:            ./milvus-onprem status"
  echo "  Logs (any svc):    ./milvus-onprem logs <component> --tail=200"
  echo "  Teardown:          ./milvus-onprem teardown --full --force"
  echo "========================================================================"
}

_cmd_init_help() {
  cat <<EOF
Usage: milvus-onprem init [OPTIONS]

Initialise this node as the first peer of a new cluster.

MODE (interactive prompt if omitted):
  --mode=standalone           Single VM, single-instance services, no HA
  --mode=distributed          HA-ready: control-plane daemon, cluster-mode
                              services, grow by running 'join' from new VMs

COMMON OPTIONS:
  --milvus-version=TAG        Pinned Milvus image tag. Default: v2.6.11
  --cluster-name=NAME         Cluster identifier. Default: milvus-onprem
  --minio-secret-key=KEY      MinIO secret. Auto-generated if omitted.
  --cluster-token=KEY         Daemon bearer token. Auto-generated if omitted (distributed only).
  --data-root=PATH            On-disk state directory. Default: /data
  --local-ip=IP               This node's IP (auto-detected from hostname -I if omitted).

PORT OVERRIDES (rarely needed):
  --milvus-port=N             Default: 19530
  --lb-port=N                 Default: 19537
  --etcd-client-port=N        Default: 2379
  --etcd-peer-port=N          Default: 2380
  --minio-api-port=N          Default: 9000
  --control-plane-port=N      Default: 19500 (distributed only)

HIGH AVAILABILITY (distributed mode):
  --ha-cluster-size=N         Declare the initial peer count so MinIO renders
                              the first N peers as ONE erasure-coded pool.
                              N>=3 tolerates loss of any single host (reads
                              and writes keep working). Peers joining beyond
                              N land in per-host pools without cross-host
                              parity. Frozen at init; unset = legacy per-host
                              pools (no host-loss tolerance). See
                              docs/FAILOVER.md.

OTHER:
  --overwrite                 Replace an existing cluster.env without prompt.
                              Refused if a daemon container is running on this
                              host (would silently corrupt a live cluster).
  --force                     Companion to --overwrite — proceed even if a
                              daemon container is running. Will break the
                              running cluster's daemon auth; use only when
                              you know what you're doing.
  --skip-bootstrap            Write cluster.env + host_prep but don't start
                              services. Operator runs 'bootstrap' separately.
  -h, --help                  Show this help.
EOF
}
