---
phase: 5-prep
author: claude-2
status: VALIDATION
addresses: HANDOFFS/09b_claude1_phase4b_fixes.md
date: 2026-05-20
---

# 13 -- Claude 2 -- Sign-off validation of Claude 1's recall harness v2

## Slice (validation target)

- `tests/fixtures/seed_corpus.sql` (60 chunks; 18 cluster + 10 structured distractors + 32 noise) -- claude-1 commit `c4e6a5d`
- `tests/recall_benchmark.sql` (precision@6 + leg-coverage gates + tighter thresholds) -- claude-1 commit `c4e6a5d`

## Status

VALIDATION (pre-sign-off check)

## What was validated

Re-ran my Phase 4b red-team bombshell against the v2 harness to confirm the structural blind spot is closed.

### Baseline (no mutation) -- v2 harness on fresh DB

```
qid 1: civil-rights pure          recall_at_10=0.833  precision_at_6=0.667  fts_nn=10  trgm_nn=10  PASS
qid 2: probate pure               recall_at_10=1.000  precision_at_6=0.500  fts_nn=6   trgm_nn=7   PASS
qid 3: medical pure               recall_at_10=1.000  precision_at_6=0.667  fts_nn=8   trgm_nn=8   PASS
qid 4: civil-rights paraphrase    recall_at_10=0.667  precision_at_6=0.500  fts_nn=3   trgm_nn=9   PASS
qid 5: probate subtopic           recall_at_10=0.833  precision_at_6=0.500  fts_nn=7   trgm_nn=10  PASS
qid 6: medical subtopic           recall_at_10=1.000  precision_at_6=0.833  fts_nn=3   trgm_nn=4   PASS

mean_recall_at_10=0.889  min=0.667
mean_precision_at_6=0.611  min=0.500
RESULT: recall_benchmark PASSED
```

**Confirmed:** every query now has fts_nonnull >= 1 AND trgm_nonnull >= 1 (3 to 10 rows per leg per query). The NULL-leg blind spot from my 10_redteam_tests is fully resolved.

### Mutation 7 (claude-2's bombshell from 10_) -- v2 harness re-test

Mutation: destroy 5 of 6 cluster-1 chunks (content -> "random gibberish ..." AND embedding -> `[0.02, 0.05, 0.95, 0.01, 0.02, 0, 0, 0]` pointing at medical axis instead of civil-rights axis).

Before (claude-1 v1 harness): mean_recall_at_10 = 1.000, PASS (mutation undetected).
**After (claude-1 v2 harness):**

```
qid 1: civil-rights pure          recall_at_10=0.167  precision_at_6=0.167  FAIL
qid 4: civil-rights paraphrase    recall_at_10=0.167  precision_at_6=0.000  FAIL
qid 2,3,5,6 PASS (unaffected -- not cluster 1)

mean_recall_at_10=0.694  min=0.167  mean_precision_at_6=0.444  min=0.000
ERROR: recall_benchmark FAILED: min recall_at_10 = 0.167 < 0.65 (per-query gate)
```

**The mutation is now detected.** The bombshell -- destroying 5 of 6 cluster-1 chunks -- causes the test to error out with a precise per-query failure message (queries 1 and 4 dropped to 16.7% recall, blocking the 65% gate).

## Recommendation: proceed to Phase 5 joint sign-off

Both halves of the harness now do what we promised:

- **`tests/recall_benchmark.sql`** (claude-1 slice) catches recall regressions on cluster-broken chunks, exercises all three legs (vector + FTS + trgm), enforces precision + leg-coverage gates.
- **`tests/latency_benchmark.py`** (claude-2 slice) catches HNSW / GIN-tsv / GIN-trgm / non-MATERIALIZED structural failures via preflight, runs two-layer (floor + ceiling) budgets, exits 2 on missing index, exits 1 on budget breach.

Open items for Phase 5 sign-off doc (`11_joint_signoff.md`, co-edited):

1. Decide whether to scale recall corpus from 60 to 100 chunks (claude-1 deferred; my 10_ asked for >=100; 60 is sufficient for current discrimination so not blocking).
2. Decide whether to add explicit per-mutation regression tests file (both Claudes deferred; not blocking).
3. Document the two retired open-questions: (a) result_chunk_ids BIGINT[] decided; (b) :role psql variable convention (currently scripts use `:'role'`; `valor_agent` is example only).
4. Run `tests/sync_check.sh --live` against the merged branch and document the result.
5. Optional: add `tests/sync_check.sh` strict Check 2 (claude-1's deferred item from Ask 4 in 06_claude2_fixes.md).

## Open items that I am NOT raising as blockers

- **100-chunk corpus target.** Kept at 60 per claude-1's judgment. Mutation 7 catches at 60; further scaling is incremental.
- **Per-mutation regression test file.** Deferred jointly. The leg-coverage + precision@6 gates already close most of the gap.
- **rrf_score monotonicity check.** Defensive but not load-bearing; defer.
- **Function-not-deployed smoke.** Already caught by `run_recall.sh` preflight and `latency_benchmark.py` Check 1.
- **My disagreement on `_percentile()` helper.** Stands; documented in 12_claude2_redteam_fixes.md. No blocking action.

## Cross-acknowledgments

- claude-1's 09b reverse-engineered the NULL-leg root cause cleanly: `plainto_tsquery('english', ...)` AND-joins all tokens, so 5-token queries against 20-row corpus had zero matches. The fix (shorter queries + `SET pg_trgm.similarity_threshold = 0.05`) is correct.
- claude-1's structured distractors (ids 21-30 sharing keywords with relevant clusters but with wrong-axis embeddings) are exactly what I recommended in 10_redteam_tests recommendation 2. Discrimination now exercises the RRF combination, not just vector recall.
- The 0.65 / 0.50 per-query + 0.85 aggregate thresholds are tight enough that mutation 7 trips immediately. Calibration is correct.

## Validation commands (for reproducibility)

```bash
# Fresh DB
sudo -u postgres createdb -O levi test_v2_recall
sudo -u postgres psql -d test_v2_recall -c "CREATE EXTENSION vector; CREATE EXTENSION pg_trgm;"

# Apply scripts + seed v2
for n in 01_enable_iterative_scan 02_create_corpus_registry 03_create_query_log 05_hybrid_rrf_search; do
    git show origin/build/claude-1:scripts/${n}.sql | psql -d test_v2_recall -v role=levi
done
git show origin/build/claude-1:tests/fixtures/seed_corpus.sql | psql -d test_v2_recall

# Baseline
git show origin/build/claude-1:tests/recall_benchmark.sql | psql -d test_v2_recall

# Mutation 7
psql -d test_v2_recall -c "
UPDATE case_test_seed.chunks SET 
  content = 'random gibberish photosynthesis tundra ' || id,
  embedding = '[0.02, 0.05, 0.95, 0.01, 0.02, 0.00, 0.00, 0.00]'::vector
WHERE id IN (1, 2, 3, 4, 5);
"

# Re-run -- should error out with recall_benchmark FAILED
git show origin/build/claude-1:tests/recall_benchmark.sql | psql -d test_v2_recall

sudo -u postgres psql -c "DROP DATABASE test_v2_recall;"
```

## Commits landed this phase

- `<sha>  phase5-prep: claude-2 validation of claude-1 recall harness v2`

[CLAUDE-2 // 2026-05-20T18:30Z]
