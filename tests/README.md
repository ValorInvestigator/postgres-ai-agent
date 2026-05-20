# `tests/` -- regression harness

Three harnesses, each guards a different failure mode:

| Harness | What it verifies | Owner | Run |
|---------|------------------|-------|-----|
| `tests/sync_check.sh` | docs <-> code agreement (column-set, function signature, registry defaults) | claude-1 | `bash tests/sync_check.sh` |
| `tests/run_recall.sh` | retrieval recall against labelled queries | claude-1 | `bash tests/run_recall.sh` |
| `tests/latency_benchmark.py` | p50 / p95 / max latency against PLAYBOOK Section 12 budget | claude-2 | `python3 tests/latency_benchmark.py` |

All three exit non-zero on regression. They are designed to be wired into CI when CI exists.

## Prerequisites

- Postgres 14+ with `pgvector >= 0.8.0` and `pg_trgm` (tested on PG 16 and PG 18.4)
- Python 3.8+ with `psycopg2` installed (`pip install psycopg2-binary`)
- Bash 4+ (for the shell harnesses; macOS default bash 3.2 may need `gnu-coreutils`)
- A throwaway database (the harnesses create + drop schemas in it):

```bash
createdb test_postgres_ai_agent

# pgvector is NOT a "trusted" extension on most Linux distros, so CREATE EXTENSION
# requires superuser. pg_trgm is usually trusted.
sudo -u postgres psql -d test_postgres_ai_agent -c 'CREATE EXTENSION vector;'
psql -d test_postgres_ai_agent -c 'CREATE EXTENSION pg_trgm;'

export PG_DSN="dbname=test_postgres_ai_agent host=/var/run/postgresql"
```

## Quick start

Run all three harnesses in order:

```bash
# 1. Static sync gate (no DB required, runs in ~1 second)
bash tests/sync_check.sh

# 2. Recall benchmark (requires PG; ~5 seconds)
bash tests/run_recall.sh

# 3. Latency benchmark (requires PG; ~30-60 seconds depending on --iterations)
python3 tests/latency_benchmark.py
```

`run_recall.sh` applies `scripts/01..05` and `tests/fixtures/seed_corpus.sql` for you. After it succeeds, `tests/latency_benchmark.py` reuses the same fixture (no re-seed needed).

To run latency alone against an already-seeded database:

```bash
# If run_recall.sh was passed --keep-db (else seed manually first)
bash tests/run_recall.sh --seed-only
python3 tests/latency_benchmark.py
```

## What each harness checks

### `tests/sync_check.sh` -- static sync gate

Verifies three drift dimensions between docs and code:

1. **Column-set agreement.** Extracts column list from `scripts/03_create_query_log.sql` and verifies all 16 `PLAYBOOK.md` Section 8 canonical columns are present. Extras allowed.
2. **Function-signature agreement.** Extracts parameter names from `scripts/05_hybrid_rrf_search.sql`. Inspects `SKILL.md` for `hybrid_rrf_search(...)` call sites. If the call site uses named-arg style (`name => value`), the check passes (no positional drift possible). If positional, verifies arg count fits the signature.
3. **Default-defaults agreement.** Extracts `DEFAULT` values from `scripts/02_create_corpus_registry.sql` for the canonical columns. Compares against `PLAYBOOK.md` Section 2 expected values (`chunks` / `content` / `embedding` / `id` / `1024`).

Static mode (default) is offline. `--live` adds three `psql` checks against a deployed DB.

```bash
bash tests/sync_check.sh           # static
bash tests/sync_check.sh --live    # static + 3 live psql checks
```

### `tests/run_recall.sh` + `tests/recall_benchmark.sql` -- recall benchmark

Applies `scripts/01..05` (skips `04_comment_on_workhorses.example.sql`), seeds `case_test_seed` with a synthetic 3-cluster corpus (civil-rights / probate / medical / noise = 20 chunks total), runs six labelled queries through `ops_search_agent.hybrid_rrf_search`, and asserts:

- **per-query**: `recall@10 >= 0.80`
- **aggregate** (mean across all queries): `recall@10 >= 0.90`

The 8-dimensional synthetic embedding makes the vectors readable in source (`tests/fixtures/seed_corpus.sql`) and deterministic on every run. The function accepts unsized `vector` so the 8-dim test corpus is compatible with the production halfvec(1024) deployment.

Available flags:

```
--db <dsn>     # explicit DSN (else uses PG_DSN env var)
--keep-db      # preserve test schema after the run (useful for inspection)
--seed-only    # stop after seeding (lets latency_benchmark.py reuse the corpus)
--no-apply     # skip scripts/01..05 (assume already applied)
```

### `tests/latency_benchmark.py` -- latency benchmark

Times three retrieval modes against the same seed corpus:

| Mode | What it measures |
|------|------------------|
| `vector_only` | Raw HNSW cosine `ORDER BY embedding <=> $1 LIMIT 10` |
| `hybrid_rrf` | `ops_search_agent.hybrid_rrf_search` three-leg RRF |
| `hybrid_rrf_with_rerank` | Hybrid RRF top-100 + stubbed 200 ms cross-encoder pass |

For each mode, runs each labelled query N times (default 30 timed iterations + 3 warmup), reports per-mode p50 / p95 / max in milliseconds, and compares against **two budget layers in parallel** (both must hold for PASS):

- `BUDGET_FLOOR_MS` -- fixture-scaled. Catches seed-corpus regressions (e.g., dropping the GIN tsvector index bumps `hybrid_rrf` p95 from ~1ms to ~3ms; the floor catches it).
- `BUDGET_CEILING_MS` -- PLAYBOOK Section 12 production scale (2M-10M rows). Catches gross structural failures (HNSW missing, planner choosing seq scan, etc.) regardless of fixture size.

Both layers are defined at the top of `latency_benchmark.py`. The aggregate p50/p95/max across 180 samples (30 iters * 6 queries) are SLI-grade (~1% CI); the per-query p50/p95/max from 30 samples are eyeball-grade (~3% CI). Raise `--iterations 100` to tighten per-query precision when needed.

Confidence grade on the rerank stub: C. The cross-encoder is not yet implemented (MCP scaffolding deferred per `HANDOFFS/BUILD_PROTOCOL.md` "Out of scope"). The stub uses a 200 ms `time.sleep()` to represent the BGE-reranker-v2-m3 cost cited in `PLAYBOOK.md` Section 5.3. When the MCP rerank tool is built, replace the `time.sleep(0.200)` with an HTTP call to the deployed endpoint.

Available flags:

```
--dsn <dsn>          # psycopg2 DSN (else uses PG_DSN env var)
--iterations N       # timed iterations per query per mode (default 30)
--warmup N           # warmup iterations per query per mode (default 3)
--json               # emit JSON instead of human-readable report
```

Exit codes:

```
0    all modes within both floor + ceiling budgets
1    one or more modes exceeded budget (regression)
2    setup error (missing function/fixture/HNSW/GIN tsvector/GIN trgm; non-MATERIALIZED CTE legs)
```

## Sample human-readable output

```
preflight PASS: function + fixture + HNSW + GIN(tsv) + GIN(trgm) + chunk count + plan shape OK
benchmarking vector_only ...
benchmarking hybrid_rrf ...
benchmarking hybrid_rrf_with_rerank ...

Latency benchmark report
==============================================================================

vector_only
  iterations/query: 30; warmup/query: 3
  samples (across 6 queries): 180
  p50:   0.85 ms  (floor    1.0 / ceiling    8.0 ms)
  p95:   1.42 ms  (floor    3.0 / ceiling   30.0 ms)
  max:   2.10 ms  (floor   10.0 / ceiling  100.0 ms)
  min:   0.62 ms
    q1 pure civil-rights vector + keyword         p50=  0.82  p95=  1.40  max=  2.10
    [...]

hybrid_rrf
  iterations/query: 30; warmup/query: 3
  samples (across 6 queries): 180
  p50:   3.12 ms  (floor    5.0 / ceiling   40.0 ms)
  [...]

hybrid_rrf_with_rerank
  iterations/query: 30; warmup/query: 3
  samples (across 6 queries): 180
  p50: 203.45 ms  (floor  230.0 / ceiling  340.0 ms)
  [...]

==============================================================================
RESULT: PASS (all modes within both floor + ceiling budgets)
```

## How the three harnesses fit together

```
+---------------------------------------------------------+
| Phase 1: docs vs code drift (no DB)                     |
|   tests/sync_check.sh -- static gate                    |
+---------------------------------------------------------+
                       |
                       v
+---------------------------------------------------------+
| Phase 2: deployed-correctness (requires PG + seed corpus) |
|   tests/run_recall.sh ----+                             |
|                           +-- shared seed corpus        |
|   tests/latency_benchmark.py +                          |
+---------------------------------------------------------+
```

`sync_check` is the fastest signal (offline) and should run on every commit. `run_recall.sh` and `latency_benchmark.py` share the seed corpus; run them together when the deployment changes.

## Troubleshooting

### `preflight FAIL: ops_search_agent.hybrid_rrf_search not found`

Apply `scripts/01..05` first:

```bash
psql -d $PG_DSN -f scripts/01_enable_iterative_scan.sql
psql -d $PG_DSN -f scripts/02_create_corpus_registry.sql
psql -d $PG_DSN -f scripts/03_create_query_log.sql
# NOTE: scripts/04 is now scripts/04_comment_on_workhorses.example.sql --
# it is a Valor-specific reference template, NOT an executable Phase 1 step.
psql -d $PG_DSN -f scripts/05_hybrid_rrf_search.sql
```

Or run `bash tests/run_recall.sh` which applies them in order.

### `preflight FAIL: case_test_seed.chunks not found`

Apply the seed corpus:

```bash
psql -d $PG_DSN -f tests/fixtures/seed_corpus.sql
```

Or `bash tests/run_recall.sh --seed-only`.

### `preflight FAIL: HNSW index missing on case_test_seed.chunks`

The seed corpus creates the HNSW index automatically. If the index is missing, the fixture was not applied cleanly; rerun `psql -d $PG_DSN -f tests/fixtures/seed_corpus.sql`.

### Recall regression: `mean_recall_at_10` below threshold

Walk through `tests/recall_benchmark.sql`'s `recall_results` temp table to find the failing query. Common causes:

- Missing `MATERIALIZED` on CTE legs in `scripts/05_hybrid_rrf_search.sql` -- the planner inlined the iterative HNSW scan
- `RANK()` replaced with `ROW_NUMBER()` -- ties in the trigram leg now break arbitrarily
- Missing GIN index on `content_tsv` (FTS leg fell to seq scan)
- The HNSW index was rebuilt with different parameters

### Latency regression: one mode exceeded its budget

Most likely causes, in descending order of frequency:

1. The HNSW index was deleted or never built -- `vector_only` falls to sequential scan and p95 explodes. Caught by preflight Check 3.
2. `MATERIALIZED` removed from `scripts/05` CTE legs -- the planner folds the legs, duplicating leg work and defeating recall on the iterative scan. Caught by preflight Check 7 (function source inspection -- counts `AS MATERIALIZED` tokens in `pg_get_functiondef`).
3. The GIN index on `content_tsv` was dropped -- the FTS leg falls to sequential scan. Caught by preflight Check 4.
4. The pg_trgm GIN index was dropped -- the trgm leg falls to sequential scan. Caught by preflight Check 5.
5. The Python `psycopg2` connection includes SSL parameters that trigger renegotiation -- only relevant if your DSN includes `sslmode=...`; the local Unix-socket DSN in the prereqs does not negotiate SSL.

Causes 1-4 surface as preflight FAILs (exit 2) BEFORE the timed loop runs, so a budget breach (exit 1) on a passing preflight points at production-scale drift or environment.

## Open work (Phase 5 + future)

- **Strict sync_check Check 2** (claude-1 slice): extract every `name =>` from `SKILL.md` and assert each name is in `scripts/05_hybrid_rrf_search.sql`'s parameter list. Currently the check is permissive (named-arg style passes regardless of argument names). Implementation outline lives in `HANDOFFS/09_claude1_redteam_tests.md`.
- **Larger latency corpus**: 20-row fixture is enough to detect structural regressions but not for production-scale percentiles. A second harness against ~10K real chunks would close the gap. The two-layer budget (floor + ceiling) defers but does not eliminate the need for a real-corpus harness.
- **Larger recall corpus** (claude-1 slice): the 20-chunk seed lets broken cluster members rank in top-10 by elimination; `tests/fixtures/seed_corpus.sql` should scale to >= 100 chunks with structured distractors. Documented in `HANDOFFS/10_claude2_redteam_tests.md`.
- **NULL fts_rank / trgm_rank diagnosis** (claude-1 slice): in the current recall harness, the FTS and pg_trgm legs of `hybrid_rrf_search` return NULL for every test query, making the recall test effectively vector-only. Root-cause + fix is owned by the code slice.
- **Rerank endpoint integration**: replace the `time.sleep(0.200)` stub in `latency_benchmark.py` `run_hybrid_rrf_with_rerank_stub` with an HTTP call once the MCP `rerank` tool is built. The stub is corpus-size-independent by design (200ms regardless of candidate count); the real endpoint will scale with count.
- **CI wiring**: none of the three harnesses currently runs in CI. When a CI service is added, the order is `sync_check.sh -> run_recall.sh -> latency_benchmark.py` with each gate blocking merge on failure.
- **Per-query rerank validation** (joint claude-1 + claude-2): the rerank mode currently retrieves 100 candidates per query but does not validate that the cross-encoder would actually reorder them. When the real BGE endpoint is wired, add a recall@10 check post-rerank to confirm the reorder improves precision. Touches both slices: recall logic + post-rerank latency path.
- **Optional `--explain` mode for `latency_benchmark.py`** (claude-2 slice): dump `EXPLAIN (ANALYZE, BUFFERS)` for each mode to surface why perf changed. Defer unless useful in practice.
