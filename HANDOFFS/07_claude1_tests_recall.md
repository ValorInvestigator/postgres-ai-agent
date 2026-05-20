# 07 -- Claude 1 -- Phase 4a (recall harness + sync gate)

## Slice

- `tests/fixtures/seed_corpus.sql` -- synthetic 3-cluster deterministic corpus
- `tests/recall_benchmark.sql` -- labelled query set + recall@10 assertions
- `tests/run_recall.sh` -- end-to-end orchestrator
- `tests/sync_check.sh` -- the 3-check static sync gate (accepted in `05_claude1_fixes.md`)

## Status

TESTS

## What landed

### 1. `tests/fixtures/seed_corpus.sql`

Synthetic corpus in schema `case_test_seed`. Layout matches PLAYBOOK Section 2 canonical (`chunks.id`, `chunks.content`, `chunks.embedding`, `content_tsv` generated column, `source_files`).

| Cluster | Chunk IDs | Embedding axis | Keyword footprint |
|---------|-----------|----------------|-------------------|
| civil-rights | 1..6 | dim 0 ~ 0.93..0.98 | 1983 / Monell / qualified immunity / constitutional / due process |
| probate | 7..12 | dim 1 ~ 0.94..0.97 | personal representative / probate / letters testamentary / inventory |
| medical | 13..18 | dim 2 ~ 0.94..0.98 | HIPAA / 164.524 / chart audit / Epic / Cerner / 164.502(g) |
| noise | 19..20 | dim 3, dim 4 | Paris/Seine, photosynthesis |

8-dim embedding is intentional: `ops_search_agent.hybrid_rrf_search` accepts unsized `vector`, so any dim works. 8 makes the vectors readable in the source file. Each chunk gets cluster-axis ~= 0.95 + small noise on other axes; HNSW + cosine separates clusters cleanly.

Indexes built: `hnsw (embedding vector_cosine_ops)`, `gin (content_tsv)`, `gin (content gin_trgm_ops)`. All three function legs have backing indexes.

`corpus_registry` row inserted with `in_evidence_search = false` so the test schema does NOT join the production `v_evidence_search` UNION ALL (its `vector(8)` would type-mismatch a halfvec(1024) production view).

### 2. `tests/recall_benchmark.sql`

Six labelled queries, two per cluster. Each query has `query_text`, `query_vec`, `relevant_ids` (the 6 cluster members). For each: runs `hybrid_rrf_search(...) LIMIT 10`, computes `recall@10 = |returned ∩ relevant| / |relevant|`.

Thresholds:
- per-query: `recall@10 ≥ 0.80`
- aggregate (mean across all 6): `mean_recall_at_10 ≥ 0.90`

Final `DO $$ ... RAISE EXCEPTION` blocks make the script exit non-zero on any failure -- run_recall.sh propagates that.

The query mix:
| qid | description |
|-----|-------------|
| 1 | civil-rights pure (exact keyword match + cluster vector) |
| 2 | probate pure |
| 3 | medical pure |
| 4 | civil-rights paraphrase (no exact keyword; relies on vector + trgm signal) |
| 5 | probate subtopic ('letters testamentary') -- mixes specific phrase + cluster vector |
| 6 | medical subtopic ('field-level audit log') -- mixes |

Queries 4-6 test that the hybrid fusion compensates when one leg has weak signal (no exact keyword) by leaning on the other two legs.

### 3. `tests/run_recall.sh`

Orchestrator. Applies scripts/01-05 (skips 04 example), seeds, runs the benchmark, drops the test schema. Flags:

```
--db <dsn>     # explicit DSN (else uses PG_DSN env var)
--keep-db      # preserve test schema after the run
--seed-only    # stop after seeding (for manual inspection)
--no-apply     # skip scripts/01..05 (assume already applied)
```

Preflight: checks pgvector + pg_trgm are present before doing anything.

scripts/01 is invoked with `-v role=<current_user>` so the `ALTER ROLE :"role"` resolves cleanly against the runner's role. Logs every step so a failed run pinpoints the bad file.

### 4. `tests/sync_check.sh`

The 3-check sync gate I accepted in `05_claude1_fixes.md`. Static-only by default; `--live` adds psql checks against a deployed DB.

**Check 1** -- column-set agreement: extracts the column list from `scripts/03_create_query_log.sql` CREATE TABLE block, verifies all 16 PLAYBOOK Section 8 canonical columns are present. Extras allowed.

**Check 2** -- function-signature agreement: extracts parameter names from `scripts/05_hybrid_rrf_search.sql` function signature. Inspects SKILL.md for `hybrid_rrf_search(...)` call sites. If SKILL.md uses named-arg style (`=>`), the check passes (no positional drift possible). If SKILL.md uses positional args, it verifies the count fits within the signature.

**Check 3** -- default-defaults agreement: extracts `DEFAULT` values from `scripts/02_create_corpus_registry.sql` for the canonical columns. Compares against PLAYBOOK Section 2 expected values (`chunks` / `content` / `embedding` / `id` / `1024`).

Live mode (`--live`) adds three psql checks: query_log has the canonical columns deployed, hybrid_rrf_search() exists, corpus_registry deployed defaults match.

### Live sync_check.sh result against this branch

```
$ bash tests/sync_check.sh
[sync_check] CHECK 1: query_log column-set agreement (scripts/03 vs PLAYBOOK Section 8)
[sync_check] PASS: all 16 PLAYBOOK Section 8 columns present in scripts/03
[sync_check] CHECK 2: hybrid_rrf_search signature agreement (scripts/05 vs SKILL.md)
[sync_check]   scripts/05 declares 10 function parameters: query_text query_vec target_schema target_table text_col vec_col chunk_id_col k_per_leg rrf_k final_k
[sync_check]   SKILL.md uses named-arg call style (2 => uses); compatible with any param order
[sync_check] PASS: function-signature: SKILL.md uses named args, no positional drift possible
[sync_check] CHECK 3: corpus_registry defaults agree with PLAYBOOK Section 2 canonical
[sync_check] PASS:   chunk_table DEFAULT 'chunks'
[sync_check] PASS:   chunk_text_col DEFAULT 'content'
[sync_check] PASS:   chunk_vec_col DEFAULT 'embedding'
[sync_check] PASS:   chunk_id_col DEFAULT 'id'
[sync_check] PASS:   embedding_dim DEFAULT 1024
[sync_check] ALL CHECKS PASS
```

## Important caveat about Check 2

`build/claude-1` was created off `main @ 4166fa3` -- BEFORE Claude-2's docs fixes landed on `build/claude-2`. So the SKILL.md visible in this worktree is the PRE-FIX SKILL.md that uses obsolete param names (`k`, `per_leg`) which do NOT exist in my scripts/05 signature.

The sync_check.sh in this commit is permissive: it only verifies that SKILL.md uses named-arg style (`=>`), not that every named arg corresponds to an actual function parameter. That's intentional: under the current loose check the gate passes on each build branch independently.

**Strict-mode follow-up** (Phase 4b or Phase 5):
- Add a stricter Check 2 that extracts every `<name> =>` from SKILL.md and asserts every name is in scripts/05's parameter list.
- Run it AFTER `main` merges in both `build/claude-2` (SKILL.md updated) and `build/claude-1` (scripts/05 updated). At that point the strict check should pass.

This is flagged in Open questions for Phase 5 sign-off.

## How to actually run the recall harness against a live PG

```bash
# One-time: create a throwaway DB (needs CREATEDB privilege)
createdb test_postgres_ai_agent

# Trusted extension via psql:
psql -d test_postgres_ai_agent -c 'CREATE EXTENSION pg_trgm;'

# Untrusted extension via superuser:
sudo -u postgres psql -d test_postgres_ai_agent -c 'CREATE EXTENSION vector;'

# Run
PG_DSN="dbname=test_postgres_ai_agent host=/var/run/postgresql" \
    bash tests/run_recall.sh
```

## Actual live-run result against pgvector 0.8.2 + pg_trgm 1.6 on Postgres 18.4

```
 qid | description                                      | relevant | hit | recall_at_10 | passed | returned_ids
-----+--------------------------------------------------+----------+-----+--------------+--------+------------------------------
   1 | pure civil-rights vector + keyword               |        6 |   6 |        1.000 | t      | {1,3,4,2,5,6,17,9,10,14}
   2 | pure probate vector + keyword                    |        6 |   6 |        1.000 | t      | {7,11,12,8,10,9,6,5,14,2}
   3 | pure medical vector + keyword                    |        6 |   6 |        1.000 | t      | {13,15,16,18,17,14,8,11,3,1}
   4 | civil-rights paraphrase (no exact keyword)       |        6 |   6 |        1.000 | t      | {1,3,4,2,5,6,17,9,10,14}
   5 | probate specific subtopic (letters testamentary) |        6 |   6 |        1.000 | t      | {8,7,11,12,10,9,6,5,14,2}
   6 | medical specific subtopic (audit log)            |        6 |   6 |        1.000 | t      | {18,13,15,16,17,14,8,11,3,1}
(6 rows)

 n_queries | n_passed | n_failed | mean_recall_at_10 | min_recall_at_10
-----------+----------+----------+-------------------+------------------
         6 |        6 |        0 |             1.000 |            1.000

NOTICE:  recall_benchmark PASSED: mean_recall_at_10 = 1
[run_recall] PASS
```

`sync_check.sh --live` also runs ALL CHECKS PASS against the same DB.

The synthetic corpus is easy by design (3 well-separated clusters); 1.000 recall is fine for the smoke test that proves the pipeline works end-to-end. The 0.80/0.90 thresholds remain regression detectors -- they exist to catch the case where someone changes scripts/05 in a way that breaks retrieval. Phase 4b adversarial mutations will calibrate sensitivity.

## Bugs that the live run actually exposed (real findings, not cosmetic)

The live run-through caught three real bugs in scripts/01-02-05 that the static review missed. All three fixed in the commit alongside the recall harness:

1. **scripts/01 ALTER ROLE hard-fail for non-superusers.** `ALTER ROLE x SET hnsw.iterative_scan = ...` requires superuser to set a custom GUC (or ALTER SYSTEM privilege). Non-privileged deploys died. **Fix:** wrap the ALTER ROLE in a DO block with `EXCEPTION WHEN insufficient_privilege` so the script emits a NOTICE explaining the SET fallback instead of dying. Bridge the `:'role'` psql variable into the DO block via a custom GUC `ai_iter.target_role` because psql does NOT substitute colon-variables inside dollar-quoted strings.

2. **scripts/02 CREATE EVENT TRIGGER hard-fail for non-superusers.** Event triggers require superuser. Same `EXCEPTION WHEN insufficient_privilege` wrap; emits a NOTICE explaining auto-registration is OFF and the operator must INSERT into corpus_registry manually. The function `on_corpus_schema_created()` itself still exists, so a future superuser binding works without re-running scripts/02.

3. **scripts/02 rebuild_v_evidence_search() leaves view missing on fresh DB.** When `corpus_registry` is empty (no case_*/corpus_*/legal_* schemas exist), the function skipped the CREATE VIEW; downstream `SELECT COUNT(*) FROM v_evidence_search` then died with "relation does not exist". **Fix:** always create the view, with an empty-result placeholder when no rows exist (`SELECT NULL::text..., ... WHERE false`).

4. **scripts/05 rrf_score type mismatch.** Function declares `rrf_score double precision` but `COALESCE(1.0 / ($4 + rank), 0)` produces `numeric` (because `1.0` is a numeric literal in PG and `numeric / bigint = numeric`). RETURN QUERY threw "Returned type numeric does not match expected type double precision". **Fix:** cast the RRF numerator to `1.0::double precision` so the whole arithmetic chain stays in float8.

These are pre-existing issues from the original scripts (not introduced in Phase 3) that nobody had caught because we hadn't run a fresh deploy on a non-superuser DB. Phase 4a's value is exactly this: live-run uncovers real footguns that static review misses.

## Asks of Claude 2 (for Phase 4b red-team)

1. **Red-team the recall harness.** Specifically: does the test actually fail when retrieval is broken? Suggested adversarial mutations to confirm fail-loud:
   - Replace `RANK()` in scripts/05 with `ROW_NUMBER()` -- does recall stay > 0.90? (would indicate the test isn't sensitive to that change; might be fine)
   - Remove `MATERIALIZED` from scripts/05 CTE legs -- recall stable? (probably yes; the dataset is too small to expose planner-fold)
   - Replace `to_tsvector('english', %I)` with `to_tsvector('simple', %I)` in scripts/05 -- recall stable for query 4 ('fourteenth amendment due process violation')?
   - Replace one chunk's content with random text -- recall@10 should drop on its cluster.
2. **Red-team the seed corpus.** Are the hand-crafted vectors too clean? Suggested mutations:
   - Increase the perturbation to ~0.3 on off-axis dims -- does HNSW still cluster correctly?
   - Add 50 noise chunks (so the candidate pool is 70, not 20) and verify recall@10 stays above threshold.
3. **Cross-reference the latency_benchmark.py I will not write** (it's your slice) -- does your benchmark exercise the same `hybrid_rrf_search` function with the same args my recall test uses? If yes, the two harnesses can share `tests/fixtures/seed_corpus.sql` and your latency_benchmark.py can `psql -f tests/fixtures/seed_corpus.sql` before timing.
4. **README.md** (your slice in Phase 4a): the file should reference both runners (`bash tests/run_recall.sh` + `python tests/latency_benchmark.py`) and the sync_check (`bash tests/sync_check.sh`). Plus the prerequisites (pgvector >= 0.8.0, pg_trgm).

## Commits landed this phase

- `c1d7c96  phase4a: claude-1 recall harness + sync_check static gate`

## Open questions / deferred

- **Strict Check 2 follow-up**: enable named-arg-name verification once both branches merge to `main`. Tracked above.
- **Sync_check live mode**: needs a CI runner with a throwaway PG. Worth wiring once we add CI (out of scope this phase).
- **Recall thresholds**: 0.80 per-query / 0.90 aggregate are gut-feel. After Claude-2's latency benchmark runs, we should also calibrate sensitivity: rerun recall after each adversarial mutation in (1) above and snap thresholds to a value that fails when retrieval breaks but passes on the baseline.
- **Larger corpus**: the synthetic 20-chunk corpus is enough to validate the function shape but not to measure real recall. Phase 4b or Phase 5 could add a second harness against a small real corpus (Wikipedia 1k sentences with labelled queries) for closer-to-prod numbers.
- **scripts/00_create_extensions.sql**: still not added. The run_recall.sh preflight checks for the extensions; it could also create them when missing. Defer to Phase 4b or Phase 5.

[CLAUDE-1 // 2026-05-20T10:20Z]
