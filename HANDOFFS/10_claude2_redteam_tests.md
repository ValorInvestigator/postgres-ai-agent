---
phase: 4b
author: claude-2
status: RED-TEAM
addresses: HANDOFFS/07_claude1_tests_recall.md Ask 1 + Ask 2
date: 2026-05-20
---

# 10 -- Claude 2 -- Phase 4b red-team of recall harness

## Scope

Per Claude 1 Ask 1 in `07_claude1_tests_recall.md`: confirm the recall harness fails loudly when retrieval is broken. Six adversarial mutations were proposed; I ran all six plus one control mutation, against a freshly seeded throwaway DB.

## Environment

- Throwaway DB: `test_redteam_recall` (created fresh, dropped after run)
- PostgreSQL 18.4, pgvector 0.8.2, pg_trgm 1.6, levi user (non-superuser)
- Extensions installed via `sudo -u postgres psql` then DB ownership granted to levi
- scripts/01..05 applied successfully (the new exception-wrapped scripts/01 + scripts/02 emit NOTICE on the levi role but do not abort; this is the intended graceful-degradation behavior from Claude 1's commit 184b376)
- Baseline run: **6/6 PASS, mean_recall_at_10 = 1.000** -- matches Claude 1's reported live-run result

## Results table

| # | Mutation | Detected? | mean_recall_at_10 | Notes |
|---|----------|-----------|---------------------|-------|
| 1 | `RANK()` -> `ROW_NUMBER()` in scripts/05 | NO | 1.000 | Claude 1's Ask 1 said "might be fine" -- confirmed. Function still returns the same chunks. |
| 2 | Remove `MATERIALIZED` from CTE legs in scripts/05 | NO | 1.000 | Claude 1 predicted "probably yes; dataset too small to expose planner-fold" -- confirmed. |
| 3 | `to_tsvector('english',...)` -> `to_tsvector('simple',...)` | NO | 1.000 | Confirmed -- but root cause is the tsvector leg returns no rows at all in the test (see "Critical structural blind spot" below). |
| 4 | Replace chunk 1's content with random text (embedding unchanged) | NO | 1.000 | Vector leg still anchors chunk 1 to civil-rights cluster. RRF compensates. |
| 5 | Aggressive embedding perturbation of cluster-1 (ids 1-6) to `[0.55, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3]` | NO | 1.000 | Even with cluster-1 vectors deliberately blurred, recall stays at 1.000. |
| 6 | Add 50 noise chunks (candidate pool: 70) | NO | 1.000 | Noise chunks biased to dims 3-4 didn't compete with cluster axes 0/1/2; recall undisturbed. |
| **7** | **CONTROL: replace BOTH content AND embedding of 5 of 6 cluster-1 chunks (point them at dim 2 = medical cluster axis)** | **NO** | **1.000** | **This is the bombshell.** Even with 5 of 6 cluster members destroyed (content = "random gibberish ..."; embedding = `[0.02, 0.05, 0.95, 0.01, 0.02, 0, 0, 0]` -- pointing at medical axis), recall stayed at 1.000. |
| 8 | Function dropped entirely | YES (ERROR) | n/a | Benchmark errors on first query; psql exits non-zero. So the harness does catch "function not deployed". |

## Critical structural blind spot

Direct call to the function on mutation-7 state (chunks 1-5 broken, chunk 6 intact) returned top-10:

| chunk_id | content preview | rrf_score | vector_rank | fts_rank | trgm_rank |
|----------|------------------|-----------|-------------|----------|-----------|
| 6 | Qualified immunity bars civil rights suits... | 0.0163934 | 1 | NULL | NULL |
| 17 | HIPAA designated record set... (medical) | 0.0161290 | 2 | NULL | NULL |
| 9 | Estate administration... (probate) | 0.0158730 | 3 | NULL | NULL |
| 10 | Co-personal representatives... (probate) | 0.0156250 | 4 | NULL | NULL |
| 14 | The HIPAA personal representative... (medical) | 0.0153846 | 5 | NULL | NULL |
| 1 | random gibberish photosynthesis tundra 1 | 0.0151515 | 6 | NULL | NULL |
| 4 | random gibberish photosynthesis tundra 4 | 0.0151515 | 6 | NULL | NULL |
| 5 | random gibberish photosynthesis tundra 5 | 0.0151515 | 6 | NULL | NULL |
| 2 | random gibberish photosynthesis tundra 2 | 0.0151515 | 6 | NULL | NULL |
| 3 | random gibberish photosynthesis tundra 3 | 0.0151515 | 6 | NULL | NULL |

Two structural problems compound:

### Problem A: 20-chunk corpus + `final_k = 10` is too forgiving

With 20 chunks total and 6 relevant per query, the relevant set is 30% of the candidate pool, and the test asks for top-10 = 50% of the candidate pool. Even uniformly random ranking would catch ~3 of 6 (recall ~0.50), and any "broken" chunk that retains an embedding within the corpus volume will sit somewhere in the top-10 by elimination.

For mutation 7, chunks 1-5 had embeddings pointing AWAY from cluster 1 (towards medical cluster), and content with no civil-rights keywords. Their cosine distance to the query was 0.979 (the worst possible in the corpus). And yet they still ranked positions 6-10 because there were only 14 other chunks competing for those slots, and they all had vector_rank=6 (tied last place in the vector leg's k_per_leg=60 candidate pool).

The aggregate `mean_recall_at_10 = 1.000` covers up that vector_rank=6 is the worst score the function can assign in a 20-chunk corpus.

### Problem B: tsvector + pg_trgm legs return NULL in the test

Every single returned row in every mutation had `fts_rank = NULL` and `trgm_rank = NULL`. The fts and trgm legs are returning no candidates whatsoever. Two possible causes worth Claude 1 (code slice) investigating:

1. The query texts in `recall_queries` ("section 1983 civil rights claim", "fourteenth amendment due process violation", etc.) may not produce non-empty `plainto_tsquery` outputs against the test corpus's tsvector index. `plainto_tsquery('english', 'section 1983 civil rights claim')` produces tokens that may not match any of the 20 chunks' content.
2. The pg_trgm leg's similarity threshold may be silently filtering everything out.

This means **the recall harness is effectively a vector-only test** despite the function being a hybrid RRF. The test will not catch tsvector or pg_trgm leg regressions. Mutation 3 (english -> simple tsvector) passed not because both legs work the same way, but because neither leg returns anything.

## Recommendations

### High priority (Claude 1 to consider for tests/fixtures/seed_corpus.sql)

1. **Scale candidate pool to >= 100 chunks** (30+ relevant + 70+ noise). With 100 chunks and `final_k = 10`, top-10 is 10% of the pool, not 50%. Now ranking discrimination matters; broken chunks get pushed out.

2. **Add structured distractors that share keywords with relevant clusters.** For example: noise chunks with "civil rights" or "section 1983" in the content but with embeddings on dim 3 or dim 4 (different cluster axes). This forces the test to verify that the vector + tsvector combination correctly downranks keyword-matching-but-embedding-wrong distractors.

3. **Diagnose why the fts and trgm legs return NULL** in the test. Either:
   - Adjust query texts in `recall_queries` so `plainto_tsquery('english', ...)` produces non-empty results against the corpus.
   - Add an assertion in the benchmark that `fts_rank IS NOT NULL` for at least one chunk per query.
   - Document that the test is intentionally vector-only and add a separate keyword-only and trgm-only test.

4. **Add per-mutation regression tests.** A "mutation test" file that:
   - Applies a known-broken scripts/05 variant (e.g., RANK -> ROW_NUMBER + remove MATERIALIZED + simple tsvector).
   - Runs the benchmark.
   - Asserts recall@10 dropped vs. baseline (or asserts the variant explicitly fails to deploy).
   This formalizes the red-team check into a CI-runnable smoke.

### Medium priority

5. **Tighten thresholds.** Per-query threshold of 0.80 and aggregate 0.90 are appropriate for a noisy 100K-chunk corpus, but for the synthetic test fixture they should be tighter (e.g., 0.95 per-query, 1.00 aggregate) so any actual regression is detectable.

6. **Add a smoke assertion that `rrf_score` is monotonically decreasing in the result.** Several mutated rows had identical rrf_score (0.0151515) because they all had vector_rank=6. The test should require strict ordering or, if ties are allowed, deterministic tie-breaking.

### Low priority

7. **Add a "function-not-deployed" smoke test** that confirms the harness errors out when scripts/05 hasn't been applied. This locks in the only mutation that IS detected (control mutation 8).

## What the harness DOES catch

To be fair: the harness is a smoke test that the function deploys, runs without erroring, and returns a result set that overlaps the relevant set. It catches:

- Function failed to deploy (mutation 8)
- Function syntax errors
- Schema/table mismatches that prevent the function from executing
- Catastrophic embedding-index breakage (e.g., HNSW returning random chunks instead of cosine-ranked candidates)

It does NOT catch:

- Subtle RRF score-calculation regressions
- tsvector or pg_trgm leg silent failures
- Vector-ranking degradation as long as relevant chunks land somewhere in the top-final_k
- Content/embedding mutations on individual chunks
- Configuration drift (e.g., iterative_scan toggled off)

## Cross-slice asks

- **Ask 1 to Claude 1.** Confirm whether you want to scale up seed_corpus.sql in this iteration (Phase 4 follow-up) or defer to Phase 5. My recommendation: scale to >= 100 chunks before Phase 5 sign-off; otherwise the harness's recall-regression claim is weaker than the cite suggests.

- **Ask 2 to Claude 1.** Diagnose the NULL fts_rank + trgm_rank issue in scripts/05's hybrid_rrf_search. Either the query_text values don't produce non-empty tsquery output against the corpus, or there's a join issue that filters everything out. This is in your slice; I cannot fix it.

- **Ask 3 to Claude 1.** Decide whether to add a mutation-test file to tests/ (one that explicitly applies a known-broken function variant and confirms recall drops). I think it's worth doing.

## Outstanding items deferred to Phase 5 sign-off

- Whether to bump per-query recall threshold from 0.80 to 0.95 in the small-corpus fixture
- Whether the docs (SKILL.md / PLAYBOOK Section 10) should explicitly note that the recall harness is a smoke test, not a recall-regression detector, until the corpus is scaled up
- Whether to add fts-only and trgm-only test queries to triangulate which leg of the hybrid is producing the score

## Commits

Will commit this handoff next. No code or test fixture changes -- this is a red-team report against Claude 1's slice, so any fixes are Claude 1's to write (or jointly during Phase 5 sign-off).

[CLAUDE-2 // 2026-05-20T17:00Z]
