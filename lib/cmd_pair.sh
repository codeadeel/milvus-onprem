# =============================================================================
# lib/cmd_pair.sh — HTTP rendezvous to distribute cluster.env to N peers
#
# Run on the bootstrap node after `init`. Starts a small Python HTTP server
# that serves cluster.env to authenticated peers (Bearer token). Exits
# automatically after (CLUSTER_SIZE - 1) successful fetches OR 10 minutes
# of idle, whichever comes first.
#
# Each peer fetches with `milvus-onprem join <bootstrap-ip>:<port> <token>`.
# =============================================================================

[[ -n "${_CMD_PAIR_SH_LOADED:-}" ]] && return 0
_CMD_PAIR_SH_LOADED=1

cmd_pair() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        cat <<EOF
Usage: milvus-onprem pair

Start the HTTP rendezvous server that distributes cluster.env to peers.
Run on the bootstrap node after \`init\`. Exits when all (CLUSTER_SIZE-1)
peers have fetched, or after 10 minutes of idle.

The pair flow:
  bootstrap-node:  milvus-onprem init --peer-ips=<all-ips>
                   milvus-onprem pair             # prints token, listens
                   (each peer joins, server exits)
                   milvus-onprem bootstrap        # render + up
  every other:     milvus-onprem join <bootstrap-ip>:<port> <token>
                   (this auto-runs bootstrap on the joining node)
EOF
        return 0
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  env_require
  role_detect
  role_validate_size

  if role_is_standalone; then
    die "pair only makes sense for multi-node clusters; CLUSTER_SIZE=1 here"
  fi

  local token expected=$((CLUSTER_SIZE - 1))
  token="$(_pair_gen_token)"

  info "==> pair server starting on ${LOCAL_IP}:${PAIR_PORT}"
  info "    token: $token"
  info "    expected fetches: $expected (one per non-bootstrap peer)"
  echo
  info "On EACH OTHER peer VM, run:"
  echo
  echo "    milvus-onprem join ${LOCAL_IP}:${PAIR_PORT} $token"
  echo
  info "Server exits after $expected fetches or 10 min idle. Ctrl-C to abort."
  echo

  _pair_server "$token" "$expected"
}

_pair_gen_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    head -c 16 /dev/urandom | xxd -p
  fi
}

_pair_server() {
  local token="$1" expected="$2"
  PYTHONUNBUFFERED=1 python3 - <<PY
import http.server, socketserver, threading, time, sys

TOKEN     = "$token"
EXPECTED  = $expected
TIMEOUT_S = 600
ENV_PATH  = "$CLUSTER_ENV"
PORT      = $PAIR_PORT

state = {"fetches": 0, "last_active": time.time()}

class Handler(http.server.BaseHTTPRequestHandler):
  def do_GET(self):
    if self.path != "/cluster.env":
      self.send_error(404); return
    auth = self.headers.get("Authorization", "")
    if auth != f"Bearer {TOKEN}":
      print(f"[pair] {self.client_address[0]} - rejected (bad token)", flush=True)
      self.send_error(403); return
    try:
      with open(ENV_PATH, "rb") as f: body = f.read()
    except Exception as e:
      self.send_error(500, str(e)); return
    self.send_response(200)
    self.send_header("Content-Type", "application/octet-stream")
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)
    state["fetches"] += 1
    state["last_active"] = time.time()
    print(f"[pair] {self.client_address[0]} - served cluster.env "
          f"({state['fetches']}/{EXPECTED})", flush=True)
  def log_message(self, fmt, *args): pass

class TS(socketserver.TCPServer):
  allow_reuse_address = True

with TS(("0.0.0.0", PORT), Handler) as srv:
  threading.Thread(target=srv.serve_forever, daemon=True).start()
  print(f"[pair] listening on 0.0.0.0:{PORT}", flush=True)
  while True:
    time.sleep(1)
    if state["fetches"] >= EXPECTED:
      print(f"[pair] all {EXPECTED} peers fetched — shutting down", flush=True)
      break
    if time.time() - state["last_active"] > TIMEOUT_S:
      print(f"[pair] {TIMEOUT_S}s idle — shutting down", flush=True)
      break
  srv.shutdown()
PY
  ok "pair complete — peers can now run their own bootstrap"
}
