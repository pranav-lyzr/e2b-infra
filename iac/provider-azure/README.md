# E2B on Azure (community provider)

Upstream `e2b-dev/infra` ships Terraform for **AWS** and **GCP** only. This
directory adds Azure support, developed as two phases:

| Phase | Directory | What it gives you | Status |
|---|---|---|---|
| **Option A — single box** | [`single-box/`](./single-box/) | One nested-virt Azure VM running the full stack with **Local** storage + registry providers. Sized for ~20 concurrent sessions. No Azure Blob / ACR required. | ✅ Ready |
| **Option B — horizontal scale** | `cluster/` (todo) | VM Scale Set client nodes + Packer Azure image, mirroring `provider-aws/`. `storage_azure.go` (Blob) + ACR registry for durability. | ⬜ Planned |

## Why this works

E2B's Go services select their cloud dependencies through interfaces with a
built-in **`Local`** backend:

- Object storage — `packages/shared/pkg/storage` (`STORAGE_PROVIDER=Local` → filesystem)
- Container registry — `packages/shared/pkg/artifacts-registry` (`ARTIFACTS_REGISTRY_PROVIDER=Local` → local Docker daemon)

So a single Linux box with `/dev/kvm` (nested virtualization) runs the whole
platform without any cloud object store or registry. The only hard requirement
Azure was missing — nested virtualization — is available on Dv5/Dsv5, Dv6/Dsv6,
Ev5, and Fsv2 sizes.

## Option A quick start

```bash
cd single-box
cp terraform.tfvars.example terraform.tfvars   # edit: subscription, ssh key, CIDR
terraform init
terraform apply
# watch first-boot bootstrap:
ssh e2b@$(terraform output -raw public_ip) 'sudo tail -f /var/log/e2b-bootstrap.log'
```

Then point the SDK at the box — see [`RUNBOOK-option-a.md`](./RUNBOOK-option-a.md)
for the full walkthrough, sizing math, verification, day-2 ops, and the path to
Option B.

## Caveats

- The `Local` path originates from `DEV-LOCAL.md` (a developer mode). It's the
  pragmatic single-box deployment, **not** an HA production topology.
- Seed tokens in `DEV-LOCAL.md` are well-known — **rotate them** before exposing
  the box beyond a trusted CIDR, and front it with TLS.
- Local template storage lives on the attached data disk; it is **not**
  replicated. Snapshot/rebuild the disk if you need durability.
