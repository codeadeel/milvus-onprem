# milvus-onprem

**High-availability Milvus 2.6 across N Linux VMs — no Kubernetes required.**

> Status: **alpha, under active development.** Not production-ready yet.
> First usable release lands when 3-node deploy + smoke + failover all
> work end-to-end on real hardware.

## What this is

A CLI plus modular bash that deploys a redundant Milvus 2.6 cluster across
plain Linux VMs (3, 5, 7, …). No Kubernetes, no Operator, no Helm. Just
docker compose + etcd Raft + distributed MinIO + Milvus's embedded
Woodpecker WAL.

Designed for the niche between "single-host Milvus Standalone" and
"full Kubernetes Milvus Operator" — constrained on-prem environments where
neither end of that spectrum fits.

## What this is not

- A Kubernetes alternative for general workloads. It does one thing: HA Milvus.
- A managed service. You operate it.
- A way to run Milvus 1.x or 2.5.x. We pin 2.6.x and document upgrades.

## Roadmap to v0

- [ ] Repo skeleton + config schema
- [ ] Core libs (config parsing, template rendering)
- [ ] Templates (compose, milvus.yaml, nginx.conf)
- [ ] etcd + MinIO management
- [ ] Lifecycle: init / bootstrap / pair / join / status / up / down
- [ ] Smoke test + pymilvus tutorial
- [ ] Documentation (ARCHITECTURE / DEPLOYMENT / CONFIG / TROUBLESHOOTING)

After v0: failover/failback, scale-out 3 → 5 → 7, backup/restore wrapper,
v1.0 once it survives a real-world deployment.

## License

Apache 2.0. See [LICENSE](LICENSE).
