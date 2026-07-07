#!/usr/bin/env bash
# E2B orchestrator node bootstrap: Nomad client + orchestrator + Firecracker,
# using Azure Blob storage + ACR + the managed data tier. Idempotent.
set -euo pipefail
PS4='[\D{%Y-%m-%d %H:%M:%S}] '
set -x

source /etc/e2b/node.env
export HOME=/root GOPATH=/root/go GOMODCACHE=/root/go/pkg/mod
mkdir -p "$GOPATH" /opt/e2b/.state
GO_VERSION="1.26.3"
REPO_DIR="/opt/e2b/e2b-infra"
export PATH="/usr/local/go/bin:/root/go/bin:/usr/local/bin:${PATH}"

# ---------------------------------------------------------------------------
# KVM / host tuning (Firecracker)
# ---------------------------------------------------------------------------
modprobe kvm 2>/dev/null || true
modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
modprobe nbd nbds_max=128 || true
if [[ ! -e /dev/kvm ]]; then
  echo "FATAL: /dev/kvm missing — VMSS size lacks nested virtualization." >&2
  exit 1
fi
cat >/etc/sysctl.d/99-e2b.conf <<EOF
vm.nr_hugepages=6144
vm.max_map_count=1048576
vm.swappiness=10
net.core.somaxconn=65535
# The uffd handler mmaps a memfd as large as each sandbox's RAM out of
# non-hugepage memory; with the default overcommit heuristic those mmaps
# start failing (ENOMEM) once a few multi-GB sandboxes run per node.
# Pages materialize lazily, so always-overcommit is the intended mode.
vm.overcommit_memory=1
EOF
sysctl --system
cat >/etc/security/limits.d/99-e2b.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft memlock unlimited
* hard memlock unlimited
EOF
mkdir -p /mnt/snapshot-cache
mountpoint -q /mnt/snapshot-cache || mount -t tmpfs -o size=16G tmpfs /mnt/snapshot-cache

# ---------------------------------------------------------------------------
# Toolchain: Go + gcloud (gsutil) + Nomad
# ---------------------------------------------------------------------------
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
fi
echo 'export PATH="/usr/local/go/bin:$PATH"' >/etc/profile.d/e2b-go.sh

if ! command -v gsutil >/dev/null 2>&1; then
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" >/etc/apt/sources.list.d/google-cloud-sdk.list
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  apt-get update && apt-get install -y google-cloud-cli
fi

if ! command -v nomad >/dev/null 2>&1; then
  curl -fsSL "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip" -o /tmp/nomad.zip
  unzip -o /tmp/nomad.zip -d /usr/local/bin
fi

# ---------------------------------------------------------------------------
# Repo + prebuilt artifacts (kernels, firecrackers, busybox)
# ---------------------------------------------------------------------------
[ -d "$REPO_DIR/.git" ] || git clone "$REPO_URL" "$REPO_DIR"
cd "$REPO_DIR"
git fetch --all --tags && git checkout "$REPO_REF" && git pull --ff-only || true

if [[ ! -f /opt/e2b/.state/artifacts.done ]]; then
  make download-public-kernels
  make download-public-firecrackers
  make -C packages/orchestrator fetch-busybox
  touch /opt/e2b/.state/artifacts.done
fi

# ---------------------------------------------------------------------------
# Orchestrator .env.local — Azure Blob + ACR + managed data tier
# ---------------------------------------------------------------------------
upsert() { local f="$1" k="$2" v="$3"; touch "$f"; if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"; else echo "$k=$v" >>"$f"; fi; }
O="$REPO_DIR/packages/orchestrator/.env.local"
upsert "$O" ENVIRONMENT "prod"
upsert "$O" ORCHESTRATOR_SERVICES "orchestrator,template-manager"
upsert "$O" STORAGE_PROVIDER "AzureBlob"
upsert "$O" ARTIFACTS_REGISTRY_PROVIDER "AZURE_ACR"
upsert "$O" AZURE_STORAGE_ACCOUNT "$AZURE_STORAGE_ACCOUNT"
upsert "$O" AZURE_STORAGE_KEY "$AZURE_STORAGE_KEY"
upsert "$O" TEMPLATE_BUCKET_NAME "$TEMPLATE_BUCKET_NAME"
upsert "$O" BUILD_CACHE_BUCKET_NAME "$BUILD_CACHE_BUCKET_NAME"
upsert "$O" AZURE_ACR_LOGIN_SERVER "$AZURE_ACR_LOGIN_SERVER"
upsert "$O" AZURE_DOCKER_REPOSITORY_NAME "$AZURE_DOCKER_REPOSITORY_NAME"
upsert "$O" AZURE_ACR_USERNAME "$AZURE_ACR_USERNAME"
upsert "$O" AZURE_ACR_PASSWORD "$AZURE_ACR_PASSWORD"
upsert "$O" CLICKHOUSE_CONNECTION_STRING "clickhouse://$CH_USER:$CH_PASSWORD@$DATA_IP:9000/default"
upsert "$O" REDIS_URL "$DATA_IP:6379"
upsert "$O" NBD_POOL_SIZE "64"
upsert "$O" SNAPSHOT_CACHE_DIR "/mnt/snapshot-cache"
# With ENVIRONMENT=prod the network pool otherwise takes the Consul-backed
# path and blocks forever (we run Nomad-only, no Consul) — :5008 never binds.
upsert "$O" USE_LOCAL_NAMESPACE_STORAGE "true"

# ---------------------------------------------------------------------------
# Build orchestrator + envd
# ---------------------------------------------------------------------------
make -C packages/envd build
# build-local is a plain `go build`; the default `build` target needs Docker
# BuildKit output support and fails on these nodes (exit 125).
make -C packages/orchestrator build-local

# ---------------------------------------------------------------------------
# Nomad CLIENT — join the control server; lands in the "default" pool that the
# API filters on (Status == ready and NodePool == "default").
# ---------------------------------------------------------------------------
mkdir -p /opt/nomad/data /etc/nomad.d
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
cat >/etc/nomad.d/nomad.hcl <<EOF
data_dir  = "/opt/nomad/data"
bind_addr = "0.0.0.0"
advertise { http = "$PRIVATE_IP" rpc = "$PRIVATE_IP" serf = "$PRIVATE_IP" }
client {
  enabled = true
  servers = ["${CONTROL_IP}:4647"]
}
EOF
cat >/etc/systemd/system/nomad.service <<'EOF'
[Unit]
Description=Nomad
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/nomad agent -config=/etc/nomad.d
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------------------
# Orchestrator service (root: KVM, TAP, cgroups, NBD)
# ---------------------------------------------------------------------------
cat >/etc/systemd/system/e2b-orchestrator.service <<EOF
[Unit]
Description=E2B orchestrator + template-manager
After=network-online.target nomad.service
Wants=network-online.target
[Service]
User=root
WorkingDirectory=$REPO_DIR/packages/orchestrator
EnvironmentFile=$REPO_DIR/packages/orchestrator/.env.local
Environment=NODE_ID=%H
Environment=GODEBUG=madvdontneed=1
ExecStartPre=/bin/mkdir -p $REPO_DIR/packages/orchestrator/.data/test-volume
ExecStart=$REPO_DIR/packages/orchestrator/bin/orchestrator
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
LimitMEMLOCK=infinity
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now nomad
systemctl enable --now e2b-orchestrator.service

echo "=============================================================="
echo " Orchestrator node ready — Nomad client joined ${CONTROL_IP}, orchestrator on :5008."
echo "=============================================================="
