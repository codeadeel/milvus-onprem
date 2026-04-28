# milvus-onprem

**High-availability Milvus 2.5 / 2.6 across N Linux VMs — no Kubernetes required.**

> **Status: v1.2** — hardware-validated end-to-end on a 4-VM cluster
> for both Milvus 2.6.11 and 2.5.4 (smoke + tutorial + replication-proof
> + backup pipeline + scale-out + watchdog + failover drills). See
> [docs/TUTORIAL.md](docs/TUTORIAL.md) for the walked-through guide.

## The problem

Milvus today gives you two deployment options and a gap between them:

- **Standalone** — single host, single binary. Easy to deploy, no HA at all.
- **Kubernetes Operator / Helm chart** — proper HA, but requires a
  Kubernetes cluster, an Operator install, cert-manager, and (on
  OpenShift) a tangle of SCC bindings.

Many on-prem environments — banks, government, defense, telcos —
have a fleet of plain Linux VMs and no Kubernetes. The official path
asks them to either run a single host (no HA) or stand up Kubernetes
(huge undertaking). `milvus-onprem` is the missing rung.

## What it is

```mermaid
flowchart LR
  C[pymilvus client]

  subgraph node1["node-1"]
    N1[nginx :19537] --> M1[Milvus]
    D1[control-plane :19500]
    M1 --> E1[(etcd)]
    M1 --> S1[(MinIO drive)]
  end
  subgraph node2["node-2"]
    N2[nginx :19537] --> M2[Milvus]
    D2[control-plane :19500]
    M2 --> E2[(etcd)]
    M2 --> S2[(MinIO drive)]
  end
  subgraph nodeN["node-N"]
    NN[nginx :19537] --> MN[Milvus]
    DN[control-plane :19500]
    MN --> EN[(etcd)]
    MN --> SN[(MinIO drive)]
  end

  C --> N1
  C --> N2
  C --> NN

  E1 <-->|Raft| E2
  E2 <-->|Raft| EN
  E1 <-->|Raft| EN
  S1 <-.->|erasure coding| S2
  S2 <-.->|erasure coding| SN
  S1 <-.->|erasure coding| SN
  D1 <-->|leader election| D2
  D2 <-->|leader election| DN
  D1 <-->|leader election| DN
```

A CLI plus modular bash plus a small Python control-plane daemon that
deploys a redundant Milvus 2.5 / 2.6 cluster across plain Linux VMs
(1, 3, 5, 7, 9). Components per node (2.6 path):

- **etcd** — joins an N-node Raft cluster. Tolerates `(N-1)/2` failures.
- **MinIO** — distributed mode, erasure-coded across all peers.
- **Milvus 2.6** with embedded **Woodpecker** WAL. No separate Pulsar /
  Kafka cluster.
- **nginx** — TCP load balancer in front of all peer Milvus instances.
- **control-plane daemon** — leader-elected (etcd lease), owns
  `/join`, jobs (backup / restore / upgrade / remove-node), watchdog
  (auto-restart unhealthy local containers, alert on peer-down),
  topology fan-out (auto re-render + nginx reload + rolling MinIO).

(Milvus 2.5 adds 4 more milvus-* containers per node and a Pulsar
broker on PULSAR_HOST — see [templates/2.5/README.md](templates/2.5/README.md).)

## Quick start (3-node HA, Milvus 2.6)

```mermaid
flowchart LR
  A[clone repo<br/>on every node] --> B[node-1: <code>init --mode=distributed</code>]
  B --> C[node-2: <code>join · token</code>]
  B --> D[node-3: <code>join · token</code>]
  C --> E[<code>status · all green</code>]
  D --> E
```

```bash
# on every node — one-time setup:
git clone https://github.com/codeadeel/milvus-onprem.git ~/milvus-onprem
cd ~/milvus-onprem

# on node-1 (the bootstrap node):
./milvus-onprem init --mode=distributed --milvus-version=v2.6.11
# prints CLUSTER_TOKEN; copy the `./milvus-onprem join …` line it shows

# on each other node:
./milvus-onprem join 10.0.0.10:19500 <CLUSTER_TOKEN>
# fetches cluster.env from the leader, runs bootstrap with state=existing

# verify (from any node):
./milvus-onprem status        # all green = ready
./milvus-onprem smoke         # 1000-row functional test
```

That's a working 3-node Milvus cluster. Clients connect to any node's
`:19537`.

**Want a fourth node later?** Run the same `join` on m4. The daemon
handles etcd member-add, topology fan-out, rolling MinIO recreate,
and nginx reload automatically — no `add-node`, no `update-peers`.

Optional — drop the CLI on PATH so you can call it from any directory:

```bash
./milvus-onprem install        # /usr/local/bin/milvus-onprem + bash completion
# or, per-user without sudo:
./milvus-onprem install --prefix=$HOME/.local/bin --completion-dir=$HOME/.bash_completion.d
```

For the **full walkthrough with hardware-validated outputs**, see
[docs/TUTORIAL.md](docs/TUTORIAL.md). For deeper deploy topology
notes, [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).

## What you get

- **One CLI**, ~20 commands covering the full lifecycle: deploy
  (`init` / `pair` / `join` / `bootstrap`), day-2 (`status` / `wait` /
  `up` / `down` / `ps` / `logs` / `urls` / `version` / `smoke`), backup
  (`create-backup` / `export-backup` / `restore-backup` / `backup-etcd`),
  scale-out (`add-node` / `update-peers`), version upgrades
  (`upgrade --milvus-version=…`), node removal (`remove-node`), job
  inspection (`jobs list/show/cancel`), system install / uninstall,
  and `teardown`.
- **N-node from day 1** — 1 (standalone), 3, 5, 7, 9. Even sizes are
  rejected (no Raft quorum).
- **Auto-failover for single-VM loss** — etcd Raft handles it, no
  operator intervention needed if you have proper quorum.
- **Online scale-out** — `add-node` adds a new peer to a running
  cluster (etcd member-add + cluster.env propagation +
  `join --existing`). MinIO server-list change is operator-coordinated
  rolling restart; the rest is automated.
- **Built-in watchdog** — runs inside the control-plane daemon (no
  extra install step). Auto-restarts unhealthy local `milvus-*`
  containers (loop-guarded so a stuck container doesn't get hammered)
  and emits structured `PEER_DOWN_ALERT` / `PEER_UP_ALERT` /
  `COMPONENT_RESTART` / `COMPONENT_RESTART_LOOP` lines greppable from
  `docker logs milvus-onprem-cp`. See [docs/CONFIG.md § Watchdog](docs/CONFIG.md#watchdog).
- **Multi-version Milvus** — ships templates for 2.6.x (default,
  Woodpecker WAL) and 2.5.x (coord-mode-cluster + Pulsar singleton).
  Switch by changing `MILVUS_IMAGE_TAG` in cluster.env. Future versions
  = drop in `templates/X.Y/`.
- **Backup integration** — wraps the official `milvus-backup` CLI for
  create/restore. Designed around the "100GB-from-developer" import case.
  Cross-version restore (2.5 backup → 2.6 cluster) validated.
- **Per-port + per-image customisation** — every port and every
  container image repo is configurable in `cluster.env` (override
  `*_IMAGE_REPO` for air-gapped registries).
- **No Kubernetes** — runs on any Linux VM with Docker.

## What it's not

- A Kubernetes alternative for general workloads. It does one thing:
  HA Milvus on plain VMs.
- A managed service. You operate it.
- For Milvus 1.x. We target 2.5 and 2.6 today; future majors land as
  templates.

## Supported environments

**milvus-onprem is cloud-agnostic.** It runs on any Linux VM with
Docker, regardless of where that VM lives:

- **Cloud:** AWS / GCP / Azure / OCI / DigitalOcean / Linode / Vultr / etc.
- **On-prem:** VMware / Proxmox / KVM / Xen / OpenStack / Nutanix
- **Bare metal:** any Linux server you can SSH into
- **Hybrid:** any mix of the above, as long as nodes can reach each
  other on the cluster ports
- **Disconnected / air-gapped:** mirror the four container images into
  your private registry; no internet access required at runtime
- **Local dev:** VirtualBox / Multipass / lima / WSL2 / a fleet of
  Raspberry Pis on your home lab

**Requirements:**

- Linux, kernel 4.x or newer (any distro — Debian, Ubuntu, RHEL,
  Rocky, Alma, openSUSE, Arch, etc.)
- Docker Engine ≥ 24.x with the Compose plugin
- Network reachability between every peer on the cluster ports
  (see [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#network-ports-between-nodes))
- Image-pull access to `milvusdb/milvus`, `quay.io/coreos/etcd`,
  `minio/minio`, `nginx`, `apachepulsar/pulsar` (or a private mirror
  with these images for air-gapped environments)

**Not required:**

- Kubernetes
- Cloud-provider APIs (no `gcloud` / `aws` / `az` calls anywhere)
- Cloud-specific DNS / metadata services
- A specific Linux distro
- A specific architecture — works on `amd64` and `arm64`

The CLI uses **direct IP addresses**, not cloud DNS. As long as your
nodes can `nc -zv <peer-ip> 2379` each other, you're good.

## Documentation

| Doc | Read this when |
|---|---|
| [docs/TUTORIAL.md](docs/TUTORIAL.md) | **Start here.** Hardware-validated walkthrough of every shipped feature on a real 4-VM cluster. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | You want to understand how the components fit together. |
| [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) | First-time deploy reference. Step-by-step with diagrams. |
| [docs/CONFIG.md](docs/CONFIG.md) | `cluster.env` reference — every variable, every default (incl. watchdog tuning + retention). |
| [docs/OPERATIONS.md](docs/OPERATIONS.md) | Day-2: status, smoke, backup, restore, scale-out, alert formats. |
| [docs/FAILOVER.md](docs/FAILOVER.md) | What happens when a node dies — 2.5 vs 2.6 behavior, retry pattern, recovery tunings, watchdog flow, 2.5 mixcoord active-standby. |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptom → fix table. Permanently-lost-node recovery, COMPONENT_RESTART_LOOP triage, 2.5 mixcoord panic. |
| [docs/CONTROL_PLANE.md](docs/CONTROL_PLANE.md) | Internals of the daemon: leader election, jobs, watchdog, design rationale. |
| [docs/PULSAR_HA.md](docs/PULSAR_HA.md) | Design for in-cluster Pulsar HA on 2.5 (not yet implemented). |
| [daemon/README.md](daemon/README.md) | Per-file walkthrough of the Python daemon. |
| [test/tutorial/README.md](test/tutorial/README.md) | 10-step pymilvus walkthrough for app developers. |
| [templates/2.5/README.md](templates/2.5/README.md) · [templates/2.6/README.md](templates/2.6/README.md) | Per-version topology notes. |

## Versioning

- Milvus version is selected via `MILVUS_IMAGE_TAG` in cluster.env
  (or `--milvus-version=…` on `init`).
- The CLI auto-routes to `templates/<major.minor>/` based on that tag.
- Currently shipping templates: **2.6** (recommended, simplest topology)
  and **2.5** (per-component containers + Pulsar singleton; HA-Pulsar
  is design-doc only — see [docs/PULSAR_HA.md](docs/PULSAR_HA.md)).
- Adding a future 2.7+ means contributing template files in a new
  `templates/X.Y/` directory — no engine changes needed.

## Validation status

| Path | Status |
|---|---|
| 2.6 N=3 / N=4 — bootstrap, smoke, tutorial 02–10, replication-proof | ✅ |
| 2.5 N=3 / N=4 — bootstrap, smoke, tutorial 02–10, replication-proof | ✅ |
| Online add-node (3→4 with rolling MinIO recreate) | ✅ ~93s, sequenced 30s/peer |
| Online remove-node (4→3, 2.5 + 2.6) | ✅ |
| Rolling Milvus version upgrade (2.5 + 2.6) | ✅ |
| Backup pipeline (etcd snapshot + create + export + restore-with-rename + load) | ✅ |
| Cross-version restore (2.5 backup → 2.6 cluster) | ✅ |
| Watchdog: COMPONENT_RESTART × N → COMPONENT_RESTART_LOOP back-off | ✅ |
| Watchdog: PEER_DOWN_ALERT / PEER_UP_ALERT | ✅ |
| 2.5 mixcoord active-standby failover (`enableActiveStandby: true`) | ✅ <500ms promotion |
| 2.6 single-node failover with active query loop | ✅ 0 errors during outage |
| Permanently-lost-node recovery (etcd member-remove + replace) | ✅ |

## License

Apache 2.0. See [LICENSE](LICENSE).

## Contributing

PRs welcome, especially:
- `templates/2.5/` (Pulsar singleton or external Pulsar)
- New backup integrations
- Real-world deploy reports + bug fixes
