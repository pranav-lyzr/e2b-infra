#!/usr/bin/env python3
"""
Concurrent sandbox load test for the self-hosted E2B cluster.

Spins up N sandboxes at once, runs a command + a filesystem round-trip in
each, then kills them all -- to check the cluster (API, orchestrators,
Nomad scheduling, Firecracker) holds up under concurrent load rather than
just sequential single-sandbox checks.

Usage:
    uv run --with e2b python load_test_sandboxes.py --count 20

Requires E2B_API_KEY (and, for a self-hosted cluster, E2B_API_URL /
E2B_SANDBOX_URL) in the environment -- see packages/shared/scripts/.env.local
for the dev seed values used against the Azure cluster.

Results print as a table; pass --json-out to also write raw per-sandbox
timings for comparing runs over time.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import time
import uuid
from dataclasses import dataclass
from pathlib import Path


@dataclass
class SandboxResult:
    index: int
    sandbox_id: str | None = None
    ok: bool = False
    error: str | None = None
    create_s: float | None = None
    command_s: float | None = None
    filesystem_s: float | None = None
    kill_s: float | None = None
    total_s: float | None = None


def run_one(index: int, template: str, command: str, timeout: int, hold_seconds: float) -> SandboxResult:
    from e2b import Sandbox

    result = SandboxResult(index=index)
    t_start = time.monotonic()
    sbx = None
    try:
        t0 = time.monotonic()
        sbx = Sandbox.create(template, timeout=timeout)
        result.sandbox_id = sbx.sandbox_id
        result.create_s = time.monotonic() - t0

        t0 = time.monotonic()
        r = sbx.commands.run(command)
        result.command_s = time.monotonic() - t0
        if r.exit_code != 0:
            raise RuntimeError(f"command exited {r.exit_code}: {r.stderr}")

        t0 = time.monotonic()
        marker = f"loadtest-{uuid.uuid4().hex[:8]}"
        sbx.files.write("/tmp/loadtest.txt", marker)
        if sbx.files.read("/tmp/loadtest.txt") != marker:
            raise RuntimeError("filesystem round-trip mismatch")
        result.filesystem_s = time.monotonic() - t0

        if hold_seconds > 0:
            time.sleep(hold_seconds)

        result.ok = True
    except Exception as exc:  # report all failures, don't crash the pool
        result.error = f"{type(exc).__name__}: {exc}"
    finally:
        if sbx is not None:
            t0 = time.monotonic()
            try:
                sbx.kill()
                result.kill_s = time.monotonic() - t0
            except Exception as exc:
                if result.error is None:
                    result.error = f"kill failed: {exc}"
        result.total_s = time.monotonic() - t_start
    return result


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return float("nan")
    values = sorted(values)
    k = (len(values) - 1) * pct
    f, c = int(k), min(int(k) + 1, len(values) - 1)
    if f == c:
        return values[f]
    return values[f] + (values[c] - values[f]) * (k - f)


def summarize(label: str, values: list[float]) -> str:
    if not values:
        return f"{label}: no data"
    return (
        f"{label:10s}: n={len(values):2d}  min={min(values):5.2f}s  "
        f"p50={percentile(values, 0.5):5.2f}s  p95={percentile(values, 0.95):5.2f}s  "
        f"max={max(values):5.2f}s"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=20, help="number of concurrent sandboxes")
    parser.add_argument("--template", default="base")
    parser.add_argument("--command", default="uname -a && sleep 0.2 && echo done")
    parser.add_argument("--timeout", type=int, default=120, help="per-sandbox timeout (s)")
    parser.add_argument(
        "--hold-seconds", type=float, default=0.0,
        help="keep each sandbox alive this long before killing, to simulate sustained load",
    )
    parser.add_argument("--json-out", type=Path, default=None)
    args = parser.parse_args()

    if not os.environ.get("E2B_API_KEY"):
        raise SystemExit("E2B_API_KEY is not set")

    print(f"Launching {args.count} sandboxes concurrently against {os.environ.get('E2B_API_URL', '(default)')}")
    wall_start = time.monotonic()
    results: list[SandboxResult] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.count) as pool:
        futures = [
            pool.submit(run_one, i, args.template, args.command, args.timeout, args.hold_seconds)
            for i in range(args.count)
        ]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())
    wall_s = time.monotonic() - wall_start

    results.sort(key=lambda r: r.index)
    failures = [r for r in results if not r.ok]

    print()
    for r in results:
        status = "OK" if r.ok else f"FAIL ({r.error})"
        print(f"  [{r.index:2d}] {r.sandbox_id or '-':22s} {status}")

    print()
    print(f"Wall clock for all {args.count}: {wall_s:.2f}s")
    print(f"Succeeded: {args.count - len(failures)}/{args.count}")
    print(summarize("create", [r.create_s for r in results if r.create_s is not None]))
    print(summarize("command", [r.command_s for r in results if r.command_s is not None]))
    print(summarize("filesystem", [r.filesystem_s for r in results if r.filesystem_s is not None]))
    print(summarize("kill", [r.kill_s for r in results if r.kill_s is not None]))

    if args.json_out:
        payload = {
            "count": args.count,
            "template": args.template,
            "wall_s": wall_s,
            "succeeded": args.count - len(failures),
            "results": [r.__dict__ for r in results],
        }
        args.json_out.write_text(json.dumps(payload, indent=2))
        print(f"\nWrote results to {args.json_out}")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
