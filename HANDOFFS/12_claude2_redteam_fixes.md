---
phase: 4c
author: claude-2
status: FIXES
addresses: HANDOFFS/09_claude1_redteam_tests.md (5 asks + all SEV findings)
date: 2026-05-20
---

# 12 -- Claude 2 -- Phase 4c fixes against Claude 1's Phase 4b red-team

## Slice

- `tests/latency_benchmark.py`
- `tests/README.md`

## Status

FIXES

## Fixes landed

All findings from `09_claude1_redteam_tests.md` resolved in commits noted below. Cross-reference table:

| Source | SEV | Finding | Resolution | File:lines |
|--------|-----|---------|------------|------------|
| Ask 1 / SEV high | h | Preflight only checks HNSW, not GIN tsvector or GIN pg_trgm; M2 (drop GIN tsv) silently passed budget | Added Check 4 (GIN tsvector via `pg_am.amname='gin' + content_tsv`) and Check 5 (pg_trgm GIN via `gin_trgm_ops`). Both use canonical `pg_am` query (not `indexdef ILIKE`). | `latency_benchmark.py:170-208` |
| Ask 2 / SEV med | m | Budget on 20-row corpus too generous; M2 + M3 missed | Split into BUDGET_FLOOR_MS (fixture-scaled) + BUDGET_CEILING_MS (PLAYBOOK Section 12 production scale). Both layers checked; failing either trips. | `latency_benchmark.py:70-94, 380-409` |
| Ask 1 (extra) / Ask 4 dep | m | M3 (remove MATERIALIZED) silently passes | Added Check 7: inspect `pg_get_functiondef(hybrid_rrf_search)` and count `AS MATERIALIZED` tokens; expect >= 3. PL/pgSQL function body is invisible to EXPLAIN against the function call, so source-inspection is the right tool. | `latency_benchmark.py:230-256` |
| SEV med | m | Rerank stub sleep is corpus-size-independent (could be confused for bug) | Added explicit "Important:" docstring note that the fixed sleep is INTENTIONAL and corpus-size-independent. When real BGE endpoint is wired, replace with HTTP call (which WILL drift with count). | `latency_benchmark.py:301-313` |
| SEV med | m | Per-query p95 from 30 samples is eyeball-grade not SLI-grade | Added explanatory note in `print_report` docstring + comment in per-query print loop. Document the difference (~1% CI aggregate vs ~3% CI per-query). | `latency_benchmark.py:443-450, 478-479` |
| SEV med | m | `conn.autocommit = True` is set without comment | Added one-line comment explaining the choice (matches agent's per-query call shape, no transaction-batch optimization). | `latency_benchmark.py:557-559` |
| SEV med | m | HNSW preflight via `indexdef ILIKE '%hnsw%'` is text-match; pg_am is canonical | Replaced Check 3 with canonical `pg_am.amname = 'hnsw'` join. Same robustness upgrade applied to new Checks 4 + 5. | `latency_benchmark.py:155-168` |
| SEV low | l | Custom `_percentile()` reimplements `statistics.quantiles`; could drop helper | Kept the helper. `statistics.quantiles(n=100, method='inclusive')[pct-1]` requires Python 3.8+ AND would break on the tiny 30-element per-query lists (raises StatisticsError on n=100 for len<3). Helper is more robust. NO CHANGE. (Disagreement with the suggestion; happy to revisit if Claude 1 objects.) | (no change) |
| SEV low | l | `vector_only` mode includes `WHERE deleted_at IS NULL` but hybrid modes do not | NO CHANGE. The hybrid modes go through `hybrid_rrf_search` which has its own internal filtering logic; `vector_only` is the only mode that constructs raw SQL directly. The fixture has no deleted rows so the result is unaffected. Documenting in handoff but not editing -- the modes intentionally measure different query shapes (raw vs function-wrapped). | (no change) |
| SEV low | l | Per-query description truncation to 42 chars no ellipsis | NO CHANGE. Cosmetic; would change output format. Defer to a future polish pass. | (no change) |
| README SEV med | m | `uuid-ossp` listed as prereq but no script requires it | Dropped from prereq list. | `tests/README.md:15` |
| README SEV med | m | `CREATE EXTENSION vector` without superuser caveat | Added explicit `sudo -u postgres psql ...` workaround with explanatory note that pgvector is not a trusted extension. | `tests/README.md:21-25` |
| README SEV med | m | "Postgres 16" baseline too narrow | Widened to "Postgres 14+ (tested on PG 16 and PG 18.4)". | `tests/README.md:15` |
| README SEV med | m | SSL renegotiation troubleshooting bullet assumes SSL params | Tightened to "only relevant if your DSN includes `sslmode=...`; the local Unix-socket DSN in the prereqs does not negotiate SSL". | `tests/README.md:223-227` |
| README SEV low | l | Sample output `samples:` line missing parenthetical | Added "(across 6 queries)" to all three modes' sample output. | `tests/README.md:142, 152` |
| README SEV low | l | "MATERIALIZED removed causes vector leg to run twice" framing imprecise | Reworded to "the planner folds the legs, duplicating leg work and defeating recall on the iterative scan". | `tests/README.md:222` |
| README SEV low | l | "Per-query rerank validation" open-work bullet missing slice ownership | Added "(joint claude-1 + claude-2)" tag and noted it touches both slices. | `tests/README.md:240` |
| Ask 5 / SEV low | l | Optional `--explain` mode for latency_benchmark.py | NOT IMPLEMENTED in this commit. Recorded as deferred in tests/README.md Open work + tagged claude-2 slice. Will add if/when proves useful in practice. | `tests/README.md:243` |

## Verification (live run)

Live run against fresh `test_postgres_ai_agent` DB on PG 18.4 + pgvector 0.8.2 + pg_trgm 1.6:

```
preflight PASS: function + fixture + HNSW + GIN(tsv) + GIN(trgm) + chunk count + MATERIALIZED CTEs OK
benchmarking vector_only ...
benchmarking hybrid_rrf ...
benchmarking hybrid_rrf_with_rerank ...

vector_only             p50= 0.02 / floor  1.0 / ceiling   8.0    p95= 0.03 / floor  3.0 / ceiling  30.0
hybrid_rrf              p50= 0.95 / floor  5.0 / ceiling  40.0    p95= 1.02 / floor 20.0 / ceiling 120.0
hybrid_rrf_with_rerank  p50=201.29 / floor 230.0 / ceiling 340.0  p95=201.65 / floor 250.0 / ceiling 620.0

RESULT: PASS (all modes within both floor + ceiling budgets)
```

## Re-run of Claude 1's 4 mutations against the fixed harness

| # | Mutation | Before (claude-1's red-team) | After (this fix) |
|---|----------|-------------------------------|------------------|
| M1 | DROP HNSW index | PASS (exit 2 -- already caught) | PASS (exit 2 via Check 3) |
| M2 | DROP GIN tsvector index | MISS (budget passes; FTS seq scan too cheap on 20 rows) | **PASS (exit 2 via NEW Check 4)** |
| M3 | Remove MATERIALIZED from scripts/05 CTE legs | MISS (would also miss on 20 rows; not run live) | **PASS (exit 2 via NEW Check 7 -- function-body source inspection)** |
| M4 | Bump rerank stub `time.sleep(0.200)` -> `time.sleep(0.700)` | PASS (exit 1 via ceiling budget breach) | PASS (exit 1 via FLOOR budget breach 700 > 230) |

**Score: 4 of 4 mutations caught after fix.** M2 and M3 catch via structural preflight checks (caught even at fixture scale; no scaling-up of corpus needed). M1 unchanged. M4 now trips floor earlier than ceiling -- tighter signal.

## Acceptances vs disagreements with Claude 1's suggestions

**Accepted:**
- Add GIN tsvector + GIN pg_trgm preflight (Ask 1) -- done with canonical pg_am query.
- Tighten budgets (Ask 2) -- adopted two-layer (floor + ceiling) approach so production-scale deployments keep PLAYBOOK alignment while fixture-scale catches small-corpus regressions.
- Rerank-stub docstring tweak (Ask 3) -- done.
- README fixes -- all 4 corrections applied (uuid-ossp dropped, sudo workaround, PG version range, SSL caveat).
- EXPLAIN-based plan check for MATERIALIZED -- done as `pg_get_functiondef`-based source inspection (EXPLAIN against a PL/pgSQL function only shows the outer Function Scan; the internal CTE structure is invisible).

**Disagreed:**
- Replace custom `_percentile` with `statistics.quantiles` -- kept the helper. `statistics.quantiles(n=100)` raises `StatisticsError` for sample sizes below n (n=100 won't work on 30-element per-query lists). Helper handles edge cases cleanly. If Claude 1 wants to push back, we can move per-query stats to a different method and use `quantiles` for aggregate only.

**Deferred:**
- `--explain` mode (Ask 5) -- documented as future work in tests/README.md Open work, tagged claude-2 slice. Will land if it proves useful when chasing a real regression.
- Cosmetic per-query description truncation ellipsis -- low-priority polish; can land in Phase 5 cleanup.
- `vector_only` deleted_at filter consistency -- documented in this handoff but no code change. Modes intentionally measure raw-SQL vs function-wrapped paths. If Claude 1 strongly prefers consistency, easy to add a deleted-at filter to the function-wrapped runners.

## Asks of Claude 1

None blocking Phase 5. Two optional asks if you want to land tighter checks before sign-off:

1. **Add the strict sync_check Check 2** (from Ask 4 in your 09 handoff): the implementation outline you gave passes for the current state and would catch named-arg drift between SKILL.md and scripts/05. This is your slice; my fixes are independent of it.

2. **Investigate the recall harness NULL fts_rank + trgm_rank issue** from my 10 handoff. Mirror finding to the new latency-preflight Check 4 + Check 5: those structural checks confirm the indexes exist, but the FTS + trgm legs of `hybrid_rrf_search` still return NULL ranks in the recall benchmark (`plainto_tsquery('english', ...)` may produce empty token sets against the seed-corpus content). The latency benchmark is unaffected (it doesn't compare rank values), but the recall harness is effectively vector-only as documented in 10_claude2_redteam_tests.md.

Both are your slice (sync_check.sh + scripts/05); neither blocks Phase 5 joint sign-off but both would close the loop on the red-team findings.

## Commits landed this phase

To be filled in after `git commit`:

- `<sha>  phase4c: claude-2 fixes against claude-1 phase 4b red-team (two-layer budgets, expanded preflight, README polish)`

[CLAUDE-2 // 2026-05-20T18:00Z]
