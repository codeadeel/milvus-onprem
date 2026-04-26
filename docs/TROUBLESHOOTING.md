# Troubleshooting

A grab-bag of issues people have hit (or are likely to hit) during deploy
and operation. If you encounter something not listed, the systematic
debugging order is:

1. `./milvus-onprem status` — what does the cluster see?
2. `docker ps -a` — what containers are up vs down vs restarting?
3. `docker logs --tail 100 <container>` — what does the failing container say?
4. `./milvus-onprem wait --timeout-s=30` — does it converge given a moment?

For day-2 operational tasks, see [OPERATIONS.md](OPERATIONS.md).

---

## Init / pair / join issues

### `init`: `--peer-ips is required`

You ran `init` with no flags. Pass at least `--peer-ips`:

```bash
./milvus-onprem init --peer-ips=10.0.0.10,10.0.0.11,10.0.0.12
```

### `init`: `cluster.env already exists at ...`

You're trying to re-run init on a node that's already been initialised.
Either:

- You meant to use the existing config → skip init, just `bootstrap`.
- You want to start fresh → `./milvus-onprem teardown --full --force`,
  then re-run init.
- You want to overwrite without losing data → `init --overwrite`. Rare;
  usually a `teardown --full` is cleaner.

### `init`: `PEER_IPS must have 1 (standalone) or odd >=3 entries`

Even-numbered cluster sizes (2, 4, 6) are rejected — see
[ARCHITECTURE.md](ARCHITECTURE.md#why-cluster-size-must-be-1-3-5).

### `pair`: `cannot bind ...:19500: Address already in use`

Either an old `pair` server is still running, or another process has
the port.

```bash
sudo ss -tlnp | grep 19500
```

Kill the offending process. Or use a different port:

```bash
PAIR_PORT=19501 ./milvus-onprem pair
# and adjust the join command on each peer accordingly
```

### `join`: `fetch failed`

Several causes, in order of likelihood:

- **Token typo.** Tokens are 32 hex chars. Copy-paste, don't retype.
- **Pair server already exited.** It exits after `(N-1)` fetches OR
  10 minutes idle. Re-run `./milvus-onprem pair` on the bootstrap
  node to mint a fresh token.
- **Firewall blocks port 19500.** Verify reachability:
  `nc -zv <bootstrap-ip> 19500` from the joining peer.

### `join`: `fetched file doesn't look like cluster.env (missing PEER_IPS)`

The pair server served something other than a valid `cluster.env`.
Usually means the bootstrap node's `cluster.env` was edited mid-pair
(don't do that), or hand-copied incorrectly. Re-run pair from scratch
on a clean cluster.env.

### `init` / `join`: `could not match hostname -I against PEER_IPS`

This VM's IP isn't in `PEER_IPS`. Check:

```bash
hostname -I
```

If the IP shown isn't what you put in `PEER_IPS`, fix one of them.
For NAT / split-horizon setups where `hostname -I` returns something
other than the IP peers reach you on, override:

```bash
FORCE_NODE_INDEX=N ./milvus-onprem init ...
```

where N is the 1-based position of this node's IP in PEER_IPS.

---

## Bootstrap / lifecycle issues

### `bootstrap`: stays in Stage 3 with `MinIO cluster health` warnings

Distributed MinIO needs **all peers** to be reachable on `:9000`
before it forms quorum. If you've only bootstrapped some nodes,
this warning is expected — re-run `bootstrap` after every peer is up.

### `bootstrap` Stage 2: `local etcd not healthy`

etcd needs quorum to report healthy. With only one node up in a 3-node
cluster, it can't form quorum yet. Expected on the first bootstrap of
the bootstrap node. Will resolve once peers come up via `join`.

### Containers restart-loop with `panic: invalid stats config`

Known Milvus 2.6.11 panic when `milvus.yaml` is mounted as
`/milvus/configs/milvus.yaml` (replacing defaults) instead of
`/milvus/configs/user.yaml` (overlaying defaults). Confirm the
template:

```bash
grep '/milvus/configs' templates/2.6/docker-compose.yml.tpl
# should show: - ./milvus.yaml:/milvus/configs/user.yaml:ro
```

If it says `milvus.yaml:/milvus/configs/milvus.yaml`, that's the bug.

### Milvus restart-loops with `Failed to init arrow filesystem: Unsupported cloud provider: minio`

Milvus 2.6 dropped `minio` as a valid `cloudProvider` value — the
segcore filesystem only accepts `aws`/`gcp`/`azure`/`aliyun`/`tencent`.
Since MinIO speaks S3, the right value is `aws`.

```bash
grep cloudProvider templates/2.6/milvus.yaml.tpl
# should show: cloudProvider: aws
```

### Milvus restart-loops with `Failed to create etcd client: context deadline exceeded`

Milvus can't reach etcd. Check:

- **Local etcd container is up:** `docker ps -a | grep milvus-etcd`.
- **etcd has quorum:** `docker exec milvus-etcd etcdctl endpoint health`.
  If this fails, peer etcds aren't reachable — check
  `nc -zv <peer-ip> 2379` from this node.

---

## etcd issues

### `member list` times out

Linearizable reads (the default) require quorum. If quorum is missing
(more than `(N-1)/2` peers down), every etcdctl read times out — even
introspective ones like `member list`.

The fix is to restore quorum: bring more peers back up. Until quorum
returns, etcd is intentionally frozen for both reads and writes.

### Querying etcd directly returns no keys

If `etcdctl get --prefix "/by-dev/..."` returns nothing but you know
data should be there: drop the leading slash. etcd v3 keys are flat
byte strings, not paths. The Milvus prefix is `by-dev/...` (no
leading slash).

```bash
docker exec milvus-etcd etcdctl --endpoints=http://127.0.0.1:2379 \
  get --prefix "by-dev/meta/session/" --keys-only
```

---

## MinIO issues

### `mc: distributed mode requires N drives`

MinIO's distributed mode has minimum drive counts depending on the
erasure-coding parity. For 3 nodes × 1 drive = 3 drives total, MinIO
runs but with tighter parity. For larger clusters this is automatic.

If you really need lower drive counts (e.g. for testing), use
`CLUSTER_SIZE=1` (standalone, single drive, no redundancy).

### MinIO bucket creation fails: `Server not initialized, please try again`

The distributed MinIO cluster hasn't finished forming yet. Wait a
minute and retry. `bootstrap` includes a wait helper that handles
this; if you're running mc commands manually, give it 60-120s.

---

## milvus-backup issues

### `download failed — set MILVUS_BACKUP_VERSION to a known release tag`

The upstream `milvus-backup` release URL or asset name pattern
changed. Two options:

```bash
# 1. override the version (latest verified working tag is v0.5.14):
./milvus-onprem create-backup --name=foo --milvus-backup-version=v0.5.14

# 2. download manually and stash the binary in the cache dir:
curl -sL https://github.com/zilliztech/milvus-backup/releases/.../milvus-backup_X.Y.Z_Linux_x86_64.tar.gz \
  | tar -xz -C /tmp
install -m 0755 /tmp/milvus-backup ~/milvus-onprem/.local/bin/
```

The asset filename pattern as of v0.5.14 is
`milvus-backup_<X.Y.Z>_<Linux|Darwin>_<x86_64|arm64>.tar.gz` (capitalized
OS, x86_64-style arch, version embedded). If a future release breaks
this assumption again, the fix lives in `lib/backup.sh`.

### `Error: invalid backup name <name>`

milvus-backup tightened name validation in v0.5.x. Hyphens are no
longer accepted; use only alphanumerics + underscores. So `daily-backup`
fails but `daily_backup` works.

### `Unable to stat source <host-path>` during restore-backup --from

`mc` runs **inside** the milvus-minio container and can't see host
filesystem paths directly. The CLI handles this internally via
`docker cp` host → container → MinIO. If you see this error, you're
running an older version of `lib/cmd_restore_backup.sh` — pull
the latest commit.

### `restore-backup` fails with `restore: collection already exist`

milvus-backup refuses to overwrite live collections. Use:

```bash
./milvus-onprem restore-backup --from=PATH --drop-existing
```

`--drop-existing` drops every collection in the live cluster before
the restore. Requires pymilvus on the host.

### `create-backup` fails on flush (Milvus 2.5)

Milvus 2.5 needs Pulsar to flush. If the Pulsar singleton is down at
backup time, the default flush-then-backup path fails. The CLI checks
this proactively when `MQ_TYPE=pulsar`:

```
ERROR Pulsar broker at 10.0.0.10:6650 is unreachable.
```

Two ways forward:

1. Bring Pulsar back: `docker start milvus-pulsar` on the PULSAR_HOST node.
2. Skip the flush, back up what's on disk:
   `./milvus-onprem create-backup --name=foo --strategy=skip_flush`
   (Loses very recent writes still in the WAL.)

Milvus 2.6 (Woodpecker) doesn't have this concern — the WAL is
embedded in every Milvus instance.

### milvus-backup config errors / `config: backup.yaml`

milvus-backup v0.5.x uses YAML, not TOML. The CLI generates
`backup.yaml` automatically. If you're seeing a TOML-related error,
you're on an older checkout — pull the latest. The file is rendered
at `~/milvus-onprem/.local/backup.yaml` per invocation.

---

## Tutorial / smoke issues

### `smoke-test.py` hangs at `load (replica_number=2)`

The first `replica_number=2` load on a fresh cluster takes 1–3 minutes
while Milvus replicates segments to two QueryNodes. That's normal.
If it hangs >5 minutes:

- Verify both QueryNodes are registered:
  ```bash
  docker exec milvus-etcd etcdctl --endpoints=http://127.0.0.1:2379 \
    get --prefix "by-dev/meta/session/" --keys-only | grep querynode
  ```
  Should show one line per node (`querynode-1`, `querynode-2`, ...).
  Note: **no leading slash** on the prefix — etcd v3 keys are flat.
- If only one shows up, only one Milvus has registered — check
  `docker logs milvus` on the missing-node side.

### Tutorial `import-dummy.py` fails with `ModuleNotFoundError: pymilvus`

```bash
pip3 install --user --break-system-packages -r test/requirements.txt
```

---

## Networking / firewall issues

### Inter-node connectivity broken

Quick triage from one node:

```bash
for ip in 10.0.0.10 10.0.0.11 10.0.0.12; do
  for port in 2379 2380 9000 19530 19537; do
    printf "%s:%-5s — " "$ip" "$port"
    timeout 3 bash -c "</dev/tcp/$ip/$port" 2>/dev/null \
      && echo "ok" || echo "FAIL"
  done
done
```

If multiple ports fail to a single IP: that node is unreachable
(firewall, network down, VM down). If one port fails everywhere: that
service is down on every node.

### Clients connect to `:19537` but get errors

```bash
nc -zv <node-ip> 19537
```

If reachable but Milvus errors: nginx has no healthy backend. Check
each node's `docker logs --tail 50 milvus`.

---

## Cleanup / reset

If the cluster is in a state you can't reason about, the nuclear option
on every node:

```bash
./milvus-onprem teardown --full --force
```

Then redeploy from scratch ([DEPLOYMENT.md](DEPLOYMENT.md)).

You lose all data unless you've been taking `create-backup` snapshots.
Restore from those:

```bash
./milvus-onprem init --peer-ips=...
# (pair / join / bootstrap as usual)
./milvus-onprem restore-backup --from=<your-backup-dir>
```

---

## Reporting new issues

If you hit something not in this doc:

1. Capture `./milvus-onprem status` from every node.
2. Capture `docker ps -a` and `docker logs <relevant-container>`
   from the affected node(s).
3. Note your `MILVUS_IMAGE_TAG` and any non-default cluster.env values.
4. Open an issue at https://github.com/codeadeel/milvus-onprem/issues.

PRs that add new entries to this doc are very welcome — anything you
hit and figure out is something the next person would also hit.
