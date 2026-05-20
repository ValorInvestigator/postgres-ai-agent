# 08 -- Claude 2 -- Phase 4a (latency harness + tests/README.md)

## Slice

- `tests/latency_benchmark.py` -- p50/p95/max latency benchmark, three retrieval modes
- `tests/README.md` -- documents all three harnesses (sync_check + recall + latency)

## Status

TESTS

## What landed

### 1. `tests/latency_benchmark.py`

Times three retrieval modes against the same `case_test_seed` fixture Claude-1 built:

| Mode | What it measures |
|------|------------------|
| `vector_only` | Raw HNSW cosine `ORDER BY embedding <=> $1 LIMIT 10` |
| `hybrid_rrf` | `ops_search_agent.hybrid_rrf_search` three-leg RRF (k_per_leg=30, final_k=10) |
| `hybrid_rrf_with_rerank` | RRF top-100 + simulated 200 ms cross-encoder pass (stub) |

For each mode, runs each of the six labelled queries N times (default 30 timed + 3 warmup) and reports per-mode p50 / p95 / max in milliseconds. Final result compared against a per-mode budget in `BUDGET_MS` near the top of the script:

- `vector_only`: p50 <= 8 ms, p95 <= 30 ms, max <= 100 ms
- `hybrid_rrf`: p50 <= 40 ms, p95 <= 120 ms, max <= 300 ms
- `hybrid_rrf_with_rerank`: p50 <= 340 ms, p95 <= 620 ms, max <= 1500 ms

Budget rationale (in docstring): the PLAYBOOK Section 12 numbers describe a 2M-10M row corpus. The seed fixture is 20 rows. The benchmark uses the PLAYBOOK 2M-row bracket as the regression detector ceiling -- if the 20-row corpus exceeds the 2M-row budget, something is structurally broken (missing HNSW, planner choosing seq scan, missing MATERIALIZED on CTE legs, etc.).

Preflight check (exits 2 if missing):
1. `ops_search_agent.hybrid_rrf_search` function exists
2. `case_test_seed.chunks` table exists
3. HNSW index present on `case_test_seed.chunks.embedding`
4. >= 18 chunks loaded (3 clusters * 6 + 2 noise)

Each mode uses the labelled query set mirrored from `tests/recall_benchmark.sql` (qid 1..6 with the same `query_text` + `query_vec`). Reuses Claude-1's seed corpus without re-seeding.

The rerank mode is a stub: it retrieves 100 candidates from `hybrid_rrf_search` and then calls `time.sleep(0.200)` to represent the BGE-reranker-v2-m3 cost cited in PLAYBOOK Section 5.3 (100-300 ms midpoint = 200 ms). Confidence grade C on the stub. When the MCP `rerank` tool is built, replace the `time.sleep` with an HTTP call.

Exit codes:
- `0` all modes within budget
- `1` one or more modes exceeded budget (regression)
- `2` setup error (missing function / fixture / index)

Usage:

```bash
PG_DSN="dbname=test_postgres_ai_agent host=/var/run/postgresql" \
    python3 tests/latency_benchmark.py
```

Or with explicit flags:

```bash
python3 tests/latency_benchmark.py \
    --dsn "dbname=test host=/var/run/postgresql" \
    --iterations 50 \
    --warmup 5 \
    --json
```

### 2. `tests/README.md`

Documents all three harnesses + how they fit together. Sections:

- Prerequisites (pgvector, pg_trgm, Python, psycopg2)
- Quick start (run all three in order)
- What each harness checks (sync_check / run_recall / latency_benchmark)
- Sample human-readable output
- How the three harnesses fit together (sync_check is offline; run_recall + latency share the seed corpus)
- Troubleshooting (preflight failures + common regression causes)
- Open work for Phase 4b + Phase 5

## Confirmation of cross-slice agreement

Per `06b_claude2_sync_gate.md` + Claude-1's `07_claude1_tests_recall.md`:

- The latency benchmark calls `hybrid_rrf_search` with named-arg style (`target_schema => 'case_test_seed'`, `k_per_leg => 30`, etc.) -- matches the post-Phase-3 function signature exactly. No positional drift possible.
- The labelled query set in `tests/latency_benchmark.py` `LABELLED_QUERIES` mirrors `tests/recall_benchmark.sql` qid 1..6 verbatim. The two harnesses can be re-keyed by qid if joint analysis is needed.
- The latency benchmark assumes the same `case_test_seed.chunks` table layout Claude-1 created in `tests/fixtures/seed_corpus.sql`. No fixture duplication.

## Answers to Claude 1's 4 asks (from 07_claude1_tests_recall.md)

### Ask 1 -- Red-team the recall harness

Deferred to my Phase 4b handoff (`10_claude2_redteam_tests.md`). Will run the four adversarial mutations Claude-1 suggested:

- Replace `RANK()` with `ROW_NUMBER()` in scripts/05 -- does recall stay >= 0.90?
- Remove `MATERIALIZED` from scripts/05 CTE legs -- recall stable?
- Replace `to_tsvector('english')` with `to_tsvector('simple')` -- recall stable on query 4?
- Replace one chunk's content with random text -- recall@10 should drop.

I will run each mutation in a throwaway worktree, capture the recall_benchmark output, and report which mutations the test catches (fail-loud) vs which it misses (fail-silent).

### Ask 2 -- Red-team the seed corpus

Also Phase 4b. Will run:

- Increase perturbation to ~0.3 on off-axis dims -- does HNSW still cluster correctly?
- Add 50 noise chunks (candidate pool 70, not 20) and verify recall@10 stays above threshold.

### Ask 3 -- Latency cross-reference

Confirmed: `tests/latency_benchmark.py` calls `hybrid_rrf_search` with the same `target_schema='case_test_seed'`, same labelled queries (verbatim mirror of recall_benchmark.sql qid 1..6), no re-seed. The two harnesses share the fixture cleanly.

### Ask 4 -- tests/README.md references all three

Confirmed. `tests/README.md` Quick-start lists all three in run-order (`sync_check.sh` first because offline, then `run_recall.sh` which seeds, then `latency_benchmark.py` which reuses the seed). Each harness has its own section documenting flags, exit codes, and troubleshooting. Plus the open work section flags the strict sync_check Check 2 + larger latency corpus + rerank endpoint integration + CI wiring.

## Commits landed this phase

- `(to fill after commit)  phase4a: claude-2 latency benchmark + tests/README.md`

## Asks of Claude 1 (for Phase 4b red-team)

1. **Red-team the latency benchmark.** Suggested adversarial mutations to confirm fail-loud:
   - Drop the HNSW index on `case_test_seed.chunks.embedding` -- does `vector_only` p95 exceed its 30 ms budget? (should; HNSW removal forces sequential scan)
   - Drop the GIN index on `content_tsv` -- does `hybrid_rrf` p95 exceed its 120 ms budget?
   - Remove `MATERIALIZED` from scripts/05 CTE legs -- does `hybrid_rrf` p95 measurably increase?
   - Increase `time.sleep` in the rerank stub from 0.200 to 0.700 -- does `hybrid_rrf_with_rerank` p50 exceed its 340 ms budget?

2. **Budget calibration question.** The current per-mode budgets are calibrated to the PLAYBOOK Section 12 numbers for a 2M-row corpus. On a 20-row fixture the actual latencies will be 1-3 orders of magnitude lower. If you want a tighter regression detector, propose tighter budgets (e.g., `vector_only` p95 <= 5 ms instead of 30 ms). The current ceiling catches structural breaks; tighter ceilings would catch minor regressions too.

3. **Rerank stub mode**. The `hybrid_rrf_with_rerank` mode uses a stub. Confirm this is acceptable for Phase 4a, OR propose a deterministic local stand-in (e.g., a Python re-rank by chunk text length, or a fixed permutation) that's still meaningful but doesn't depend on a real BGE endpoint.

4. **Strict sync_check Check 2 follow-up.** You flagged this in 07's Open questions. Once `main` merges both branches, the strict named-arg-name verification can run. I will add the strict check to `sync_check.sh` in Phase 4b if you confirm scope.

## Open questions / deferred

- The 200 ms rerank stub is an order of magnitude. PLAYBOOK Section 5.3 cites 100-300 ms for 100 docs on a consumer GPU; I picked 200 ms as the midpoint. If your hardware budget is different, propose a different stub value (or replace the stub with the real call if/when MCP `rerank` is built).
- `tests/latency_benchmark.py` reports json via `--json`. No HTML/dashboard output. If observability dashboards become a need, the JSON output can feed a Grafana/Prometheus exporter.
- The latency benchmark currently runs against `case_test_seed` (the 20-row fixture). For production-scale validation, point `--dsn` at a deployment with a real corpus + adjust the target_schema in the runners. Deferred to a future iteration.
- `pytest` integration: the benchmark is a standalone script; it could be wrapped as a `pytest` test for unified CI. Out of scope this phase.

[CLAUDE-2 // 2026-05-20T10:45Z]
