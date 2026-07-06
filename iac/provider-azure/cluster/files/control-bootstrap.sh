#!/usr/bin/env bash
# E2B control node bootstrap: Nomad server + API + client-proxy, wired to the
# managed data tier. Idempotent. Logs to /var/log/e2b-bootstrap.log.
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
# Toolchain: Go + Nomad
# ---------------------------------------------------------------------------
if ! /usr/local/go/bin/go version 2>/dev/null | grep -q "go${GO_VERSION}"; then
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
fi
echo 'export PATH="/usr/local/go/bin:$PATH"' >/etc/profile.d/e2b-go.sh

if ! command -v nomad >/dev/null 2>&1; then
  curl -fsSL "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_amd64.zip" -o /tmp/nomad.zip
  unzip -o /tmp/nomad.zip -d /usr/local/bin
fi

# ---------------------------------------------------------------------------
# Nomad SERVER (node registry the API queries; Nomad-only, no Consul)
# ---------------------------------------------------------------------------
mkdir -p /opt/nomad/data /etc/nomad.d
cat >/etc/nomad.d/nomad.hcl <<EOF
data_dir  = "/opt/nomad/data"
bind_addr = "0.0.0.0"
advertise { http = "${CONTROL_IP}" rpc = "${CONTROL_IP}" serf = "${CONTROL_IP}" }
server { enabled = true bootstrap_expect = 1 }
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
systemctl daemon-reload
systemctl enable --now nomad

# ---------------------------------------------------------------------------
# Repo + build API and client-proxy
# ---------------------------------------------------------------------------
[ -d "$REPO_DIR/.git" ] || git clone "$REPO_URL" "$REPO_DIR"
cd "$REPO_DIR"
git fetch --all --tags && git checkout "$REPO_REF" && git pull --ff-only || true

upsert() { local f="$1" k="$2" v="$3"; touch "$f"; if grep -q "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"; else echo "$k=$v" >>"$f"; fi; }

PG="postgres://$PG_USER:$PG_PASSWORD@$DATA_IP:5432/postgres?sslmode=disable"
CH="clickhouse://$CH_USER:$CH_PASSWORD@$DATA_IP:9000/default"

# API: start from checked-in .env.local (keeps volume/token/edge dev secrets
# consistent with the seed), override for cluster mode.
A="$REPO_DIR/packages/api/.env.local"
upsert "$A" POSTGRES_CONNECTION_STRING "$PG"
upsert "$A" CLICKHOUSE_CONNECTION_STRING "$CH"
upsert "$A" REDIS_URL "$DATA_IP:6379"
upsert "$A" ENVIRONMENT "prod"
upsert "$A" SERVICE_DISCOVERY_PROVIDER "nomad"
upsert "$A" NOMAD_ADDRESS "http://localhost:4646"
# Orchestrator/template-manager run as systemd units (not Nomad jobs), so find
# template builders via the Nomad node list instead of job allocations.
upsert "$A" NOMAD_TEMPLATE_BUILDER_DISCOVERY "nodes"

P="$REPO_DIR/packages/client-proxy/.env.local"
upsert "$P" REDIS_URL "$DATA_IP:6379"
upsert "$P" ENVIRONMENT "prod"

make -C packages/api build
make -C packages/client-proxy build

# ---------------------------------------------------------------------------
# DB migrations + seed (once) against the managed data tier
# ---------------------------------------------------------------------------
if [[ ! -f /opt/e2b/.state/db.done ]]; then
  POSTGRES_CONNECTION_STRING="$PG" make -C packages/db migrate-local || true
  CLICKHOUSE_CONNECTION_STRING="$CH" make -C packages/clickhouse migrate-local || true
  make -C packages/local-dev seed-database || true
  touch /opt/e2b/.state/db.done
fi

# ---------------------------------------------------------------------------
# systemd services
# ---------------------------------------------------------------------------
cat >/etc/systemd/system/e2b-api.service <<EOF
[Unit]
Description=E2B API
After=network-online.target nomad.service
Wants=network-online.target
[Service]
WorkingDirectory=$REPO_DIR/packages/api
EnvironmentFile=$REPO_DIR/packages/api/.env.local
Environment=NODE_ID=%H
ExecStart=$REPO_DIR/packages/api/bin/api --port 3000
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/e2b-client-proxy.service <<EOF
[Unit]
Description=E2B client proxy
After=network-online.target e2b-api.service
Wants=network-online.target
[Service]
WorkingDirectory=$REPO_DIR/packages/client-proxy
EnvironmentFile=$REPO_DIR/packages/client-proxy/.env.local
Environment=NODE_ID=%H
ExecStart=$REPO_DIR/packages/client-proxy/bin/client-proxy
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now e2b-api.service
systemctl enable --now e2b-client-proxy.service

echo "=============================================================="
echo " Control node ready. Nomad server + API(:3000) + proxy(:3002)."
echo " Once orchestrator nodes register, build the base template with:"
echo "   make -C $REPO_DIR/packages/shared/scripts local-build-base-template"
echo "=============================================================="
