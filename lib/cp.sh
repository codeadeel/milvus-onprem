# =============================================================================
# lib/cp.sh — control-plane HTTP helpers shared across all CLI commands
#
# Wraps the curl POST /jobs pattern with bounded redirects + exit-47
# retry. Without these guards, a curl chain following 307s through
# every peer's daemon during a leader-state-flux window (e.g.
# immediately after rotate-token recreates every peer's daemon, or
# during a leader hand-off) can hit curl's default 50-redirect cap and
# fail with `curl: (47) Maximum (50) redirects followed`. We cap at 5
# redirects (more than enough for a healthy 307 hop) and retry the
# whole call up to 3 times with backoff. By the third attempt
# leadership is almost always stable.
#
# Used by every cmd_*.sh that POSTs to /jobs.
# =============================================================================

[[ -n "${_CP_SH_LOADED:-}" ]] && return 0
_CP_SH_LOADED=1

# cp_post_job <url> <token> <body>
#
# POST `body` (JSON) to `url` with `Authorization: Bearer $token`.
# On success: prints the response body to stdout, returns 0.
# On curl exit 47 (redirect-loop): retries up to 3 times with 5s
# backoff, then errors out via die() with an actionable message.
# On other curl errors: errors out immediately.
cp_post_job() {
  local url="$1" token="$2" body="$3"
  local attempt=0 max_attempts=3
  local resp rc
  while (( attempt < max_attempts )); do
    resp=$(curl -fsS --location-trusted --max-redirs 5 --max-time 30 \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -d "$body" "$url" 2>&1)
    rc=$?
    if (( rc == 0 )); then
      printf '%s' "$resp"
      return 0
    fi
    if (( rc == 47 )); then
      attempt=$((attempt + 1))
      if (( attempt < max_attempts )); then
        warn "POST $url hit curl-47 (redirect loop) — leader state likely in flux. Retry ${attempt}/${max_attempts} in 5s..."
        sleep 5
        continue
      fi
    fi
    # Non-redirect error, OR exhausted redirect retries — give up.
    die "POST $url failed (curl rc=$rc): ${resp:-<no body>}"
  done
}
