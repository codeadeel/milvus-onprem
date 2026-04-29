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

## Round 2 — adversarial QA across 2.6 + 2.5 N=4

Drilled on 2.6 N=4 first (post Round-1 fixes), then teardown +
deploy 2.5 N=4 + drill the same matrix plus 2.5-specific paths.

### What works (validated this round)

| Category | Result |
|---|---|
| 10K-row insert + index + load + ANN top-5 (2.6 N=4) | 2.8s insert + 3.8s load + 6.8ms search |
| `remove-node --ip=` 4→3 with rolling MinIO sweep on **shrink** | 93s sequenced, 31s/peer; cluster green after; no data loss to existing collections |
| `WATCHDOG_MODE=monitor` toggle | env var passthrough lands; banner shows `mode=monitor`; on unhealthy container, daemon logs `... unhealthy for N ticks (mode=monitor; not restarting)` and does NOT call docker restart |
| 2.5 mixcoord active-standby on N=4 | All 4 coords (root/data/query/index) promoted within ~1.1s of leader-mixcoord stop. m2 took rootcoord+datacoord+indexcoord; m3 took querycoord. |
| 2.5 Pulsar SPOF (PULSAR_HOST kill) | Confirmed — pymilvus connect hangs while pulsar is down, restores when pulsar comes back. Documented limitation. |
| `secrets.compare_digest` + leader 307 redirects | Round 1 findings still hold; no regression. |

### New findings — Round 2

| ID | Severity | Symptom |
|---|---|---|
| F-A.1 | **wart** | `export-backup --to=/tmp/foo` writes to the **leader's** filesystem, not the invoking peer's. The job runs leader-only, and the bind-mounted /tmp inside the daemon is the leader's host /tmp. Operator on m1 expecting the file at m1:/tmp/foo finds it on m3 (current leader). Mitigation: document; or auto-rsync back to invoking peer. |
| F-A.2 | **wart** | `restore-backup --rename=A:B` only re-maps collection A. If the backup contains other collections (B, C, …), milvus-backup tries to restore each at its original name; if any of those names already exist in the cluster, restore fails with `collection already exist`. The CLI doesn't pass milvus-backup's `--filter` flag through, so an operator can't scope to "just A". |
| F-A.3 | **bug** | `restore-backup --drop-existing` is silently a no-op in distributed mode. The bash CLI's `_restore_drop_existing` requires pymilvus, which isn't installed in the daemon image (`ModuleNotFoundError: No module named 'pymilvus'`). The CLI skips with a `warn` that's invisible inside the daemon's log capture. The subsequent restore fails with `collection already exist`. Fix: ship pymilvus in the daemon image, or use Milvus's REST API for drop_collection. |
| F-Phase2.1 | **bug** | Three simultaneous `./milvus-onprem join` calls (parallel SSH from a script) → only the first succeeds; the others silently fail to even write `cluster.env` on the joining peer. The leader's `_join_lock` serializes correctly, but the joiner-side `curl --max-time 60` (lib/cmd_join.sh) appears to time out before the lock releases. The shell `2>&1 | tail -2 &` background pattern hides the error from the caller. **Workaround**: run joins sequentially. **Fix candidates**: bump joiner-side curl timeout to 300s; have the leader respond fast (issue an etcd-reservation upfront, do the heavy work async, return success); or have the joiner detect the timeout and retry. |
| F-Phase1.D | **wart** | Dangling docker images accumulate when the daemon image is rebuilt (e.g. during patch cycles). Saw 2 layers totaling ~672MB after a busy QA day. `docker image prune -f` handles it; could be a `milvus-onprem maintenance` subcommand that cleans dangling images and trims old job-state in etcd. |
| F-Phase1.C | **doc-gap** | `milvus-etcd` and `milvus-nginx` have NO docker healthchecks defined in either 2.5 or 2.6 templates. If the etcd or nginx process inside one of those containers crashes WITHOUT the container fully exiting (rare but possible — segfault in a thread that's caught), our watchdog can't see "unhealthy" and can't auto-restart. Fix: add TCP healthchecks for both (etcd `/dev/tcp/localhost/${ETCD_CLIENT_PORT}`, nginx `/dev/tcp/localhost/${NGINX_LB_PORT}`) — same `bash -c "echo > /dev/tcp/..."` pattern we use for 2.5 milvus-* workers. |

### Misconceptions corrected

| Earlier guess | Reality |
|---|---|
| "`docker kill` should fire `restart: always`" | False. Docker docs and observed behavior confirm: user-initiated stops/kills do NOT trigger `restart: always`. The policy fires only on unexpected exits (process crash inside container). |

## Round 3 — scale + concurrency + watchdog edges

Pushed harder still. Drilled on the live 2.5 N=4 (then N=3 after a
remove). Scope: 100K-row scale, watchdog multi-container loop-guard
behavior, concurrent backup + remove-node, upgrade-mid-failure.

### What works (validated this round)

| Area | Result |
|---|---|
| Watchdog multi-container tracking | 3 simultaneous `milvus-wd[123]` containers all unhealthy → independent COMPONENT_RESTART counters per name, independent COMPONENT_RESTART_LOOP fires (3 LOOPs at near-identical timestamps for 3 distinct containers). |
| Concurrent `create-backup` + `remove-node` | Both submitted in parallel, both completed cleanly. backup=1.98s, remove-node=5.67s. Cluster ended green at N=3. No corruption / race observed at the daemon-job level. |
| Same-version "upgrade" (rolling restart mechanics) | `upgrade --milvus-version=v2.5.4` against an already-2.5.4 cluster runs a clean rolling-restart of the per-component containers on each peer, in node-N order. ~25s/peer. |

### New findings — Round 3

| ID | Severity | Symptom |
|---|---|---|
| F-R3-A.1 | **bug (Pulsar SPOF)** | 100K-row insert in 10×10K batches → `num_entities=83373` after final flush. **17K rows lost.** Pulsar's BookKeeper bookie stalled mid-ingest (28-second BK ops, "Forcing connection to close since cannot send a pong message"); milvus's MQ consumer dropped pending messages. This is a known consequence of the singleton Pulsar SPOF on 2.5 — documented in `templates/2.5/README.md` and `docs/PULSAR_HA.md` as a write-availability concern, but the actual failure mode (silent partial data loss on bulk ingest, no exception raised) is worse than just "writes block when pulsar is down". Mitigations: (a) smaller batches (≤1K rows/batch) so MQ keeps up; (b) HA Pulsar (per docs/PULSAR_HA.md, design-only); (c) use 2.6 (Woodpecker eliminates the Pulsar dependency). |
| F-R3-B.1 | **bug** | `COMPONENT_RESTART_LOOP` was a sliding-window rate-limit, not a halt. Documented design (per `daemon/watchdog.py` class docstring) is "stops the auto-restart and emits COMPONENT_RESTART_LOOP — let the operator inspect rather than amplify a misconfigured restart pile." Actual: after the 5-min window aged out, the watchdog resumed restarts and re-fired LOOP. Drilled live: in ~13min, `milvus-wd[123]` accumulated **10 LOOP fires** across the 3 containers and never stopped retrying. **Fixed**: once `_loop_alerted` is set for a container, no more restarts. The flag clears only when the container reaches `health=healthy` (giving operators a clean re-arm path: fix the issue, restart the container manually, watchdog re-engages once healthy). |
| F-R3-D.1 | (not-a-bug) | Tried to drill upgrade-abort by killing m2's mixcoord mid-rolling-upgrade. The drill window was too narrow (small data → fast recreates) and the kill didn't land during a critical step; upgrade completed successfully. Logic-level review of `daemon/workers/version_upgrade.py` confirms abort-on-failure path exists (`raise RuntimeError(f"{peer_ip} upgrade failed: {body_json['error']}")` propagates to the job runner). Functional drill of an actual mid-upgrade abort needs a longer-running upgrade or fault injection at the `/upgrade-self` HTTP layer. Not blocking. |

### Round 3 fix shipped

| Finding | Fix | Validation |
|---|---|---|
| F-R3-B.1 loop-guard not actually halting | `daemon/watchdog.py` — once `_loop_alerted.add(name)` runs, `_maybe_restart` returns immediately without re-checking the sliding window. Flag is cleared only when the container observes `health=healthy` in `_tick`, giving the operator a clean re-arm path: fix the underlying issue, run `docker restart <name>`, watchdog sees healthy → flag clears → auto-restart re-armed for any future re-trip. | Re-drilled with the fix; only ONE LOOP fires per container per "incident", restarts genuinely halt until operator-triggered recovery. |

## Round 4 — production-readiness pass

Targeted at the user's selected list: concurrent SDK, daemon restart
during job, upgrade-mid-failure, air-gapped registry, token rotation,
multi-version coexistence, backup-format compat, F5.2 follow-up,
watchdog peer-failure threshold tuning. Plus a hard-coded-values audit
("nothing should be hard-coded; production-ready dynamic config").

### Audit: hard-coded values

Scanned `lib/`, `daemon/`, `templates/` for hard-coded ports / paths /
magic numbers. Findings:

- **Most code is already env-driven** via `env.sh`'s `:=` defaults and
  `daemon/config.py`'s pydantic `Field(default=…)`. Operator overrides
  via `cluster.env` flow through `lib/render.sh`'s envsubst list and
  the templates' `${VAR}` references.
- `127.0.0.1` literals in `lib/cmd_*.sh` and `lib/etcd.sh` /
  `lib/minio.sh`: these are loopback (talking to the local container's
  bound port), not "this host's IP" — intentional, must remain literal.
- `/etcd-data/` in `lib/etcd.sh` snapshot path: required by the etcd
  image's volume mount convention. Hard-coded but unavoidable.
- `/tmp/onprem-{import,export}-…` in restore + export backup: inside
  the milvus-minio container's filesystem, also bind-mounted to host.
  Convention-driven hard code; fine.

**Real cleanup targets (fixed in this round):**

- nginx upstream `max_fails=3 fail_timeout=30s` was hard-coded in
  `lib/render.sh`. Now configurable via `NGINX_UPSTREAM_MAX_FAILS` and
  `NGINX_UPSTREAM_FAIL_TIMEOUT_S` (defaults match prior values).
- `httpx.AsyncClient(timeout=180.0)` in `daemon/handlers.py` for the
  rolling MinIO recreate RPC was hard-coded. Now
  `MILVUS_ONPREM_ROLLING_MINIO_PEER_RPC_TIMEOUT_S`.
- `_wait_minio_healthy(timeout_s=90)` in handlers was hard-coded. Now
  `MILVUS_ONPREM_ROLLING_MINIO_HEALTHY_WAIT_S`.

All passthrough wired: `lib/env.sh` → `lib/render.sh` substitution
list → `templates/{2.5,2.6}/_daemon-service.yml.tpl` env block.

### What works (R4 validations)

| Cat | Result |
|---|---|
| **R4-A** Concurrent SDK clients | 8 threads (4 readers + 4 writers) doing 240 ops in 0.5s, 0 errors, exact final row count (5000 = 1000 seed + 4×10×100). |
| **R4-B** Token rotation | Per-peer: edit `CLUSTER_TOKEN` in cluster.env, render, recreate daemon. m1 immediately accepts NEW + rejects OLD; m2/m3 still on OLD until their cluster.env updates. After rotating all 3, all 3 accept NEW. **Caveat**: cross-peer RPCs (rolling MinIO, /upgrade-self, watchdog peer probes from ANY peer) break during the rotation window — operators must rotate in fast succession or during a maintenance window. |
| **R4-D** Watchdog threshold tuning | `WATCHDOG_PEER_FAILURE_THRESHOLD=1`: peer-down alert in 10s (vs 60s with default 6). Mechanical, behaves linearly with threshold × interval. |
| **R4-E** F5.2 heartbeat-lease (implemented + drilled) | Stuck-running jobs after leader death were the F5.2 limitation. Implemented per-job heartbeat: `Job.last_heartbeat` updated by the owner's periodic flusher every 2s; new `JobsManager.prune_stuck_running()` runs on the leader every 30s and marks running jobs `failed` if heartbeat is older than `jobs_heartbeat_timeout_s` (default 60s). **Drilled live**: submit a create-backup → kill leader's daemon mid-job → 81 seconds later, new leader's sweep marked the job `failed` with `error="owner died (heartbeat age=71s; timeout=60s) — job presumed stuck after daemon loss"`. Previously the job stayed `running` forever. |
| **R4-I** Air-gapped registry overrides | Set `MILVUS_IMAGE_REPO=internal-registry.example.com/milvus` (and 4 sibling overrides) in cluster.env → `./milvus-onprem render` → all milvus-* / etcd / minio / nginx / pulsar service blocks now reference the private registry. Render-level confirmed. (Live deploy against a real registry requires actual mirror setup — out of scope for this drill.) |

### New findings — Round 4

| ID | Severity | Symptom |
|---|---|---|
| F-R4-C.1 | **wart** | Multi-version coexistence: there's no guard preventing an operator from manually editing cluster.env on one peer to a different `MILVUS_IMAGE_TAG` than the rest of the cluster. `./milvus-onprem render` happily generates a 2.6-shaped compose for a peer in a 2.5 cluster (or vice versa). The cluster would then fail at runtime in confusing ways (etcd metadata schemas don't cross-match). The cross-major upgrade path (`./milvus-onprem upgrade`) refuses correctly, but ad-hoc cluster.env edits aren't validated against the cluster-wide consensus. Future fix: leader writes the cluster's canonical `MILVUS_IMAGE_TAG` to etcd `/cluster/version`; render checks it agrees. |
| F-R4-B.1 | **operator-care** | Token rotation works per-peer but not cluster-atomically. During the window where some peers have NEW token and others OLD, daemon-to-daemon RPCs (rolling MinIO sweep, /upgrade-self, /recreate-minio-self) fail with 403. Operator must rotate all peers in fast succession (≤ ~30s recommended) or during a quiet window. |

### Round 4 fixes shipped

| Finding | Fix |
|---|---|
| F5.2 (from R1, deferred to R4) — stuck-running jobs after leader death | Heartbeat per Job; leader-side stuck-sweep marks failed after timeout. New env vars `MILVUS_ONPREM_JOBS_HEARTBEAT_TIMEOUT_S` (60s) and `MILVUS_ONPREM_JOBS_STUCK_SWEEP_INTERVAL_S` (30s). |
| Hard-coded nginx upstream params | `NGINX_UPSTREAM_MAX_FAILS` / `NGINX_UPSTREAM_FAIL_TIMEOUT_S` env vars. |
| Hard-coded rolling MinIO timeouts in handlers.py | `MILVUS_ONPREM_ROLLING_MINIO_PEER_RPC_TIMEOUT_S` / `MILVUS_ONPREM_ROLLING_MINIO_HEALTHY_WAIT_S`. |

### R4 deferred (not drilled this round)

| Cat | Why |
|---|---|
| R4-F daemon-restart-during-peer-side-job | Pulsar-kill drill was a no-op (only PULSAR_HOST has pulsar; leader was a non-pulsar peer). The F5.2 drill exercises the related "owner dies mid-job" path; this would just be the symmetric "remote peer dies during a /upgrade-self RPC". Logic-level review confirms the leader's RPC raises on connection drop. |
| R4-G upgrade fault injection | Same-version upgrade is too fast on small data; the natural fault windows close before the kill lands. Real drill needs deliberate HTTP-layer fault injection (e.g. iptables drop on /upgrade-self responses, or a debug flag in the worker). |
| R4-H backup format compat across milvus-backup binary versions | Need multiple binary versions in cache; only `v0.5.14` is downloaded. Operator can supply `--milvus-backup-version=` on `create-backup`/`restore-backup`; the version pinning works (already env-driven via `MILVUS_BACKUP_VERSION`). Cross-version-binary compat is upstream-binary-vendor concern; out of scope. |

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
