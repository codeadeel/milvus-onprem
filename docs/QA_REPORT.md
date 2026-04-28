# QA report — v1.2 systematic validation

> **Status:** in progress. Started 2026-04-28 against the 2.6.11 N=4
> cluster (10.0.0.2/3/4/5). Findings categorized by severity:
> **bug** = wrong behavior, **wart** = surprising / annoying but
> works, **doc-gap** = code is right but not documented, **wishlist**
> = enhancement, not a defect.

## Categories tested

- [x] Input validation — 5 findings (1 bug, 1 doc-bug, 2 warts, 1 doc-gap)
- [x] Auth — clean (constant-time compare, all sensitive routes 401)
- [x] Idempotency — clean (init/join/bootstrap/render all idempotent or refuse cleanly)
- [x] Concurrency — 1 bug (backup-etcd race, **fixed**), 1 wart (silent 307 with empty body)
- [x] Failure recovery — leader failover clean (15s); 1 bug (stuck-running jobs after leader death — known v1.1 limitation)
- [x] State consistency — clean across cluster.env / etcd topology / nginx / live containers
- [x] Error message quality — 1 bug (heredoc backtick, **fixed**); helpful errors elsewhere
- [ ] Resource hygiene (job retention, dangling images, log volume) — deferred
- [ ] Cross-version restore (2.5 → 2.6) — earlier validated by upstream sessions
- [x] Help text + exit codes — clean after F7.1 fix

## Fixes shipped in this QA pass

| Finding | Fix | Validation |
|---|---|---|
| F4.1 backup-etcd race | `lib/etcd.sh` per-call random tag in snapshot path | 3 concurrent jobs → 3/3 done (was 2/3) |
| F1.1 jobs show traceback | `lib/cmd_jobs.sh` capture HTTP status, raise `die "no such job: …"` on 404 | `jobs show <bogus-uuid>` → `ERROR no such job: <id>` |
| F7.1 heredoc executes GNU join | `milvus-onprem` replace `` `join` `` with `'join'` | `nonsense` subcommand prints help cleanly, no spurious `join: missing operand` |
| F1.2 TUTORIAL flag wrong | `docs/TUTORIAL.md` `--name=node-4` → `--ip=10.0.0.5` | Reading the doc; matches the code's actual flag. |

## Known limitations (not fixed in this pass)

| ID | What it is | Why deferred |
|---|---|---|
| F5.2 | Stuck-running jobs after leader death | Documented in `daemon/jobs.py` as a v1.1 limitation; proper fix needs per-job heartbeat keys (medium effort). Worth doing in a follow-up. |
| F4.2 | Silent 307 on POST without `--location-trusted` | The bash CLI handles this; only affects script-callers of the HTTP API. Doc-level fix possible (loud message in 307 body); deferred. |
| F1.4 | `create-backup --name=foo-bar` surfaces raw milvus-backup error | Pre-flight regex check would help; minor. |
| F3.2 | Duplicate `create-backup --name=X` returns binary's "already exist" error | Pre-flight `mc ls` check would help; minor. |

## Findings

### Cat 1: Input validation

| ID | Severity | Component | Symptom |
|---|---|---|---|
| F1.1 | **bug** | `daemon/api.py` `GET /jobs/{id}` | `./milvus-onprem jobs show <bogus-uuid>` returns a Python `JSONDecodeError` traceback instead of a clean "no such job" message. The CLI parses the response body as JSON; on 404 the body is presumably empty / non-JSON. |
| F1.2 | **bug** | `docs/TUTORIAL.md` Phase F | Says `./milvus-onprem remove-node --name=node-4`. The actual flag (per `lib/cmd_remove_node.sh`) is `--ip=PEER_IP`. There's no `--name` flag at all. |
| F1.3 | **wart** | `milvus-onprem` dispatcher | `./milvus-onprem status --some-bogus-flag` silently runs as if the flag wasn't there. Most subcommands' arg parsers reject unknown flags; the dispatcher should too, or each command should consistently reject. |
| F1.4 | **wart** | `lib/cmd_create_backup.sh` | `--name=foo-bar` (hyphens) and `--name='qa$test'` and `--name=<300-char>` all fail with the underlying `milvus-backup` binary's "invalid backup name" error. We know about the hyphen rule from CLAUDE.md but don't pre-flight; operator hits a confusing error after the binary spins up. Pre-validate `^[a-zA-Z0-9_]{1,N}$` in the bash CLI before invoking. |
| F1.5 | **doc-gap** | `lib/cmd_upgrade.sh` `--force` | Upgrade refuses non-interactive runs without `--force` — that's right (upgrade is destructive), but the message could be friendlier and explicitly tell the operator about `--force`. |

### Cat 2: Auth

| ID | Severity | Symptom |
|---|---|---|
| F2.1 | works | `secrets.compare_digest` for token comparison; constant-time. |
| F2.2 | works | `/health`, `/version` public; all other routes 401 without bearer. |
| F2.3 | (info) | Trailing whitespace in bearer header tolerated; lowercase `bearer` accepted (RFC-compliant). |

### Cat 3: Idempotency

| ID | Severity | Symptom |
|---|---|---|
| F3.1 | works | re-run init / join / bootstrap / render — all clean idempotent (or refuse with hint). |
| F3.2 | **wart** | `create-backup --name=X` twice fails with raw milvus-backup binary error "backup with name X already exist". Could pre-flight-check via `mc ls` before running the binary. |

### Cat 4: Concurrency

| ID | Severity | Symptom |
|---|---|---|
| F4.1 | **bug** | `lib/etcd.sh:etcd_backup` uses a hardcoded `/etcd-data/snapshot.db` path. Two concurrent `backup-etcd` jobs race on the rename: one succeeds, the other fails with `Error: could not rename /etcd-data/snapshot.db.part to /etcd-data/snapshot.db (no such file or directory)`. **Drilled live**: 3 concurrent jobs → 2 done, 1 failed. Fix: per-call random-suffix filename. |
| F4.2 | **wart** | `curl -X POST .../jobs` against a follower returns 307 with empty body; without `--location-trusted` the redirect is silently un-followed and the operator sees no error. The bash CLI uses --location-trusted; HTTP-API callers must too. |
| F4.3 | works | 3 concurrent /jobs creates land 3 distinct UUIDs, no race in job-ID allocation. |

### Cat 5: Failure recovery

| ID | Severity | Symptom |
|---|---|---|
| F5.1 | works | Leader failover on `docker kill milvus-onprem-cp`: new leader elected within 15s lease TTL (drilled: 15.0s on hardware). |
| F5.2 | **bug** | When the leader is killed mid-job, the job stays in `state: running` forever in etcd. The new leader does not detect the dead owner and does not transition the job to `failed`. Documented v1.1 limitation in `daemon/jobs.py` docstring, but in practice this leaves stuck entries that confuse `jobs list`. Fix candidates: (a) per-job heartbeat key with lease, leader sweeps stale; (b) at minimum, surface a "stuck" marker in `jobs list` UI. |
| F5.3 | works | Leader-side `/join` is idempotent on duplicate IP — re-POSTing returns the existing node-N + fresh cluster_env. Drilled with m4 already in topology: returned `node_name: node-4` correctly. |

### Cat 6: State consistency

| ID | Severity | Symptom |
|---|---|---|
| F6.1 | works | After a 3→4 grow: cluster.env PEER_IPS, etcd `/cluster/topology/peers/`, every peer's nginx upstream block, and live container counts (5 milvus-* per peer on 2.6) all agree. |

### Cat 7: Error message quality + exit codes

| ID | Severity | Symptom |
|---|---|---|
| F7.1 | **bug** | The dispatcher's `usage()` heredoc has an unquoted backtick: `` `join` `` on line 55, which makes bash run the GNU coreutils `join` command on every help invocation. Visible as `join: missing operand` printed to stderr whenever `--help` or an unknown command runs. **Fixed** in this QA pass — replaced backticks with `'…'`. |
| F7.2 | works | Missing-required-arg errors are clean: `--ip is required`, `--name is required`, `--milvus-version is required (e.g. --milvus-version=v2.5.5)`. |
| F7.3 | works | Exit codes consistent: `status` rc=0; unknown subcommand rc=1; failed backup-name validation rc=1. |
