#!/usr/bin/env python3
"""Aggregate token usage from per-session JSONL files (plan-evals fo-4nglm).

Claude Code writes one JSONL per session under ~/.claude/projects/<hash>/<session>.jsonl.
Each line may contain a ``message.usage`` object with input_tokens, output_tokens,
cache_creation_input_tokens, and cache_read_input_tokens.

Usage:
    python3 scripts/eval-aggregate-tokens.py --jsonl-dir <path>

Emits JSON on stdout:
    {
        "tokens_in": N,
        "tokens_out": N,
        "cache_creation_input_tokens": N,
        "cache_read_input_tokens": N,
        "session_count": N,
        "file_count": N
    }

Exits 0 always — malformed lines are logged to stderr and skipped.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Aggregate token usage from a directory of per-session JSONL files."
    )
    parser.add_argument(
        "--jsonl-dir",
        required=True,
        help="Root directory to search recursively for .jsonl files.",
    )
    args = parser.parse_args()

    root = Path(args.jsonl_dir)
    if not root.is_dir():
        print(f"[aggregate-tokens] --jsonl-dir does not exist: {root}", file=sys.stderr)
        sys.exit(1)

    tokens_in: int = 0
    tokens_out: int = 0
    cache_creation: int = 0
    cache_read: int = 0
    file_count: int = 0
    # Count distinct session IDs (file stems) rather than files, in case
    # the same session appears under multiple project hashes.
    session_ids: set[str] = set()

    for jsonl_path in sorted(root.rglob("*.jsonl")):
        file_count += 1
        session_ids.add(jsonl_path.stem)
        try:
            with jsonl_path.open(encoding="utf-8", errors="replace") as fh:
                for lineno, raw in enumerate(fh, start=1):
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        obj = json.loads(raw)
                    except json.JSONDecodeError as exc:
                        print(
                            f"[aggregate-tokens] {jsonl_path}:{lineno}: malformed JSON — {exc}",
                            file=sys.stderr,
                        )
                        continue

                    usage = None
                    try:
                        usage = obj["message"]["usage"]
                    except (KeyError, TypeError):
                        pass

                    if usage is None:
                        continue

                    tokens_in += usage.get("input_tokens", 0) or 0
                    tokens_out += usage.get("output_tokens", 0) or 0
                    cache_creation += usage.get("cache_creation_input_tokens", 0) or 0
                    cache_read += usage.get("cache_read_input_tokens", 0) or 0
        except OSError as exc:
            print(
                f"[aggregate-tokens] cannot read {jsonl_path}: {exc}",
                file=sys.stderr,
            )

    result = {
        "tokens_in": tokens_in,
        "tokens_out": tokens_out,
        "cache_creation_input_tokens": cache_creation,
        "cache_read_input_tokens": cache_read,
        "session_count": len(session_ids),
        "file_count": file_count,
    }
    print(json.dumps(result))


if __name__ == "__main__":
    main()
