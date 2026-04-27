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

**Not yet implemented in v0.** Adding a node to a running cluster
requires careful etcd member-add coordination + MinIO re-balancing.
Planned for v0.x.

For now, scale-out requires a planned migration:
1. Take a `create-backup`.
2. `teardown --full` on every node.
3. Stand up a new cluster with the larger `PEER_IPS`.
4. `restore-backup` from the snapshot.

Estimated time: hours to a day, depending on data size. Not great —
the scale-out story is the next big v0.x priority.

### Design notes for the eventual `add-node` command

Captured here so a future session can pick up without re-deriving:

**etcd path** (the easy part): `etcdctl member add node-N
--peer-urls=http://NEW_IP:2380` from any healthy peer registers the
new member. The new node then starts etcd with
`ETCD_INITIAL_CLUSTER_STATE=existing` and an `--initial-cluster` list
that *includes itself*. Existing nodes don't restart (their etcd has
its data dir; `--initial-cluster-state=new` is ignored on subsequent
boots).

**MinIO path** (the hard part): distributed MinIO takes its server
list at startup and **does not support online member addition to the
same pool**. To grow a 3-node cluster to 4, every existing MinIO has
to restart with the 4-server `MINIO_SERVER_CMD`. Two viable options:

- *Rolling restart*: stop/start MinIO on each node sequentially (one
  at a time, wait for healthcheck, move to next). Erasure coding
  tolerates one drive missing, so reads/writes degrade but don't
  fail. Implementable as a `cmd_add_node.sh` step.
- *Server-pool expansion*: `mc admin pool add` adds the new node as
  a *separate* pool. New writes go to the new pool until it equalises;
  existing data stays on the original pool. Different operational
  shape — usually not what users mean by "add a node".

**Cluster.env propagation**: every existing peer's `cluster.env`
needs `PEER_IPS` extended with the new IP. Re-render is required so
the milvus.yaml `etcd.endpoints` block picks up the new peer. nginx
LB upstream list also needs the new node. Existing milvus / nginx
containers need a restart for the rendered changes to take effect
(milvus picks up etcd endpoints on start; nginx re-reads its config
on `up -d --force-recreate nginx`).

**New-node bootstrap**: needs a variant of `pair`/`join` that flips
`ETCD_INITIAL_CLUSTER_STATE=existing` and skips the initial-bootstrap
self-checks. Cheapest path: extend `cmd_pair.sh` with `--add-node`
that emits the joiner's required env, plus `cmd_join.sh` accepting
`--existing` to set the state.

**Why this is deferred**: each of the four parts is small in isolation,
but the orchestration is hairy and the failure modes are global
(half-added node = split-brain etcd, MinIO refusing reads). It needs a
4th VM in CI to validate end-to-end before shipping. Revisit when one
is available.

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
