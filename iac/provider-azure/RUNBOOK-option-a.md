# Option A Runbook — 20 concurrent E2B sessions on one Azure box

Stand up the full E2B stack (API + orchestrator + client-proxy + Firecracker)
on a single nested-virt Azure VM using **Local** storage and registry providers.
No Azure Blob, no ACR, no Nomad cluster. Everything is preserved as reusable
Terraform in [`single-box/`](./single-box/).

---

## 1. Sizing math (why these numbers)

Each sandbox is a Firecracker microVM with pre-reserved **2 MiB huge pages**
covering its RAM. Huge pages are reserved at boot and unusable by anything else,
so we size them to the planned sandbox footprint — no more.

| Quantity | Formula | 20 sessions @ 2 vCPU / 1 GB |
|---|---|---|
| Huge pages | `sessions × ram_mb / 2 × 1.15` | ~11,776 pages (~23 GB) |
| vCPU (oversubscribed) | `sessions × vcpu` | 40 vCPU on 16 physical = 2.5× |
| Snapshot tmpfs | ~1× total sandbox RAM | ~20 GB |
| NBD device pool | `max(64, sessions × 2)` | 64 |

**VM choice:** `Standard_D16s_v6` (16 vCPU / 64 GB) is the floor — 23 GB huge
pages + Postgres/ClickHouse/Redis + Go builds fit in 64 GB, and interactive
sandboxes tolerate CPU oversubscription. Choose `Standard_D32s_v6` (32 vCPU /
128 GB) if sessions are CPU-heavy or you build templates while serving traffic.
All sizing is driven by the `sessions`, `per_session_vcpu`, and
`per_session_ram_mb` Terraform variables — Terraform computes the huge pages,
NBD pool, and tmpfs for you (`terraform output capacity_plan`).

> The E2B **base** template defaults to ~512 MB. `per_session_ram_mb = 1024` just
> reserves headroom. Lower it to reclaim RAM if all your templates are small.

---

## 2. Prerequisites (local machine)

- Terraform ≥ 1.7.5, Azure CLI (`az login`)
- An SSH keypair (`ssh-keygen -t ed25519`)
- An Azure subscription with quota for the chosen Dv6 size in your region
- Confirm the size supports nested virtualization in your region:
  ```bash
  az vm list-skus --location eastus --size Standard_D16s_v6 \
    --query "[].capabilities[?name=='HyperVGenerations'].value" -o tsv
  ```

---

## 3. Deploy

```bash
cd iac/provider-azure/single-box
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars      # subscription_id, ssh_public_key, admin_source_cidr, sessions

terraform init
terraform apply               # ~2 min to provision; bootstrap continues on the box
```

First boot runs `cloud-init` → `bootstrap.sh`, which:
1. verifies `/dev/kvm`, loads `kvm`/`nbd`, applies huge pages + sysctls,
2. mounts the data disk at `/opt/e2b/data`, creates the snapshot tmpfs,
3. installs Go 1.26.3 + gcloud SDK, clones the repo, applies `env-overrides.sh`,
4. downloads public kernels + Firecrackers,
5. brings up Postgres/ClickHouse/Redis (`e2b-infra.service`), migrates, seeds,
6. builds `api` / `orchestrator` / `client-proxy`, installs their systemd units,
7. builds the `base` sandbox template.

Watch it:
```bash
ssh e2b@$(terraform output -raw public_ip)
sudo tail -f /var/log/e2b-bootstrap.log      # until "bootstrap complete"
systemctl status e2b-infra e2b-orchestrator e2b-api e2b-client-proxy
```

Expect the first run to take a while (Go builds + artifact downloads).

---

## 4. Verify end-to-end

On the box (or from your allowed CIDR, swapping localhost for the public IP):

```bash
curl -s http://localhost:3000/health
curl -s -X POST http://localhost:3000/sandboxes \
  -H "X-API-Key: e2b_53ae1fed82754c17ad8077fbc8bcdd90" \
  -H "Content-Type: application/json" \
  -d '{"templateID": "base"}'      # returns a sandboxID
```

From the SDK (this repo is `e2b-sdk/`):

```python
from e2b import Sandbox
IP = "<terraform output public_ip>"
sbx = Sandbox(
    api_key="e2b_53ae1fed82754c17ad8077fbc8bcdd90",
    api_url=f"http://{IP}:3000",
    sandbox_url=f"http://{IP}:3002",
    template="base",
)
print(sbx.commands.run('echo hello from azure').stdout)
```

Load-check 20 at once: create 20 sandboxes in a loop and watch
`grep HugePages /proc/meminfo` (`HugePages_Free` should stay > 0) and
`systemctl status e2b-orchestrator`.

---

## 5. Security — do this before real use

The seed API key / access token are **public** (they live in `DEV-LOCAL.md`).
For anything beyond a locked-down test:

1. Keep `admin_source_cidr` tight (your VPN egress, not `0.0.0.0/0`).
2. Rotate tokens: re-seed with your own values, or generate a new team/key via
   the DB and update `packages/*/.env.local`, then `systemctl restart e2b-*`.
3. Put TLS in front of :3000 / :3002 (Caddy/nginx or an Azure Application
   Gateway) and expose only 443.

---

## 6. Day-2 operations

| Task | Command (on the box) |
|---|---|
| Restart a service | `sudo systemctl restart e2b-api` |
| Logs | `journalctl -u e2b-orchestrator -f` |
| Change capacity | edit `/etc/e2b/sizing.env` → `sudo /opt/e2b/env-overrides.sh` → `sudo sysctl --system` → `sudo systemctl restart e2b-orchestrator` (huge-page changes may need a reboot) |
| Update code | `cd /opt/e2b/e2b-infra && git pull && make -C packages/<svc> build && sudo systemctl restart e2b-<svc>` |
| Rebuild base template | `make -C packages/shared/scripts local-build-base-template` |

To change capacity via IaC instead: bump `sessions` / `per_session_*` in
`terraform.tfvars`, `terraform apply` (re-renders `/etc/e2b/sizing.env`), then
re-run `env-overrides.sh` on the box (or reboot).

---

## 7. Scaling out → Option B

One box tops out at its physical cores/RAM. For automated horizontal scale:

- Promote this into `provider-azure/cluster/`: put the orchestrator/client role
  behind a **VM Scale Set**, bake the box image with **Packer for Azure**
  (mirror `provider-aws/nomad-cluster-disk-image/`), and run Nomad+Consul so the
  control plane schedules sandboxes across nodes.
- Swap Local providers for durable managed services by adding `storage_azure.go`
  (Azure Blob) and an ACR registry impl — each mirrors the existing `*_aws.go`
  file behind the same interface.
- The Nomad job specs in `iac/modules/` are cloud-neutral and carry over as-is.

Until then, this single box gives you a real, reproducible 20-session E2B on
Azure — and the Terraform here is the seed for the cluster version.
