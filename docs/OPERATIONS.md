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

The wrapper handles everything: uploads to our MinIO, renders
`backup.toml` from cluster.env, runs `milvus-backup restore --restore_index`.

---

## Recovering from single-node loss

With proper N-node quorum (3+, odd), losing one node is mostly
**automatic**. etcd's Raft quorum absorbs it; MinIO's distributed mode
degrades gracefully; nginx routes around the dead Milvus.

What to do:

1. **Don't panic.** The cluster is still operating with the surviving
   `(N-1)` nodes. Verify with `./milvus-onprem status` from any
   surviving node.
2. **Investigate.** What happened to the dead node? OS crash? Disk
   failure? Network?
3. **Fix the underlying cause.** Reboot, replace disk, fix network.
4. **Bring the node back online.** Just power it on — containers
   auto-start (`restart: always`). etcd on the recovered node will
   rejoin the cluster automatically.
5. **Verify** with `./milvus-onprem status` on the recovered node.

If the data dir on the recovered node is **lost** (disk replaced,
node reimaged), the node needs to clear its old etcd state and rejoin
fresh. Currently this requires a manual `etcd member remove + member add +
re-bootstrap` procedure — see "Replacing a permanently-lost node" in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) (planned).

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

Watchdog (when running as a systemd service — planned):

```bash
sudo journalctl -u milvus-watchdog --since "10 minutes ago"
```

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
