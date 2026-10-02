#!/usr/bin/env python3
"""Run an explicit validation plan concurrently, with deadlines and a source receipt.

No package installs, baseline retries, publishing, or test selection is implicit.
Plans contain argv arrays, not shell strings. See docs/validation-and-release.md.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def source_state(root):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root)

    # Include uncommitted source, including new files; generated output is ignored
    # by git. A SHA alone would falsely identify a dirty checkout as tested HEAD.
    digest = hashlib.sha256(git("diff", "HEAD", "--binary", "--no-ext-diff"))
    untracked = git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0")
    for name in sorted(filter(None, untracked)):
        digest.update(name + b"\0")
        path = root / os.fsdecode(name)
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        else:
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
    return {
        "commit": git("rev-parse", "HEAD").decode().strip(),
        "tree": git("rev-parse", "HEAD^{tree}").decode().strip(),
        "working_changes_sha256": digest.hexdigest(),
        "dirty": bool(git("status", "--porcelain", "--untracked-files=normal")),
    }


def read_plan(path, root):
    plan = json.loads(path.read_text())
    checks = plan.get("checks")
    if not isinstance(checks, list) or not checks:
        raise ValueError("plan must contain a nonempty checks list")
    if not isinstance(plan.get("reason"), str) or not plan["reason"].strip():
        raise ValueError("plan must explain its scope in reason")
    minimum = plan.get("minimum_free_gib", 2)
    if isinstance(minimum, bool) or not isinstance(minimum, (int, float)) or not math.isfinite(minimum) or minimum < 0:
        raise ValueError("minimum_free_gib must be a finite nonnegative number")
    names = set()
    for check in checks:
        name = check.get("name", "")
        if not re.fullmatch(r"[a-zA-Z0-9_-]+", name) or name in names:
            raise ValueError("check names must be unique letters, digits, underscores, or hyphens")
        names.add(name)
        argv = check.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and a for a in argv):
            raise ValueError(f"{name}: argv must be a nonempty string array")
        timeout = check.get("timeout_seconds")
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)) or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError(f"{name}: supply a positive timeout_seconds")
        cwd = (root / check.get("cwd", ".")).resolve()
        if not cwd.is_dir() or not cwd.is_relative_to(root):
            raise ValueError(f"{name}: cwd must be a directory in this checkout")
    return plan


def stop_group(process):
    """Only our new session's process group, never global pkill/tmux cleanup."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        pass
    # The parent may exit on TERM while its fixture children ignore it.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def run_checks(plan, root, output, jobs):
    pending = list(plan["checks"])
    active = []
    results = []
    try:
        while pending or active:
            while pending and len(active) < jobs:
                check = pending.pop(0)
                result = dict(check, started_at=utc_now(), status="running")
                log_path = output / (check["name"] + ".log")
                result["log"] = str(log_path)
                log = log_path.open("wb")
                started = time.monotonic()
                try:
                    process = subprocess.Popen(
                        check["argv"], cwd=root / check.get("cwd", "."),
                        stdout=log, stderr=subprocess.STDOUT,
                        stdin=subprocess.DEVNULL, start_new_session=True,
                    )
                except OSError as error:
                    log.close()
                    result.update(status="blocked", error=str(error), duration_seconds=0, finished_at=utc_now())
                    results.append(result)
                    print(f"{check['name']}: blocked ({error})", flush=True)
                    continue
                active.append((process, log, result, started))
                print(f"{check['name']}: started (limit {check['timeout_seconds']}s)", flush=True)
            for item in active[:]:
                process, log, result, started = item
                elapsed = time.monotonic() - started
                code = process.poll()
                if code is None and elapsed < result["timeout_seconds"]:
                    continue
                result["status"] = "timeout" if code is None else ("passed" if code == 0 else "failed")
                stop_group(process)
                log.close()
                result.update(exit_code=process.returncode, duration_seconds=round(elapsed, 3), finished_at=utc_now())
                active.remove(item)
                results.append(result)
                print(f"{result['name']}: {result['status']} ({elapsed:.1f}s), {result['log']}", flush=True)
            if active:
                time.sleep(0.05)
    except KeyboardInterrupt:
        for process, log, result, started in active:
            stop_group(process)
            log.close()
            result.update(status="cancelled", duration_seconds=round(time.monotonic() - started, 3), finished_at=utc_now())
            results.append(result)
        results.extend(dict(check, status="not_run") for check in pending)
    finally:
        # Also clean up owned children if writing a log/receipt or polling fails.
        for process, log, _, _ in active:
            if not log.closed:
                stop_group(process)
                log.close()
    return results


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plan", type=Path)
    parser.add_argument("--jobs", type=int, default=2, help="independent checks at once (default: 2)")
    args = parser.parse_args(argv)
    if os.name != "posix":
        parser.error("process-group cleanup currently requires macOS or Linux")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
    plan = read_plan(args.plan, root)
    output = root / ".harness" / "validation" / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + f"-{os.getpid()}")
    output.mkdir(parents=True)
    receipt = dict(started_at=utc_now(), reason=plan["reason"], source=source_state(root), checks=[])
    started = time.monotonic()
    free = shutil.disk_usage(root).free / 1024 ** 3
    receipt["free_gib_before"] = round(free, 3)
    if free < plan.get("minimum_free_gib", 2):
        receipt.update(status="blocked", error=f"Only {free:.2f} GiB free; plan requires {plan.get('minimum_free_gib', 2)} GiB")
        receipt["checks"] = [dict(check, status="not_run") for check in plan["checks"]]
        print(receipt["error"], file=sys.stderr)
    else:
        receipt["checks"] = run_checks(plan, root, output, args.jobs)
        receipt["source_after"] = source_state(root)
        if receipt["source"] != receipt["source_after"]:
            receipt.update(status="source_changed", error="Source changed during validation; results do not identify one tested tree")
        else:
            receipt["status"] = "passed" if all(c["status"] == "passed" for c in receipt["checks"]) else "failed"
    receipt.update(finished_at=utc_now(), duration_seconds=round(time.monotonic() - started, 3))
    path = output / "receipt.json"
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"{receipt['status']}: {path}")
    return 0 if receipt["status"] == "passed" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"validation error: {error}", file=sys.stderr)
        sys.exit(2)
