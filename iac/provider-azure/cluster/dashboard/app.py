#!/usr/bin/env python3
"""
Minimal E2B cluster dashboard for the self-hosted Azure deployment.

Lists sandboxes (running + paused), lets you browse/read files inside the
Firecracker VMs (via envd), run commands in them, view metrics, and
kill/pause/resume — roughly the useful parts of app.e2b.dev, self-contained.

The server holds the API key; the browser only ever talks to this process.
Binds to 127.0.0.1 by default — if you deploy it on the control node or
expose it, put auth in front first (there is none built in).

Usage:
    export E2B_API_KEY=...           # dev seed key or your rotated key
    export E2B_API_URL=http://40.87.105.106:3000
    export E2B_SANDBOX_URL=http://40.87.105.106:3002
    uv run --with e2b,fastapi,uvicorn,httpx python app.py [--port 8800]

Then open http://127.0.0.1:8800
"""
from __future__ import annotations

import argparse
import os
import threading
from pathlib import Path

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, JSONResponse

from e2b import Sandbox
from e2b.exceptions import SandboxException

API_URL = os.environ.get("E2B_API_URL", "http://40.87.105.106:3000")
API_KEY = os.environ.get("E2B_API_KEY", "")

app = FastAPI(title="e2b-cluster-dashboard")

_handles: dict[str, Sandbox] = {}
_handles_lock = threading.Lock()


def api_get(path: str, **params) -> httpx.Response:
    return httpx.get(
        f"{API_URL}{path}",
        headers={"X-API-Key": API_KEY},
        params={k: v for k, v in params.items() if v is not None},
        timeout=15,
    )


def handle(sandbox_id: str) -> Sandbox:
    """Get a connected Sandbox handle. Note: connect() resumes a paused sandbox."""
    with _handles_lock:
        sbx = _handles.get(sandbox_id)
    if sbx is None:
        try:
            sbx = Sandbox.connect(sandbox_id)
        except SandboxException as exc:
            raise HTTPException(status_code=404, detail=str(exc))
        with _handles_lock:
            _handles[sandbox_id] = sbx
    return sbx


def drop_handle(sandbox_id: str) -> None:
    with _handles_lock:
        _handles.pop(sandbox_id, None)


@app.get("/")
def index():
    return FileResponse(Path(__file__).parent / "index.html")


@app.get("/api/sandboxes")
def list_sandboxes():
    items = []
    paginator = Sandbox.list()
    while paginator.has_next:
        for s in paginator.next_items():
            items.append(
                {
                    "sandbox_id": s.sandbox_id,
                    "template_id": s.template_id,
                    "state": str(s.state.value if hasattr(s.state, "value") else s.state),
                    "started_at": s.started_at.isoformat() if s.started_at else None,
                    "end_at": s.end_at.isoformat() if s.end_at else None,
                    "cpu_count": s.cpu_count,
                    "memory_mb": s.memory_mb,
                    "metadata": s.metadata or {},
                }
            )
    return {"sandboxes": items}


@app.get("/api/sandboxes/{sandbox_id}/files")
def list_files(sandbox_id: str, path: str = Query("/")):
    sbx = handle(sandbox_id)
    try:
        entries = sbx.files.list(path)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    return {
        "path": path,
        "entries": [
            {"name": e.name, "type": str(e.type.value if hasattr(e.type, "value") else e.type), "path": e.path}
            for e in entries
        ],
    }


MAX_FILE_BYTES = 256 * 1024


@app.get("/api/sandboxes/{sandbox_id}/file")
def read_file(sandbox_id: str, path: str = Query(...)):
    sbx = handle(sandbox_id)
    try:
        content = sbx.files.read(path)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    truncated = len(content) > MAX_FILE_BYTES
    return {"path": path, "truncated": truncated, "content": content[:MAX_FILE_BYTES]}


@app.post("/api/sandboxes/{sandbox_id}/exec")
def exec_command(sandbox_id: str, body: dict):
    cmd = (body or {}).get("cmd", "").strip()
    if not cmd:
        raise HTTPException(status_code=400, detail="cmd is required")
    sbx = handle(sandbox_id)
    try:
        r = sbx.commands.run(cmd, timeout=60)
        return {"exit_code": r.exit_code, "stdout": r.stdout, "stderr": r.stderr}
    except Exception as exc:
        # command failures raise; surface what we have instead of a 500
        exit_code = getattr(exc, "exit_code", None)
        stderr = getattr(exc, "stderr", None) or str(exc)
        stdout = getattr(exc, "stdout", "") or ""
        return {"exit_code": exit_code if exit_code is not None else -1, "stdout": stdout, "stderr": stderr}


@app.get("/api/sandboxes/{sandbox_id}/metrics")
def sandbox_metrics(sandbox_id: str):
    r = api_get(f"/sandboxes/{sandbox_id}/metrics")
    if r.status_code != 200:
        raise HTTPException(status_code=r.status_code, detail=r.text[:500])
    return JSONResponse(r.json())


@app.get("/api/sandboxes/{sandbox_id}/logs")
def sandbox_logs(sandbox_id: str):
    # Loki-backed upstream; this cluster has no Loki, so degrade gracefully.
    try:
        r = api_get(f"/sandboxes/{sandbox_id}/logs", limit=200)
        if r.status_code == 200:
            return JSONResponse(r.json())
        return JSONResponse(
            {"unavailable": True, "reason": f"API returned {r.status_code}: no log backend (Loki) is deployed on this cluster"},
            status_code=200,
        )
    except httpx.HTTPError as exc:
        return JSONResponse({"unavailable": True, "reason": str(exc)}, status_code=200)


@app.post("/api/sandboxes/{sandbox_id}/kill")
def kill_sandbox(sandbox_id: str):
    sbx = handle(sandbox_id)
    ok = sbx.kill()
    drop_handle(sandbox_id)
    return {"ok": ok}


@app.post("/api/sandboxes/{sandbox_id}/pause")
def pause_sandbox(sandbox_id: str):
    sbx = handle(sandbox_id)
    ok = sbx.pause()
    drop_handle(sandbox_id)
    return {"ok": ok}


@app.post("/api/sandboxes/{sandbox_id}/resume")
def resume_sandbox(sandbox_id: str):
    drop_handle(sandbox_id)
    sbx = handle(sandbox_id)  # connect() resumes paused sandboxes
    return {"ok": True, "state": "running", "sandbox_id": sbx.sandbox_id}


@app.post("/api/sandboxes")
def create_sandbox(body: dict | None = None):
    template = (body or {}).get("template", "base")
    timeout = int((body or {}).get("timeout", 300))
    sbx = Sandbox.create(template, timeout=timeout)
    with _handles_lock:
        _handles[sbx.sandbox_id] = sbx
    return {"sandbox_id": sbx.sandbox_id}


@app.get("/api/cluster")
def cluster_info():
    health = None
    try:
        health = httpx.get(f"{API_URL}/health", timeout=5).status_code
    except httpx.HTTPError:
        pass
    return {"api_url": API_URL, "api_health": health}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8800)
    args = parser.parse_args()
    if not API_KEY:
        raise SystemExit("E2B_API_KEY is not set")
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    main()
