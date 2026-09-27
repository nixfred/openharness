"""Tool and slash-command handlers. Handlers take (args, **kwargs) and return a JSON string; they
never raise (per the Hermes developer guide)."""
import importlib.util
import json
from pathlib import Path

_URL = "http://127.0.0.1:18473/api/attention"


def _core():
    """Load the sibling attention.py (shared with the standalone CLI) without a package import."""
    here = Path(__file__).resolve().parent
    for candidate in (here / "attention.py", here.parent / "attention.py"):
        if candidate.exists():
            spec = importlib.util.spec_from_file_location("harness_attention_core", candidate)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    raise FileNotFoundError("attention.py not found next to tools.py")


def configure(url: str) -> None:
    global _URL
    if url:
        _URL = url


def harness_attention(args: dict, **kwargs) -> str:
    try:
        core = _core()
        summary = core.summarize(core.fetch(_URL))
        if args.get("only_urgent"):
            summary = {k: summary[k] for k in ("host", "state", "count", "needs_you", "alerts")}
        return json.dumps(summary)
    except ConnectionError as exc:
        return json.dumps({"error": str(exc), "hint": "Start the daemon with `harness start` on this machine."})
    except Exception as exc:  # never raise out of a tool handler
        return json.dumps({"error": f"harness_attention failed: {exc}"})


def attention_command(raw_args: str) -> str:
    try:
        return _core().report(_URL)
    except ConnectionError as exc:
        return str(exc)
    except Exception as exc:
        return f"harness_attention failed: {exc}"
