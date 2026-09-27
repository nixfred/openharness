#!/usr/bin/env python3
"""Harness attention client and formatter. Standalone CLI and the core the Hermes tool imports.

Reads GET http://127.0.0.1:18473/api/attention (or HARNESS_ATTENTION_URL) and prints:
  <host>: <count> <most urgent state>
  <glyph> <name>  <engine>  <label>  <detail>
  ...
  ! collision: <detail>
Exit 0 on success, 3 when the daemon is unreachable. Stdlib only.
"""
import json
import os
import sys
import urllib.error
import urllib.request

DEFAULT_URL = "http://127.0.0.1:18473/api/attention"
GLYPH = {"working": "~", "waiting": "?", "permission": "!", "failed": "x", "done": "*", "idle": "-", "offline": "."}
URGENT = ("permission", "waiting", "failed")


def fetch(url: str = "", timeout: float = 2.0) -> dict:
    """Return the attention payload as a dict. Raises ConnectionError when the daemon is unreachable."""
    target = url or os.environ.get("HARNESS_ATTENTION_URL", DEFAULT_URL)
    try:
        with urllib.request.urlopen(target, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise ConnectionError(f"Harness daemon unreachable at {target}: {exc}") from exc
    if not isinstance(data, dict):
        raise ConnectionError(f"unexpected payload from {target}")
    return data


def summarize(data: dict) -> dict:
    """Normalise the payload into something small the model and a person both read well."""
    agents = data.get("agents") or []
    alerts = data.get("alerts") or []
    summary = data.get("summary") or {}
    needs_you = [a for a in agents if a.get("state") in URGENT]
    return {
        "host": data.get("hostname", ""),
        "state": summary.get("state", "offline"),
        "count": summary.get("count", 0),
        "needs_you": [{"name": a.get("name"), "state": a.get("state"), "detail": a.get("detail", "")} for a in needs_you],
        "agents": [
            {
                "name": a.get("name") or a.get("agentId"),
                "engine": a.get("engine", ""),
                "machine": a.get("machine", ""),
                "state": a.get("state", "idle"),
                "label": a.get("label") or a.get("state", ""),
                "detail": a.get("detail", ""),
                "glyph": a.get("glyph") or GLYPH.get(a.get("state", ""), "-"),
            }
            for a in agents
        ],
        "alerts": [{"kind": x.get("kind", ""), "detail": x.get("detail", "")} for x in alerts],
    }


def format_lines(s: dict) -> list:
    lines = [f"{s['host'] or 'harness'}: {s['count']} {s['state']}"]
    for a in s["agents"]:
        tail = f"  {a['detail']}" if a["detail"] else ""
        lines.append(f"{a['glyph']} {a['name']:<28} {a['engine']:<10} {a['label']}{tail}")
    for x in s["alerts"]:
        lines.append(f"! collision ({x['kind']}): {x['detail']}")
    return lines


def report(url: str = "") -> str:
    return "\n".join(format_lines(summarize(fetch(url))))


def main(argv: list) -> int:
    url = argv[1] if len(argv) > 1 else ""
    try:
        print(report(url))
        return 0
    except ConnectionError as exc:
        print(str(exc))
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
