# CLI reference

Every `./milvus-onprem` subcommand. Run `./milvus-onprem <cmd> --help`
for the same per-command information at the terminal.

## Index

| Category | Commands |
|---|---|
| **Lifecycle** | [`init`](#init) · [`render`](#render) · [`up`](#up) · [`down`](#down) · [`bootstrap`](#bootstrap) · [`status`](#status) · [`wait`](#wait) · [`teardown`](#teardown) |
| **Pre-deploy** | [`preflight`](#preflight) |
| **Multi-node** | [`join`](#join) · [`rotate-token`](#rotate-token) · [`remove-node`](#remove-node) |
| **Backup** | [`backup-etcd`](#backup-etcd) · [`create-backup`](#create-backup) · [`export-backup`](#export-backup) · [`restore-backup`](#restore-backup) |
| **Upgrade** | [`upgrade`](#upgrade) · [`maintenance`](#maintenance) |
| **Jobs** | [`jobs`](#jobs) |
| **Inspect** | [`smoke`](#smoke) · [`version`](#version) · [`urls`](#urls) · [`ps`](#ps) · [`logs`](#logs) · [`watchdog`](#watchdog) |
| **System** | [`install`](#install) · [`uninstall`](#uninstall) |

## Lifecycle

### `init`

Generate `cluster.env` on this node. Required first step.

```bash
./milvus-onprem init --mode=standalone
./milvus-onprem init --mode=distributed [--peer-ips=IP,IP,...]
./milvus-onprem init --mode=distributed --milvus-image-tag=v2.5.4
```

| Flag | Default | Notes |
|---|---|---|
| `--mode=standalone\|distributed` | required | `standalone` = single VM, no HA. `distributed` = multi-VM with control-plane daemon. |
| `--peer-ips=IP,IP,...` | (distributed only) | Optional bootstrap-time hint. Distributed mode also grows via `join`; new peers don't need to be in `--peer-ips` ahead of time. |
| `--milvus-image-tag=vX.Y.Z` | `v2.6.11` | `v2.5.x` selects the 2.5 templates. |
| `--overwrite` | off | Allow re-init when `cluster.env` already exists. |
| `--skip-preflight` | off | Skip the auto-run preflight check. |

Auto-runs `preflight --local` first unless `--skip-preflight`.

### `render`

Re-render `rendered/<node-name>/` from the current `cluster.env`.

```bash
./milvus-onprem render
```

Run after hand-editing `cluster.env`. In distributed mode the daemon
also re-renders automatically on every topology change.

### `up`

Start all containers on this node from the rendered compose.

```bash
./milvus-onprem up
```

### `down`

Stop all containers on this node. Data on disk is preserved.

```bash
./milvus-onprem down
```

### `bootstrap`

Render + `up` + `wait` + create the MinIO bucket. The "deploy
everything on this node" command. Idempotent: re-running on a healthy
cluster is a no-op.

```bash
./milvus-onprem bootstrap [--skip-preflight]
```

### `status`

Show this node's local + cluster-wide health: containers up/down,
component reachability, peer-side reachability for every other node.

```bash
./milvus-onprem status
```

### `wait`

Block until the cluster converges (all components green).

```bash
./milvus-onprem wait [--timeout-s=300]
```

### `teardown`

Stop containers and (optionally) wipe data. The escape hatch — works
even when `cluster.env` is invalid.

```bash
./milvus-onprem teardown --force          # containers only, keep data
./milvus-onprem teardown --data --force   # also wipe DATA_ROOT
./milvus-onprem teardown --full --force   # everything: containers + data + cluster.env + rendered/
```

`--force` is required for non-interactive use.

## Pre-deploy

### `preflight`

Pre-deploy / pre-join sanity check. Catches environment-side failures
before init/bootstrap spin up containers that would crash anyway.

```bash
./milvus-onprem preflight                # local + peer (default)
./milvus-onprem preflight --local        # this host only
./milvus-onprem preflight --peer         # peer reachability only
./milvus-onprem preflight --peer --peers=10.0.0.10
./milvus-onprem preflight --peer --peer-ip=10.0.0.10
```

Local checks: docker daemon reachable, docker compose plugin, disk
space, ports free, bash >= 4, python3 + curl, docker group membership.

Peer checks: TCP reachability to every peer on every cluster port
(etcd 2379/2380, MinIO 9000/9091, Milvus 19530, LB 19537, control-plane
19500, plus 2.5's pulsar 6650/8080) + inter-peer time skew via the
daemon's `/peer/clock` endpoint.

Auto-runs at the top of `init` / `join` / `bootstrap` unless
`--skip-preflight` is passed.

Exit codes: `0` all green, `1` hard failure, `2` warnings only.

## Multi-node

### `join`

On a new VM: contact a running cluster's daemon, get assigned a node
name, write cluster.env, and bootstrap. Use this for both initial
peer additions (1→3) and online scale-out (3→4, etc.).

```bash
./milvus-onprem join <peer-ip>:19500 <token>
./milvus-onprem join <peer-ip>:19500 <token> --resume
```

`<peer-ip>` is any existing peer's IP — the request 307-redirects to
the leader if you hit a follower. `<token>` is the CLUSTER_TOKEN
printed by `init` (or fetch it from any peer's cluster.env).

| Flag | Notes |
|---|---|
| `--resume` | Resume a partial join (network dropped mid-fetch, etc.). Picks up from the last completed step. |
| `--local-ip=IP` | Override the auto-detected local IP. |
| `--skip-preflight` | Skip the auto-run preflight check. |

The daemon orchestrates everything: assigns a `node-N` name, writes
the topology entry to etcd, calls etcd member-add (Raft-online),
returns a fully-baked cluster.env. The new peer writes that cluster.env,
runs `host_prep`, builds the daemon image, renders templates, and
runs bootstrap with `ETCD_INITIAL_CLUSTER_STATE=existing`. Existing
peers' daemons watch the topology change and re-render + reload nginx
+ rolling-restart MinIO automatically.

### `rotate-token`

Rotate `CLUSTER_TOKEN` atomically across every peer. Distributed mode
only.

```bash
./milvus-onprem rotate-token                    # auto-generate new token
./milvus-onprem rotate-token --new-token=<key>  # use this exact value
./milvus-onprem rotate-token --force            # skip confirmation
```

The CLI submits a `rotate-token` job; the leader fans out to every
follower in parallel via `/rotate-self`; each peer writes
`cluster.env`, re-renders, and self-recreates its control-plane
container. Daemons restart with the new token ~5s later. The CLI
verifies every peer accepts the new token before returning success.

`--new-token` must be ≥ 32 chars. If verification fails, re-run with
the same `--new-token` value to retry.

### `remove-node`

Gracefully remove a peer from the cluster: drain its MinIO pool, etcd
member-remove, topology delete. Distributed mode only.

```bash
./milvus-onprem remove-node --ip=<peer-ip>
./milvus-onprem remove-node --ip=<peer-ip> --force
```

The leaving peer's containers are still running after this command
returns. On the leaving VM, run `./milvus-onprem teardown --full
--force` to clean up local state.

Refuses to run if the cluster has only 1 peer or if the target IP is
the current leader.

## Backup

### `backup-etcd`

Snapshot the local etcd store to a `.db` file. Cheap insurance before
any risky operation.

```bash
./milvus-onprem backup-etcd
./milvus-onprem backup-etcd --output=/path/to/snapshot.db
```

Default output: `/tmp/etcd-snapshot-YYYYMMDD-HHMMSS.db`. Snapshots are
typically <100 MB.

### `create-backup`

Take a `milvus-backup` snapshot of live data. Stored in MinIO at
`milvus-bucket/backup/<name>/`.

```bash
./milvus-onprem create-backup --name=daily_2026_04_29
./milvus-onprem create-backup --name=billing_only --collections=billing,invoices
./milvus-onprem create-backup --list
```

| Flag | Notes |
|---|---|
| `--name=NAME` | Required. Alphanumerics + underscores only — `milvus-backup` rejects hyphens. |
| `--collections=A,B` | Backup only the named collections. |
| `--strategy=skip_flush` | 2.5 only. Backup what's already on disk; doesn't flush via Pulsar. Use when Pulsar is down. |
| `--list` | List existing backups. |
| `--milvus-backup-version=vX.Y.Z` | Override the upstream binary version. |

### `export-backup`

Copy a backup from MinIO to a filesystem path (USB / NFS / off-site
archival).

```bash
./milvus-onprem export-backup --name=daily_2026_04_29 --to=/path/to/export
```

Distributed mode: the export lands on the **leader's** filesystem.
Retrieve from there using whatever transport your environment
supports.

### `restore-backup`

Import a `milvus-backup` snapshot.

```bash
./milvus-onprem restore-backup --name=daily_2026_04_29
./milvus-onprem restore-backup --from=/path/to/external_backup
./milvus-onprem restore-backup --from=PATH --rename=src_coll:imported_v1
./milvus-onprem restore-backup --from=PATH --drop-existing --load
```

| Flag | Notes |
|---|---|
| `--name=NAME` | Restore from a backup currently in MinIO. |
| `--from=PATH` | Restore from a filesystem path; mc-mirrors into MinIO first. |
| `--rename=SRC:DST[,...]` | Rename collections during restore. |
| `--drop-existing` | Drop live collections of matching names first. Requires pymilvus. |
| `--load` | Auto-load collections after restore. `replica_number` derives from `CLUSTER_SIZE` (`min(2, N)`). |

## Upgrade

### `upgrade`

Roll the cluster to a new Milvus image tag, peer-by-peer. Same
major.minor only (e.g. `v2.6.11 → v2.6.12`).

```bash
./milvus-onprem upgrade --milvus-version=v2.6.12
./milvus-onprem upgrade --milvus-version=v2.6.12 --force
```

The daemon's `version-upgrade` job pulls the new image on every peer,
then rolling-restarts the milvus services peer-by-peer (leader first),
waits healthy after each, and aborts on the first failure.

For cross-major-minor upgrades (e.g. `v2.5.x → v2.6.x`), see
[OPERATIONS.md § Upgrading](OPERATIONS.md#upgrading) — the path is
backup + teardown + re-init + restore.

### `maintenance`

Operator-side hygiene actions.

```bash
./milvus-onprem maintenance --prune-images --confirm
./milvus-onprem maintenance --prune-logs --confirm
./milvus-onprem maintenance --prune-etcd-jobs --confirm
./milvus-onprem maintenance --all --confirm
./milvus-onprem maintenance --all --dry-run
```

| Flag | What |
|---|---|
| `--prune-images` | Remove dangling Docker images. |
| `--prune-logs` | Truncate per-container Docker JSON logs (one-shot reclaim; rotate at the docker daemon level for a real fix). |
| `--prune-etcd-jobs` | Trigger an immediate stuck-running + retention sweep on the leader. |
| `--all` | Every action. |
| `--dry-run` | Print the plan without doing anything. |
| `--confirm` | Required to actually run. Without it, prints the plan and exits. |

## Jobs

### `jobs`

Manage daemon-orchestrated jobs (backups, upgrades, remove-node,
rotate-token).

```bash
./milvus-onprem jobs list [--state=pending|running|done|failed|cancelled]
./milvus-onprem jobs show <job-id>
./milvus-onprem jobs cancel <job-id>
./milvus-onprem jobs types
```

## Inspect

### `smoke`

End-to-end smoke test: create a temp collection, insert 1k vectors,
load with `replica_number=2`, run ANN + hybrid searches, drop.

```bash
./milvus-onprem smoke
```

Requires `pymilvus` on the host:
`pip3 install --user --break-system-packages -r test/requirements.txt`.

### `version`

Print CLI version + configured Milvus / etcd / MinIO image tags.

```bash
./milvus-onprem version
```

### `urls`

Print connection URLs (Milvus LB, MinIO console, control-plane HTTP).

```bash
./milvus-onprem urls
```

### `ps`

`docker ps` filtered to `milvus-*` containers on this node.

```bash
./milvus-onprem ps
```

### `logs`

Tail logs for a component on this node.

```bash
./milvus-onprem logs <component> [--tail=N]
```

`<component>` is one of `etcd`, `minio`, `milvus`, `nginx`, `pulsar`,
`onprem-cp`, or any 2.5 sibling (`mixcoord`, `proxy`, `querynode`,
`datanode`, `indexnode`).

### `watchdog`

The watchdog runs inside every peer's control-plane daemon
automatically — no install step. Tail its alerts:

```bash
docker logs -f milvus-onprem-cp 2>&1 | grep -E 'PEER_(DOWN|UP)_ALERT|COMPONENT_'
```

The standalone `watchdog` subcommand is available for legacy
deployments that don't have a daemon (e.g. standalone mode); it polls
peer reachability and emits the same alert format.

## System

### `install`

Install the CLI on PATH (`/usr/local/bin/milvus-onprem`) plus bash
completion.

```bash
sudo ./milvus-onprem install
sudo ./milvus-onprem install --with-watchdog   # also install systemd unit (legacy)
```

### `uninstall`

Reverse of `install`. Does not touch cluster data — see `teardown`
for that.

```bash
sudo ./milvus-onprem uninstall
sudo ./milvus-onprem uninstall --with-watchdog
```
