# Eval case: tpc-validator

A single `PortValidator` class with a `validate(port: int) -> Result` method.
Valid ports are 1–49151 (TCP/UDP registered range); the ephemeral range
49152–65535 is reserved; zero/negatives are out-of-range; non-int types
(including `bool`) are rejected.

Designed as the **Two-Phase Commit (TPC)** canonical case for plan-evals:

- **Phase 1 (contract-author)** reads the spec and writes `tests/test_contract.py`
  plus a minimal stub in `validator/__init__.py`. It does NOT implement the
  validator.
- **Phase 2 (implementer)** reads the spec and the locked contract tests, then
  implements `validator/__init__.py`. It MAY NOT modify any test file.

The runner (`scripts/eval-tpc.sh`) enforces the test-file lock by snapshotting
`tests/` after Phase 1 and diffing at Phase 2 exit. Any modification is a
protocol violation and the run is marked failed.

## Contents

```
tpc-validator/
├── README.md                           (this file)
├── spec.md                             (PortValidator requirements)
├── fanout.json                         ({"dir": "validator", "exclude": []})
├── starting-state/
│   ├── validator/
│   │   └── __init__.py                 (empty — Phase 1 writes the stub)
│   └── tests/
│       └── (empty — Phase 1 writes test_contract.py here)
├── visible-tests/
│   └── test_phase1_contract_exists.py  (asserts Phase 1 output is non-trivial)
└── hidden-tests/
    └── test_quality.py                 (~20 edge-case tests; scorer-only)
```

## Scoring

- **Visible:** `pytest visible-tests/` — checks Phase 1 produced a non-trivial
  contract (≥5 test functions in `tests/test_contract.py`).
- **Hidden:** `pytest hidden-tests/` — scorer-only edge cases; divergence from
  Phase 1's contract coverage is the experimental signal.
- **Existing:** `pytest tests/` — Phase 1's contract tests must pass after
  Phase 2 implements the validator.

## Comparison baseline

Run `bash scripts/eval-ralph.sh tpc-validator` for a single-agent baseline
(writes tests + implementation in one session). Compare TPC vs ralph on
hidden-test pass rate to evaluate whether forced phase separation improves
edge-case coverage.
