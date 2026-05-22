#!/usr/bin/env bash
# bd-locked.sh — serialize bd invocations across processes via flock.
#
# Under SHIM=ntm, every Claude pane runs bd as its own subprocess. With N
# concurrent panes (and the driver's own bd writes happening in parallel),
# bd v1.0.3's embedded-dolt + auto-import-on-each-invocation cycle races:
# concurrent writers' JSONL re-imports clobber each other's in-dolt writes.
#
# This wrapper serializes ALL bd invocations under a single advisory lock,
# making the substrate behave as if there were one writer. It's not a
# permanent fix (the real fix is bd-side, ideally a single-server mode),
# but it's a cheap test of the hypothesis: if flock-serialized bd makes
# multi-agent ntm scenarios pass, the substrate concurrency theory holds.
#
# Lock file: /tmp/bd.lock (writable by uid 1000).
# Timeout: 60 seconds — long enough for normal bd ops (queries + writes),
# short enough that a true deadlock surfaces as an error rather than a hang.

exec flock -w 60 /tmp/bd.lock /usr/local/bin/bd.real "$@"
