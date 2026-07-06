#!/usr/bin/env bash
# Apply capacity + storage overrides to the checked-in .env.local files.
# Idempotent (upsert per key). Re-run after changing /etc/e2b/sizing.env, then
# restart the e2b-* services. Keeps STORAGE_PROVIDER / ARTIFACTS_REGISTRY_PROVIDER
# on the "Local" backends (no Azure Blob / ACR needed for the single-box mode).
set -euo pipefail
source /etc/e2b/sizing.env

REPO_DIR="/opt/e2b/e2b-infra"

upsert() {  # upsert <file> <KEY> <VALUE>
  local file="$1" key="$2" val="$3"
  touch "$file"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$file"
  else
    echo "${key}=${val}" >>"$file"
  fi
}

ORCH="$REPO_DIR/packages/orchestrator/.env.local"
upsert "$ORCH" STORAGE_PROVIDER Local
upsert "$ORCH" ARTIFACTS_REGISTRY_PROVIDER Local
upsert "$ORCH" NBD_POOL_SIZE "$NBD_POOL_SIZE"
# Durable local template/build storage on the mounted data disk.
upsert "$ORCH" LOCAL_TEMPLATE_STORAGE_BASE_PATH /opt/e2b/data/template-storage
upsert "$ORCH" LOCAL_BUILD_CACHE_STORAGE_BASE_PATH /opt/e2b/data/build-cache
upsert "$ORCH" SNAPSHOT_CACHE_DIR /mnt/snapshot-cache
mkdir -p /opt/e2b/data/template-storage /opt/e2b/data/build-cache

echo "env-overrides applied (NBD_POOL_SIZE=${NBD_POOL_SIZE}, Local providers, data disk paths)."
