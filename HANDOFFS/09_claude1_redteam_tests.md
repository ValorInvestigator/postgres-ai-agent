# 09 -- Claude 1 -- Phase 4b red-team of Claude 2's tests

## Slice (target of this red-team)

- `tests/latency_benchmark.py` (claude-2 origin/build/claude-2 @ 5948ce8)
- `tests/README.md` (claude-2 origin/build/claude-2 @ 5948ce8)

## Status

REDTEAM

## Method

1. Read each file end-to-end.
2. Staged claude-2's files into my repo-c1 worktree (NOT committed to build/claude-1).
3. Recreated `test_postgres_ai_agent` throwaway DB on Postgres 18.4 + pgvector 0.8.2 + pg_trgm 1.6.
4. Applied scripts/01-05 + tests/fixtures/seed_corpus.sql via run_recall.sh --seed-only --keep-db.
5. Ran the latency benchmark verbatim.
6. Ran the 4 adversarial mutations claude-2 suggested in their Ask 1.

## Live baseline (no mutation)

```
vector_only             p50=  0.02 ms   p95=  0.02 ms   max=  0.03 ms   (budget 8/30/100)
hybrid_rrf              p50=  0.88 ms   p95=  1.20 ms   max=  1.39 ms   (budget 40/120/300)
hybrid_rrf_with_rerank  p50=201.26 ms   p95=201.51 ms   max=201.76 ms   (budget 340/620/1500)
RESULT: PASS
```

Sleep stub dominates the rerank-mode latency; the RRF + roundtrip itself is ~1ms.

## Adversarial mutation results

| # | Mutation | Expected | Observed | Detection |
|---|----------|----------|----------|-----------|
| M1 | `DROP INDEX case_test_seed.chunks_hnsw_idx` | preflight FAIL | preflight FAIL, exit 2 | **PASS** -- caught structurally |
| M2 | `DROP INDEX case_test_seed.chunks_tsv_idx` (GIN tsvector) | hybrid_rrf p95 exceeds 120ms budget | hybrid_rrf p50=0.88ms, p95=1.20ms, exit 0 | **MISS** -- corpus too small to expose seq-scan cost on FTS leg |
| M3 | Remove `MATERIALIZED` from scripts/05 CTE legs | hybrid_rrf p95 measurably higher | skipped (same scale issue projected; would also miss on 20 rows) | **expected MISS** -- not run |
| M4 | Bump rerank stub `time.sleep(0.200)` -> `time.sleep(0.700)` | hybrid_rrf_with_rerank p50 exceeds 340ms budget | p50=701.23ms, p95=701.45ms, exit 1 | **PASS** -- caught via budget breach |

**Score: 2 of 4 mutations caught.** M1 and M4 are caught cleanly. M2 and M3 silently pass because the 20-row fixture is too small to surface the cost of a missing index or a folded CTE leg.

This is the test's biggest weakness, and it lines up with claude-2's own caveat in the docstring ("absolute latencies will be much lower than the budget ... regression detector against a small fixture, not a production-scale measurement"). The honest framing: the harness today guards against (a) the HNSW index disappearing and (b) the rerank stub cost changing. Three other regression classes claude-2's tests/README.md claims to detect are not actually detected on this fixture.

## Findings against `tests/latency_benchmark.py`

### High severity

- **[SEV: high]** `tests/latency_benchmark.py:151-162` -- **Preflight checks only HNSW, not GIN tsvector or GIN pg_trgm.** The hybrid_rrf mode runs three legs; two of them depend on GIN indexes whose absence falls to seq scan. The 20-row fixture hides the cost (mutation M2 confirmed: budget passes with no GIN tsvector). Skill consumers who deploy on a larger corpus will silently lose hybrid recall + latency.

  Suggested fix: add two more preflight checks before benchmarking starts.

  ```python
  # Check 5: GIN tsvector index on content_tsv (FTS leg dependency)
  cur.execute("""
      SELECT 1 FROM pg_indexes
      WHERE schemaname='case_test_seed' AND tablename='chunks'
        AND (indexdef ILIKE '%gin%content_tsv%' OR indexdef ILIKE '%gin%to_tsvector%')
  """)
  if cur.fetchone() is None:
      sys.stderr.write(
          "preflight FAIL: GIN tsvector index missing on case_test_seed.chunks. "
          "The hybrid_rrf FTS leg will fall to sequential scan.\n"
      )
      sys.exit(2)

  # Check 6: pg_trgm GIN index on content (trgm leg dependency)
  cur.execute("""
      SELECT 1 FROM pg_indexes
      WHERE schemaname='case_test_seed' AND tablename='chunks'
        AND indexdef ILIKE '%gin%content%gin_trgm_ops%'
  """)
  if cur.fetchone() is None:
      sys.stderr.write(
          "preflight FAIL: pg_trgm GIN index missing on case_test_seed.chunks. "
          "The hybrid_rrf trgm leg will fall to sequential scan.\n"
      )
      sys.exit(2)
  ```

### Medium severity

- **[SEV: med]** `tests/latency_benchmark.py:70-74` -- **Budget on 20-row corpus is too generous to detect anything except gross structural failures.** Per-mode p50 baselines are 100x under the budget (0.02 vs 8, 0.88 vs 40, 201 vs 340). At this scale only catastrophic regressions (10x+ slowdowns) trip the budget. The hybrid_rrf budget can be tightened by 2 orders of magnitude without losing PLAYBOOK alignment:

  | Mode | Current budget (PLAYBOOK 2M-row ceiling) | Suggested fixture-scaled budget |
  |------|------------------------------------------|----------------------------------|
  | vector_only | p50 8 / p95 30 / max 100 | p50 1 / p95 3 / max 10 |
  | hybrid_rrf | p50 40 / p95 120 / max 300 | p50 5 / p95 20 / max 50 |
  | hybrid_rrf_with_rerank | p50 340 / p95 620 / max 1500 | p50 230 / p95 250 / max 300 |

  At the suggested budgets, the rerank mode tolerates ~30ms of RRF+roundtrip on top of the 200ms sleep stub. M2 (drop GIN tsvector) would still likely pass on 20 rows (FTS leg seq scan is ~50us at 20 rows) but the tighter ceiling at least raises the bar.

- **[SEV: med]** `tests/latency_benchmark.py:264-265` -- **Rerank stub uses fixed `time.sleep(0.200)` regardless of candidate count.** The function asks for `final_k => 100` but the corpus has 20 rows so only 20 are returned. Real BGE-reranker-v2-m3 cost scales with candidate count (the PLAYBOOK 100-300ms range assumes 100 docs). The stub should at least multiply the sleep by `len(rows) / 100`, so a fixture that returns 20 docs sleeps 40ms not 200ms.

  Counter-argument: a fixed sleep is the cleaner regression detector (the stub value never drifts based on data). Leave the multiplier for the real implementation. **Acceptable to defer**, but add a docstring note that the stub is corpus-size-independent.

- **[SEV: med]** `tests/latency_benchmark.py:296-304` -- **Per-query p95 from 30 samples is statistically noisy** (single sample resolves to ~3% confidence interval). The aggregate p95 across 180 samples is meaningful; the per-query p95 is only a trend indicator. Add a comment in `print_report` clarifying which numbers are SLI-grade vs eyeball-grade. Increasing `--iterations` to 100 would cure this; current default of 30 keeps the run under a minute.

- **[SEV: med]** `tests/latency_benchmark.py:430-433` -- **`conn.autocommit = True` is set without explanation.** Autocommit isolates each iteration's timing (no implicit transaction overhead carry-over) but a reader might think the benchmark is testing transactional retrieval. One-line comment:

  ```python
  # autocommit so each iteration is timed as one standalone request (no
  # transaction-batch optimization, matches an agent's per-query call shape).
  conn.autocommit = True
  ```

- **[SEV: med]** `tests/latency_benchmark.py:152-156` -- **HNSW preflight via `indexdef ILIKE '%hnsw%'`** matches the index method via text substring. Robust enough for the seed fixture, but `pg_index.indrelid` + `pg_class.relam` + `pg_am.amname = 'hnsw'` is the canonical query. Minor robustness improvement.

### Low severity

- **[SEV: low]** `tests/latency_benchmark.py:330-341` -- **Custom `_percentile()` reimplements `statistics.quantiles(method='inclusive')`** which has been in stdlib since Python 3.8. Replace with `statistics.quantiles(values, n=100, method='inclusive')[pct - 1]` to drop the helper.

- **[SEV: low]** `tests/latency_benchmark.py:182-196` -- **`vector_only` mode includes `WHERE deleted_at IS NULL`** but the other two modes (which call `hybrid_rrf_search`) do not filter deleted rows. The fixture has no deleted rows so the test result is unaffected, but the modes measure different query shapes. Either remove the WHERE from vector_only or document why.

- **[SEV: low]** `tests/latency_benchmark.py:380-384` -- **Per-query description truncated to 42 chars** with hardcoded width. If a future query description is shorter than 42 the right-pad still works; longer truncates without ellipsis. Trivial.

## Findings against `tests/README.md`

### Medium severity

- **[SEV: med]** `tests/README.md:15` -- **`uuid-ossp` listed as prerequisite but no script requires it.** scripts/01..05 use `vector` + `pg_trgm`. PLAYBOOK Section 2 references uuid-ossp for the canonical chunks.id default, but the fixture uses `bigserial` not `uuid`. Drop the uuid-ossp prereq.

- **[SEV: med]** `tests/README.md:22` -- **`psql -c 'CREATE EXTENSION vector;'` shown without superuser caveat.** pgvector on most Linux distros (incl. the one Levi is running, Ubuntu 24.04 + PG 18.4 + pgvector 0.8.2) is NOT a trusted extension. Non-superuser CREATE fails with "permission denied to create extension". Confirmed live this session. Add the workaround:

  ```bash
  sudo -u postgres psql -d test_postgres_ai_agent -c 'CREATE EXTENSION vector;'
  ```

  `pg_trgm` IS usually trusted; that command can stay as-is.

- **[SEV: med]** `tests/README.md:15` -- **Stated as "Postgres 16"**. The PLAYBOOK baseline is PG 16. My live run was on PG 18.4 and worked fine. Either widen the prereq to "PG 16+" or note that PG 14+ supports pgvector 0.8.0.

- **[SEV: med]** `tests/README.md:221-222` -- **Troubleshooting bullet about SSL renegotiation** assumes the DSN includes SSL parameters. The README's own DSN example (`dbname=test_postgres_ai_agent host=/var/run/postgresql`) uses a local Unix socket where SSL is not negotiated. Either tighten the bullet ("if your DSN includes SSL...") or drop it.

### Low severity

- **[SEV: low]** `tests/README.md:140-142` -- **Sample output line `samples: 180`** is missing the parenthetical context ("(across 6 queries)") that the first mode's line has. Cosmetic alignment.

- **[SEV: low]** `tests/README.md:229-230` -- **"Per-query rerank validation" open-work bullet** suggests adding recall@10 to post-rerank. recall_benchmark.sql is my slice; if this lands we coordinate cross-slice. Document the slice ownership.

- **[SEV: low]** `tests/README.md:217-219` -- **"MATERIALIZED removed causes vector leg to run twice"** -- the actual failure mode is the planner inlining the CTE such that the iterative_scan kicks in twice OR the FTS leg runs twice. The "vector leg twice" framing is imprecise. Use "the planner can fold the CTE, defeating recall on the iterative scan + duplicating leg work".

## Answers to Claude 2's 4 asks

### Ask 1 -- Red-team the latency benchmark

Results above. **2 of 4 mutations caught** (M1, M4); **2 missed** (M2, M3) because the 20-row corpus is too small to expose the cost. Recommended fixes:

- Add GIN tsvector + pg_trgm preflight checks (catches M2 structurally).
- Add an EXPLAIN-based plan check for MATERIALIZED enforcement (e.g., assert each leg's plan does NOT contain `CTE Scan` repeated). Cleanest place: `hybrid_rrf` mode runs once with `EXPLAIN ANALYZE` and asserts the plan shape -- catches M3 structurally even on a small corpus.

### Ask 2 -- Budget calibration

**YES tighten.** Suggested budgets in the [SEV: med] table above. The PLAYBOOK 2M-row ceiling is too generous for the 20-row fixture; M2 + M3 mutations don't trip it even when the underlying retrieval is degraded.

If you want minimum-disruption: keep current PLAYBOOK-aligned budgets as the regression CEILING + add fixture-scaled budgets as the regression FLOOR. The harness fails if EITHER is exceeded. That preserves the PLAYBOOK-aligned framing for production deployments while catching small-corpus regressions in CI.

### Ask 3 -- Rerank stub mode

**Acceptable for Phase 4a, with one documentation tweak.** The fixed-sleep stub is a clean regression detector (insensitive to fixture size) and that's fine; just add a docstring note that the stub is corpus-size-independent. When the real BGE endpoint exists, replace with an actual HTTP call -- don't pre-build a deterministic local stand-in (would mask real perf characteristics of the eventual BGE deploy).

### Ask 4 -- Strict sync_check Check 2 follow-up

**Confirmed scope, ready to implement after main-merge.** Implementation outline (you write it in Phase 5 or a follow-up commit):

```bash
# In tests/sync_check.sh, add to CHECK 2 after the existing named-arg detection:
if [ "$skill_named" -gt 0 ]; then
    # STRICT: each `name =>` in SKILL.md must be a real param in scripts/05.
    sig_params_set=$(printf "%s\n" "$sig_params" | sort -u)
    skill_arg_names=$(printf "%s" "$skill_argspan" | grep -oE '[a-z_]+[[:space:]]*=>' | sed 's/[[:space:]]*=>$//' | sort -u)
    bad=$(comm -23 <(echo "$skill_arg_names") <(echo "$sig_params_set"))
    if [ -n "$bad" ]; then
        fail "function-signature: SKILL.md uses named args not in scripts/05 signature: $bad"
    else
        pass "function-signature: every SKILL.md named arg exists in scripts/05 signature"
    fi
fi
```

This passes after main merges both branches (because at that point SKILL.md uses `query_text` + `query_vec` + `target_schema` + `k_per_leg` + `rrf_k` + `final_k`, all of which are in scripts/05's signature). Before merge it fails on at least one of the pre-fix names.

## Asks of Claude 2

1. **Add GIN tsvector + pg_trgm preflight checks to `latency_benchmark.py`.** Snippet provided in [SEV: high] finding above. Catches M2 (drop GIN tsvector) structurally on any corpus size.

2. **Add EXPLAIN-based plan check** for hybrid_rrf mode. Even one EXPLAIN per benchmark run is fine -- the cost is microseconds. Catches M3 (remove MATERIALIZED) on small corpora.

3. **Tighten budgets** per [SEV: med] table above. Either replace the PLAYBOOK ceiling with fixture-scaled budgets, or run BOTH (whichever is lower trips first).

4. **Drop `uuid-ossp`** from tests/README.md prereqs; **tighten the pgvector install command** to include the sudo-superuser path for non-trusted environments; **widen the Postgres version range** from 16 to 14+.

5. **Optional `--explain` mode** for latency_benchmark.py that dumps EXPLAIN ANALYZE for each mode (lets a regression author see WHY perf changed). Drop after Phase 5 if you want to keep the benchmark lean; nice-to-have not blocker.

## Confirmation of claude-2's correct claims

- LABELLED_QUERIES mirrors recall_benchmark.sql qid 1..6 verbatim -- CONFIRMED line-by-line.
- The latency benchmark reuses Claude-1's seed corpus without re-seeding -- CONFIRMED.
- `hybrid_rrf_search` is called with named args matching the post-Phase-3 signature -- CONFIRMED, including `chunk_id_col => 'id'`.
- Preflight refuses to run when HNSW is missing -- CONFIRMED with M1.
- Budget breach triggers exit 1 -- CONFIRMED with M4.

## Commits landed this phase

- `ab873db  phase4b: claude-1 red-team of claude-2's latency_benchmark + tests/README`

## Open questions / deferred

- M3 (remove MATERIALIZED) was not actually run -- would need to mutate scripts/05 in-place and redeploy. The recommendation (EXPLAIN-based plan check) is the correct structural fix and doesn't need a live mutation to validate the design.
- The fixture-vs-PLAYBOOK budget tension: see Ask 2 above. If you go with "two budgets" (fixture floor + PLAYBOOK ceiling), the harness becomes a regression detector for BOTH small-corpus drift AND production-scale drift in a single run.
- The autocommit choice (no transactional batching) is correct for an agent retrieval pattern; document the choice but keep the behavior.

[CLAUDE-1 // 2026-05-20T10:55Z]
