#!/usr/bin/env python3
"""
eval-extract-usage.py — extract usage fields from a `claude -p --output-format
json` output file. Emits a single JSON object on stdout with:

    input_tokens
    output_tokens
    cache_creation_input_tokens
    cache_read_input_tokens
    model

Used by eval-{ralph,fanout,sectioning,orchworkers}.sh so cache-fields support
(plan-evals C.4 / bead fo-vgam1) lives in one place.

claude's per-turn `usage` field captures the **incremental turn cost** —
input_tokens excludes cached prefix. cache_creation_input_tokens (first time
the prefix is seen) + cache_read_input_tokens (re-use) reflect the full
contract length, which is what claim 3 in position.md needs.

Usage:
    python3 scripts/eval-extract-usage.py <claude-out.json>

Output (always valid JSON; zero/empty defaults on any parse failure):
    {"input_tokens": 12, "output_tokens": 345,
     "cache_creation_input_tokens": 4200, "cache_read_input_tokens": 0,
     "model": "claude-sonnet-4-6"}
"""
import json
import sys


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    out = {
        "input_tokens": 0,
        "output_tokens": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
        "model": "",
    }
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception:
        print(json.dumps(out))
        return

    usage = data.get("usage") or {}
    for key in ("input_tokens", "output_tokens",
                "cache_creation_input_tokens", "cache_read_input_tokens"):
        v = usage.get(key)
        if isinstance(v, int):
            out[key] = v
        else:
            # Some legacy shapes use prompt_tokens/completion_tokens.
            if key == "input_tokens":
                alt = usage.get("prompt_tokens")
                if isinstance(alt, int): out[key] = alt
            elif key == "output_tokens":
                alt = usage.get("completion_tokens")
                if isinstance(alt, int): out[key] = alt

    model_usage = data.get("modelUsage") or {}
    if model_usage:
        out["model"] = next(iter(model_usage))

    print(json.dumps(out))


if __name__ == "__main__":
    main()
