# Operations

Day-2 operational tasks. For first-time deploy see [DEPLOYMENT.md](DEPLOYMENT.md).
For when things break, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Daily / regular operations

### Check cluster health

From any node:

```bash
./milvus-onprem status
./milvus-onprem wait              # blocks until convergence (good after restarts)
```

`status` shows:
- Local containers + their state (`docker ps`-style)
- Local reachability — etcd, MinIO, Milvus, nginx
- Per-peer reachability — every other node's services

All-green = healthy cluster.

### Smoke test

```bash
python3 test/smoke-test.py
```

Creates a temporary collection, inserts 1k vectors, loads with
`replica_number=2`, runs ANN + hybrid searches, drops the collection.
End-to-end validation of the data path.

If this fails after a previously-passing deploy, *something has
changed*. Check `status` and recent etcd / Milvus logs.

### Quick etcd snapshot

Cheap insurance before any risky operation (image bump, config
change, restore):

```bash
./milvus-onprem backup-etcd
# default output: /tmp/etcd-snapshot-YYYYMMDD-HHMMSS.db

./milvus-onprem backup-etcd --output=/path/to/safer/location.db
```

Snapshots are small (typically <100 MB even for sizable clusters).
Easy to keep daily backups via cron:

```cron
0 3 * * *  /home/operator/milvus-onprem/milvus-onprem backup-etcd --output=/backups/etcd-$(date +\%F).db
```

---

## Backup and restore

We wrap the official **`milvus-backup`** CLI from Zilliz. The binary is
auto-downloaded on first use into `${REPO_ROOT}/.local/bin/milvus-backup`.

### Take a backup

```bash
./milvus-onprem create-backup --name=daily-2026-04-26
# stores in MinIO at milvus-bucket/backup/daily-2026-04-26/

./milvus-onprem create-backup --name=billing-only --collections=billing,invoices
# only the named collections

./milvus-onprem create-backup --list
# list all existing backups
```

### Export a backup off-cluster

`milvus-backup` snapshots live in MinIO. To copy one to a filesystem
(e.g. for off-site archival):

```bash
docker exec milvus-minio mc cp -r \
  local/milvus-bucket/backup/daily-2026-04-26/ \
  /data/exports/daily-2026-04-26/
```

(`local` is the MinIO alias `minio_mc` sets up; the path inside the
container maps to `${DATA_ROOT}/minio` on the host.)

### Restore a backup

```bash
# from a previously-created backup still in our MinIO:
./milvus-onprem restore-backup --skip-upload --name=daily-2026-04-26 --restore_index

# from a backup that was created elsewhere and lives in a filesystem dir:
./milvus-onprem restore-backup --from=/path/to/external_backup
# this mc-mirrors the dir into our MinIO first, then restores

# rename collections during restore (avoid clobbering live data):
./milvus-onprem restore-backup --from=/path/to/dev_export \
  --rename=source_coll:imported_v1
```

Typical timing:
- 1 GB backup: a few minutes
- 100 GB backup: 30-60 minutes (mostly the upload step)

### The 100-GB-from-developer scenario

A developer hands you 100 GB of `milvus-backup` data on a laptop.
To get it into the cluster:

```bash
# on the developer's machine (or any host with the data):
scp -r ~/dev_export operator@node-1:~/

# on node-1:
cd ~/milvus-onprem
./milvus-onprem restore-backup --from=~/dev_export
```

### Useful flags for restore

```bash
# auto-load collections after restore (replica_number auto-derived from CLUSTER_SIZE):
./milvus-onprem restore-backup --from=~/dev_export --load

# overwrite existing collections (drops them first; requires pymilvus):
./milvus-onprem restore-backup --from=~/dev_export --drop-existing --load

# rename collections during restore (avoid clobbering live data):
./milvus-onprem restore-backup --from=~/dev_export --rename=src_coll:imported_v1
```

### Backup in N-node HA clusters

Backups work the **same way** on a 3/5/7-node HA cluster as they do
in standalone:

- **Run from any node.** The CLI talks to Milvus via the local LB
  (`:19537`) and to MinIO via local `:9000`. Distributed MinIO means
  any node's `:9000` serves the same content. Pick whichever node is
  most convenient — they're symmetric.
- **Backup data is itself redundant.** In distributed MinIO with N≥3
  nodes, the backup tree gets erasure-coded across all peers. Losing
  one node doesn't lose the backup. (Standalone single-drive MinIO
  has zero redundancy on its data; off-site `export-backup` is
  essential there.)
- **`--load` yields immediate read redundancy.** The auto-derived
  `replica_number` is `min(2, CLUSTER_SIZE)` — so on HA you get 2,
  meaning the restored collection is loaded onto **two QueryNodes
  on different nodes** the moment restore finishes. Either replica
  can serve queries if the other is taken out.
- **2.5 caveat: Pulsar singleton.** With Milvus 2.5, the message
  queue is a singleton on `PULSAR_HOST`. If that node is down at
  backup time, Milvus can't flush in-flight writes through it, so
  the default backup (which flushes first) fails.

  `milvus-onprem create-backup` handles this with a Pulsar
  reachability pre-flight. If Pulsar is down, the command refuses to
  start and tells you the two ways forward:

  1. Fix Pulsar first (`docker start milvus-pulsar` on `PULSAR_HOST`).
  2. Use `--strategy=skip_flush` to back up only what's already on
     disk — fast, but very recent writes still in the Pulsar WAL
     won't be included.

  See [templates/2.5/README.md](../templates/2.5/README.md#spof-caveat-the-pulsar-singleton)
  for the full SPOF discussion.

  **2.6 (Woodpecker) has no such concern** — the WAL is embedded in
  every Milvus instance, so any healthy node can flush.

### Air-gapped backup binary

`milvus-onprem create-backup` / `restore-backup` shell out to the
upstream `milvus-backup` binary. On first use the binary is downloaded
from `github.com/zilliztech/milvus-backup/releases` into
`~/milvus-onprem/.local/bin/milvus-backup`. Subsequent runs find it
cached and skip the download — no internet needed thereafter.

For air-gapped sites or restricted-egress environments, pre-place the
binary once on every node:

```bash
# on a connected machine, fetch the right asset for your target arch:
ver=v0.5.14    # or whatever MILVUS_BACKUP_VERSION you've pinned
curl -L -o /tmp/milvus-backup.tgz \
  "https://github.com/zilliztech/milvus-backup/releases/download/${ver}/milvus-backup_${ver#v}_Linux_x86_64.tar.gz"

# transfer the tarball into the air-gapped network, then on each peer:
mkdir -p ~/milvus-onprem/.local/bin
tar -xzf /path/to/milvus-backup.tgz -C ~/milvus-onprem/.local/bin/ milvus-backup
chmod +x ~/milvus-onprem/.local/bin/milvus-backup
```

Once the binary is in place, every `create-backup`/`restore-backup`
call is fully offline. The auto-fetch logic detects the cached file
via `[[ -x "$MILVUS_BACKUP_BIN" ]]` and skips the GitHub download.

A typical backup cron in HA:

```cron
# every night at 3am, take a full milvus-backup snapshot.
# distributed MinIO replicates it across nodes automatically.
0 3 * * *  /home/operator/milvus-onprem/milvus-onprem create-backup \
             --name=daily-$(date +\%F)

# weekly off-site export to /backups (assume that's an NFS mount):
0 4 * * 0  /home/operator/milvus-onprem/milvus-onprem export-backup \
             --name=daily-$(date +\%F --date='yesterday') \
             --to=/backups/milvus/weekly-$(date +\%F)
```

The wrapper handles everything: uploads to our MinIO, renders
`backup.toml` from cluster.env, runs `milvus-backup restore --restore_index`.

---

## Recovering from single-node loss

With proper N-node quorum (3+, odd), losing one node is mostly
**automatic**. etcd's Raft quorum absorbs it; MinIO's distributed mode
degrades gracefully; nginx routes around the dead Milvus.

The detail you need to know is whether your cluster is on 2.5 or 2.6:
on 2.6 a single node loss is invisible to the SDK; on 2.5 in-flight
reads briefly see `code=106 collection on recovering` until querycoord
rebalances channels (~50s untuned, ~15-20s with our tightened
templates). Full breakdown, retry-helper recipe, and tuning recipe
live in [FAILOVER.md](FAILOVER.md).

Quick recovery procedure:

1. **Don't panic.** Cluster keeps serving from `(N-1)` nodes.
2. **Retry SDK calls** that hit `code=106` — see
   [`retry_on_recovering`](../test/tutorial/_shared.py).
3. **Bring the node back**: `./milvus-onprem up`. Containers have
   `restart: always`, so `systemctl start docker` after a host reboot
   is often enough.
4. **Verify** with `./milvus-onprem status` and `wait`.
5. **Cross-peer consistency**:
   `python3 test/tutorial/05_prove_replication.py`.

If the data dir on the recovered node is **lost** (disk replaced,
node reimaged), the node needs to clear its old etcd state and rejoin
fresh. The procedure is documented under
["Replacing a permanently-lost node"](TROUBLESHOOTING.md#replacing-a-permanently-lost-node)
in TROUBLESHOOTING.md.

---

## Scale-out (add a node to an existing cluster)

The `milvus-onprem add-node` + `update-peers` + `join --existing`
trio handles online scale-out without a teardown / restore cycle.
What is automated and what is operator-coordinated:

### What's automated

- **etcd member-add.** `add-node` calls `etcdctl member add` against
  the existing cluster from any healthy peer. etcd Raft handles online
  member changes correctly — surviving peers learn via gossip; the new
  node starts with `ETCD_INITIAL_CLUSTER_STATE=existing`.
- **`cluster.env` and template propagation.** `add-node` updates the
  orchestrator's `cluster.env` and re-renders. `update-peers` does the
  same on every other existing peer. nginx is reloaded
  (non-disruptive) so its upstream list picks up the new node. The
  joiner gets the updated `cluster.env` via the existing `pair` HTTP
  rendezvous and runs `join --existing`, which sets the right etcd
  state and runs bootstrap.

### What's operator-coordinated

- **MinIO server-list change.** Distributed MinIO takes its server
  list at startup and does not support online member addition to the
  same pool. Going from N to N+1 nodes requires every existing MinIO
  to restart with the new server-list argument. The system stays
  available across the rolling restart only if you do them one at a
  time and wait for healthchecks between each — and even then, until
  the new node's MinIO is up with the same server list, the cluster
  is in a degraded state. Plan a brief MinIO maintenance window.

  The alternative is `mc admin pool add` for server-pool expansion,
  which adds the new node as a *separate* erasure-coded pool. New
  writes go to whichever pool has space; existing data stays where
  it is. Different operational shape — usually not what users mean
  by "add a node," but no MinIO downtime.

### Procedure

```mermaid
sequenceDiagram
  autonumber
  participant Op as Operator
  participant N1 as orchestrator
  participant N2 as other peers
  participant N4 as new VM

  Op->>N1: add-node --new-ip=...
  N1->>N1: etcdctl member add online; Raft accepts
  N1->>N1: cluster.env grows; PEER_IPS appends new-ip
  N1->>N1: render and nginx reload
  N1-->>Op: prints next-step instructions

  Op->>N2: update-peers --peer-ips=...
  N2->>N2: cluster.env, render, nginx reload

  Note over Op,N4: MinIO rolling restart, manual,<br/>one peer at a time
  Op->>N1: docker compose ... force-recreate minio
  Op->>N2: docker compose ... force-recreate minio

  Op->>N1: pair, token issued
  N1-->>Op: token
  Op->>N4: join orchestrator:19500 token --existing
  N4->>N1: GET /cluster.env
  N1-->>N4: cluster.env with N+1 peers
  N4->>N4: bootstrap with ETCD_INITIAL_CLUSTER_STATE=existing
  N4->>N1: etcd Raft handshake; member already registered
  N4-->>Op: bootstrap complete; new node green
```

In order, on the indicated nodes:

```bash
# 1. On any healthy existing peer (the orchestrator):
./milvus-onprem add-node --new-ip=10.0.0.13 [--new-name=node-4]
# (or: ... --dry-run to preview)

# 2. On every OTHER existing peer (not the orchestrator), with the
#    new PEER_IPS list printed by step 1:
./milvus-onprem update-peers --peer-ips=10.0.0.10,10.0.0.11,10.0.0.12,10.0.0.13

# 3. (MinIO) coordinate a rolling restart of MinIO on every existing
#    peer. On each, in sequence (wait for healthy between):
docker compose -f rendered/<node-name>/docker-compose.yml \
  up -d --force-recreate minio

# 4. On the orchestrator: serve the updated cluster.env to the new node.
./milvus-onprem pair

# 5. On the NEW VM:
./milvus-onprem join <orchestrator-ip>:19500 <token> --existing
```

### Validation status

- ✅ etcd member-add path validated against a live 3-node cluster
  (added a TEST-NET-1 192.0.2.x member, confirmed quorum held with
  3-of-4, removed cleanly).
- ✅ `add-node` end-to-end on the orchestrator side: cluster.env
  edited, templates re-rendered, nginx reloaded, no impact to running
  cluster.
- ✅ `update-peers` and `join --existing` have help text, dry-run mode,
  argument validation (refuses self-removal, refuses already-present
  IPs, requires healthy etcd).
- ⏳ End-to-end with a real 4th VM: not yet run (no spare VM today).
  When a 4th VM is available, the procedure above is the validation
  test — `add-node` on m1, `update-peers` on m2/m3, MinIO rolling
  restart, `join --existing` on m4, then `smoke` and
  `05_prove_replication.py` should pass with the new peer included.

---

## Upgrading

### Patch-level upgrades (e.g. v2.6.11 → v2.6.12)

Safe and straightforward:

```bash
# on each node:
# 1. edit cluster.env, change MILVUS_IMAGE_TAG to the new patch version
# 2. then:
./milvus-onprem render
./milvus-onprem up
```

`docker compose up` will detect the image tag changed, pull the new
image, and recreate the Milvus container with it. Per-node, takes
~30s. Run on one node at a time to keep the cluster serving throughout.

### Major-minor upgrades (e.g. v2.6.x → v2.7.x)

Requires either:
- Templates exist for the new major.minor (`templates/2.7/`) — drop
  them in, edit `MILVUS_IMAGE_TAG`, render + up. Test in a non-prod
  cluster first.
- They don't yet — community contribution opportunity.

For backwards-incompatible upgrades (Milvus has had several): plan a
migration via backup/restore. Take a `create-backup`, deploy the new
version on a new cluster, `restore-backup` there, cut over clients,
decommission the old cluster.

---

## Logging

Container logs:

```bash
docker logs --tail 200 milvus-etcd
docker logs --tail 200 milvus-minio
docker logs --tail 200 milvus
docker logs --tail 200 milvus-nginx
```

Watchdog (running as a systemd service after
`milvus-onprem install --with-watchdog`):

```bash
sudo journalctl -u milvus-watchdog -f | grep PEER_
sudo journalctl -u milvus-watchdog --since "10 minutes ago"
```

Alert format is `PEER_DOWN_ALERT` / `PEER_UP_ALERT` followed by
space-separated `key=value` pairs (`ts`, `node`, `ip`, `mode`,
`consecutive_failures`, plus `was_down_for_s` on recovery) — easy to
grep, easy to feed into a log shipper or alerting rule.

For deeper Milvus debugging, edit `templates/<version>/milvus.yaml.tpl`
and set `log.level: debug`, then `render && up`. Be prepared for a lot
of output.

---

## What to do if everything's on fire

If multiple nodes are unhealthy at once or you can't reason about the
state:

1. **Don't run failover-style commands.** With proper Raft, those
   aren't needed; running them when the cluster could self-heal makes
   it worse.
2. **Take an etcd snapshot from any reachable node:**
   `./milvus-onprem backup-etcd`. This is your insurance.
3. **Check `./milvus-onprem status` on each node.** Identify which
   components are unhealthy where.
4. **Check container logs** on the unhealthy components.
5. **If it's truly a meltdown,** the path is:
   - Capture `cluster.env` and rendered configs.
   - `teardown --full --force` on every node.
   - Redeploy from scratch.
   - `restore-backup` from your latest `milvus-backup` snapshot.

This is the worst-case path and assumes you've been making
`create-backup` snapshots regularly. If you haven't, *make daily ones
the first thing you do tomorrow*.
