#!/usr/bin/env python3
"""
Sandbox lifecycle test for the self-hosted E2B cluster.

Verifies the timeout/pause features work end-to-end:
  1. timeout auto-kill   -- default lifecycle kills the sandbox when timeout expires
  2. set_timeout         -- extending the timeout keeps the sandbox alive past the original
  3. manual pause/resume -- pause() snapshots to storage, connect() resumes, files survive
  4. auto-pause          -- lifecycle {"on_timeout": "pause"} pauses instead of killing

On this cluster the pause paths also exercise the Azure Blob snapshot
upload/download, so this doubles as a storage-backend regression test.

Usage:
    uv run --with e2b python lifecycle_test_sandboxes.py

Requires E2B_API_KEY / E2B_API_URL / E2B_SANDBOX_URL in the environment.
"""
from __future__ import annotations

import os
import sys
import time
import uuid

from e2b import Sandbox

RESULTS: list[tuple[str, bool, str]] = []


def record(name: str, ok: bool, detail: str) -> None:
    RESULTS.append((name, ok, detail))
    print(f"  {'PASS' if ok else 'FAIL'}: {name} — {detail}")


def state_of(sandbox_id: str) -> str:
    """Return the sandbox state, or 'gone' if the API no longer knows it as running/paused."""
    paginator = Sandbox.list()
    while paginator.has_next:
        for s in paginator.next_items():
            if s.sandbox_id.startswith(sandbox_id.split("-")[0]):
                return str(s.state)
    return "gone"


def wait_for_state(sandbox_id: str, want: str, timeout_s: float, poll_s: float = 3.0) -> str:
    deadline = time.monotonic() + timeout_s
    last = state_of(sandbox_id)
    while time.monotonic() < deadline:
        if want in last:
            return last
        time.sleep(poll_s)
        last = state_of(sandbox_id)
    return last


def resume(sandbox_id: str, timeout: int = 60) -> Sandbox:
    """Resume a paused sandbox; SDK exposes this as connect."""
    return Sandbox.connect(sandbox_id, timeout=timeout)


def test_timeout_kill() -> None:
    print("\n[1] timeout auto-kill (timeout=15s, default lifecycle)")
    sbx = Sandbox.create("base", timeout=15)
    running = state_of(sbx.sandbox_id)
    print(f"    created {sbx.sandbox_id}, state={running}")
    final = wait_for_state(sbx.sandbox_id, "gone", timeout_s=60)
    if final == "gone":
        record("timeout auto-kill", True, "sandbox gone within 60s of a 15s timeout")
    else:
        record("timeout auto-kill", False, f"state is still {final} 60s after timeout")
        sbx.kill()


def test_set_timeout() -> None:
    print("\n[2] set_timeout extension (15s -> 90s)")
    sbx = Sandbox.create("base", timeout=15)
    sbx.set_timeout(90)
    time.sleep(30)  # well past the original 15s
    try:
        r = sbx.commands.run("echo alive")
        ok = r.exit_code == 0
        record("set_timeout extension", ok, "still serving commands 30s after original timeout")
    except Exception as exc:
        record("set_timeout extension", False, f"sandbox died despite extension: {exc}")
    finally:
        try:
            sbx.kill()
        except Exception:
            pass


def test_manual_pause_resume() -> None:
    print("\n[3] manual pause -> resume with state preserved")
    sbx = Sandbox.create("base", timeout=120)
    marker = f"pause-{uuid.uuid4().hex[:8]}"
    sbx.files.write("/tmp/marker.txt", marker)

    t0 = time.monotonic()
    paused = sbx.pause()
    pause_s = time.monotonic() - t0
    print(f"    pause() returned {paused} in {pause_s:.1f}s")
    st = state_of(sbx.sandbox_id)
    print(f"    state after pause: {st}")

    t0 = time.monotonic()
    resumed = resume(sbx.sandbox_id)
    resume_s = time.monotonic() - t0
    try:
        content = resumed.files.read("/tmp/marker.txt")
        ok = content == marker
        record(
            "manual pause/resume",
            ok,
            f"pause {pause_s:.1f}s, resume {resume_s:.1f}s, marker {'intact' if ok else 'LOST'}",
        )
    finally:
        resumed.kill()


def test_auto_pause() -> None:
    print("\n[4] auto-pause on timeout (timeout=15s, on_timeout=pause)")
    sbx = Sandbox.create("base", timeout=15, lifecycle={"on_timeout": "pause"})
    marker = f"autopause-{uuid.uuid4().hex[:8]}"
    sbx.files.write("/tmp/marker.txt", marker)

    final = wait_for_state(sbx.sandbox_id, "paused", timeout_s=90)
    print(f"    state after timeout: {final}")
    if "paused" not in final:
        record("auto-pause on timeout", False, f"expected paused, got {final}")
        try:
            sbx.kill()
        except Exception:
            pass
        return

    resumed = resume(sbx.sandbox_id)
    try:
        content = resumed.files.read("/tmp/marker.txt")
        ok = content == marker
        record("auto-pause on timeout", ok, f"paused on timeout, resumed, marker {'intact' if ok else 'LOST'}")
    finally:
        resumed.kill()


def main() -> int:
    if not os.environ.get("E2B_API_KEY"):
        raise SystemExit("E2B_API_KEY is not set")
    print(f"Lifecycle tests against {os.environ.get('E2B_API_URL', '(default)')}")

    for test in (test_timeout_kill, test_set_timeout, test_manual_pause_resume, test_auto_pause):
        try:
            test()
        except Exception as exc:
            record(test.__name__, False, f"unhandled: {type(exc).__name__}: {exc}")

    print("\n=== summary ===")
    failed = [r for r in RESULTS if not r[1]]
    for name, ok, detail in RESULTS:
        print(f"  {'PASS' if ok else 'FAIL'}  {name}")
    print(f"{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
