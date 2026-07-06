#!/usr/bin/env bash
# E2B single-box bootstrap (local storage + local registry providers).
# Idempotent: safe to re-run. Logs to /var/log/e2b-bootstrap.log.
set -euo pipefail
PS4='[\D{%Y-%m-%d %H:%M:%S}] '
set -x

source /etc/e2b/sizing.env

# cloud-init runcmd runs as root WITHOUT a login environment, so $HOME is unset.
# Go needs it for GOPATH / module cache / sumdb, and sub-makes inherit these.
export HOME=/root
export GOPATH=/root/go
export GOMODCACHE=/root/go/pkg/mod
mkdir -p "$GOPATH"

GO_VERSION="1.26.3"
REPO_DIR="/opt/e2b/e2b-infra"
DATA_DIR="/opt/e2b/data"
MARKER_DIR="/opt/e2b/.state"
mkdir -p "$MARKER_DIR"

# ---------------------------------------------------------------------------
# 0. KVM / nested virtualization sanity check (Firecracker hard requirement)
# ---------------------------------------------------------------------------
modprobe kvm || true
modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || true
modprobe nbd nbds_max="${NBDS_MAX}" || true
if [[ ! -e /dev/kvm ]]; then
  echo "FATAL: /dev/kvm not present. This VM size does not expose nested virtualization." >&2
  echo "Pick a nested-virt-capable size (Dv5/Dsv5, Dv6/Dsv6, Fsv2) and redeploy." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Host tuning: huge pages, nbd, sysctls (persisted)
# ---------------------------------------------------------------------------
cat >/etc/sysctl.d/99-e2b.conf <<EOF
vm.nr_hugepages=${NR_HUGEPAGES}
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.max_map_count=1048576
net.core.somaxconn=65535
net.core.netdev_max_backlog=65535
net.ipv4.tcp_max_syn_backlog=65535
EOF
sysctl --system

cat >/etc/security/limits.d/99-e2b.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
* soft memlock unlimited
* hard memlock unlimited
EOF

# ---------------------------------------------------------------------------
# 2. Mount the data disk at /opt/e2b/data (LUN 10) for template/build/snapshot storage
# ---------------------------------------------------------------------------
DATA_DISK="$(readlink -f /dev/disk/azure/scsi1/lun10 2>/dev/null || true)"
if [[ -n "$DATA_DISK" && -b "$DATA_DISK" ]]; then
  if ! blkid "$DATA_DISK"; then
    mkfs.ext4 -F "$DATA_DISK"
  fi
  mkdir -p "$DATA_DIR"
  grep -q "$DATA_DIR" /etc/fstab || echo "$(blkid -s UUID -o value "$DATA_DISK") $DATA_DIR ext4 defaults,nofail 0 2" >>/etc/fstab
  mount -a || true
else
  echo "WARN: data disk (lun10) not found; using OS disk for storage." >&2
  mkdir -p "$DATA_DIR"
fi

# tmpfs snapshot cache sized to total sandbox RAM
mkdir -p /mnt/snapshot-cache
grep -q "/mnt/snapshot-cache" /etc/fstab || \
  echo "tmpfs /mnt/snapshot-cache tmpfs size=${SNAPSHOT_CACHE_GB}G 0 0" >>/etc/fstab
mountpoint -q /mnt/snapshot-cache || mount /mnt/snapshot-cache

# ---------------------------------------------------------------------------
# 3. Toolchain: Go + gcloud SDK (gsutil, for downloading public kernels/firecrackers)
# ---------------------------------------------------------------------------
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
fi
export PATH="/usr/local/go/bin:/root/go/bin:${PATH}"
grep -q '/usr/local/go/bin' /etc/profile.d/e2b-go.sh 2>/dev/null || \
  echo 'export PATH="/usr/local/go/bin:$PATH"' >/etc/profile.d/e2b-go.sh

if ! command -v gsutil >/dev/null 2>&1; then
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    >/etc/apt/sources.list.d/google-cloud-sdk.list
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  apt-get update && apt-get install -y google-cloud-cli
fi

# ---------------------------------------------------------------------------
# 4. Clone / update the repo
# ---------------------------------------------------------------------------
mkdir -p /opt/e2b
if [[ ! -d "$REPO_DIR/.git" ]]; then
  git clone "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"
git fetch --all --tags
git checkout "$REPO_REF"
git pull --ff-only || true

# Apply capacity/exposure overrides to the checked-in .env.local files
/opt/e2b/env-overrides.sh

# ---------------------------------------------------------------------------
# 5. Download prebuilt Firecracker + kernels (anonymous public bucket)
# ---------------------------------------------------------------------------
if [[ ! -f "$MARKER_DIR/artifacts.done" ]]; then
  make download-public-kernels
  make download-public-firecrackers
  # busybox is fetched by a separate target (not covered by DEV-LOCAL.md); the
  # orchestrator needs it to populate the sandbox rootfs, else template builds
  # fail with "error reading busybox file .../.busybox/<ver>/<arch>/busybox".
  make -C packages/orchestrator fetch-busybox
  touch "$MARKER_DIR/artifacts.done"
fi

# ---------------------------------------------------------------------------
# 6. Bring up backing infra (Postgres, ClickHouse, Redis + observability)
# ---------------------------------------------------------------------------
systemctl daemon-reload
systemctl enable --now e2b-infra.service

echo "Waiting for Postgres and ClickHouse..."
for i in $(seq 1 60); do
  if docker exec "$(docker ps -qf name=postgres | head -1)" pg_isready -U postgres 2>/dev/null | grep -q "accepting"; then
    break
  fi
  sleep 3
done
sleep 10  # let ClickHouse finish init

# ---------------------------------------------------------------------------
# 7. Build envd, migrate DBs, seed once
# ---------------------------------------------------------------------------
make -C packages/envd build

if [[ ! -f "$MARKER_DIR/db.done" ]]; then
  make -C packages/db migrate-local
  make -C packages/clickhouse migrate-local
  make -C packages/local-dev seed-database
  touch "$MARKER_DIR/db.done"
fi

# ---------------------------------------------------------------------------
# 8. Build the three services
# ---------------------------------------------------------------------------
make -C packages/api build
make -C packages/orchestrator build || make -C packages/orchestrator build-debug
make -C packages/client-proxy build

# ---------------------------------------------------------------------------
# 9. Start services (order: orchestrator -> api -> client-proxy)
# ---------------------------------------------------------------------------
systemctl enable --now e2b-orchestrator.service
for i in $(seq 1 40); do
  curl -fsS http://localhost:5008/health >/dev/null 2>&1 && break
  sleep 3
done
systemctl enable --now e2b-api.service
systemctl enable --now e2b-client-proxy.service

# ---------------------------------------------------------------------------
# 10. Build the base template (required before any sandbox can start)
# ---------------------------------------------------------------------------
if [[ ! -f "$MARKER_DIR/base-template.done" ]]; then
  for i in $(seq 1 20); do
    curl -fsS http://localhost:3000/health >/dev/null 2>&1 && break
    sleep 3
  done
  make -C packages/shared/scripts local-build-base-template && touch "$MARKER_DIR/base-template.done"
fi

echo "======================================================================"
echo " E2B single-box bootstrap complete."
echo "   API:      http://<public-ip>:3000"
echo "   Sandbox:  http://<public-ip>:3002"
echo "   Tokens:   see DEV-LOCAL.md 'Client configuration' (ROTATE before real use)"
echo "   Sessions planned: ${SESSIONS}  hugepages: ${NR_HUGEPAGES} (2MiB each)"
echo "======================================================================"
