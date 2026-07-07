#!/usr/bin/env bash
# Launch the cluster dashboard. Reads the API key from the env or from the
# checked-in dev seed (packages/shared/scripts/.env.local); URLs default to
# the cluster's public LB and can be overridden the same way.
set -euo pipefail
cd "$(dirname "$0")"

# uv may not be on a minimal PATH (IDE launchers, systemd)
for p in "$HOME/.local/bin" /usr/local/bin /opt/homebrew/bin /Library/Frameworks/Python.framework/Versions/3.12/bin; do
  [[ -x "$p/uv" ]] && PATH="$p:$PATH" && break
done
command -v uv >/dev/null || { echo "uv not found; install from https://docs.astral.sh/uv/" >&2; exit 1; }

if [[ -z "${E2B_API_KEY:-}" ]]; then
  SEED="../../../../packages/shared/scripts/.env.local"
  if [[ -f "$SEED" ]]; then
    E2B_API_KEY="$(grep '^E2B_API_KEY=' "$SEED" | cut -d= -f2)"
  fi
fi
export E2B_API_KEY
export E2B_API_URL="${E2B_API_URL:-http://40.87.105.106:3000}"
export E2B_SANDBOX_URL="${E2B_SANDBOX_URL:-http://40.87.105.106:3002}"

exec uv run --with e2b,fastapi,uvicorn,httpx python app.py --port "${DASHBOARD_PORT:-8800}"
