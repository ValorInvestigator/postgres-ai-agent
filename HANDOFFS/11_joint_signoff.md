---
phase: 5
authors: claude-1 + claude-2 (co-edited)
status: SIGNOFF
date: 2026-05-20
---

# 11 -- Joint sign-off -- postgres-ai-agent verify-and-harden build

This is the final pre-merge sign-off for the two-Claude parallel build.
Both Claudes attest that their slice's findings have been resolved, the
test harnesses run green on fresh databases, and the resulting skill is
ready to merge to `main`.

## Slice ownership confirmed

- **Claude 1 (code slice):** `scripts/`, `snippets/`, `tests/recall_benchmark.sql`, `tests/run_recall.sh`, `tests/fixtures/seed_corpus.sql`, `tests/sync_check.sh`, `tests/recall/README.md` (if any).
- **Claude 2 (docs slice):** `SKILL.md`, `README.md`, `references/PLAYBOOK.md`, `references/waves/`, `tests/latency_benchmark.py`, `tests/README.md`.
- **Joint (co-edited):** `HANDOFFS/STATE.md`, `HANDOFFS/11_joint_signoff.md`, `HANDOFFS/BUILD_PROTOCOL.md`, `HANDOFFS/EM_DASH_RULE_CLARIFICATION.md`.

## Seed inconsistencies -- resolution

| # | Seed inconsistency | Resolution | Where |
|---|---------------------|------------|-------|
| 1 | `tests/` directory listed in repo layout but did not exist | RESOLVED -- both Claudes co-built `tests/` in Phase 4a | `tests/` in build/claude-1 and build/claude-2 |
| 2 | `SKILL.md` references MCP `rerank` tool with no implementation | RESOLVED -- inline note added that MCP scaffolding is deferred per BUILD_PROTOCOL.md "Out of scope"; rerank stub in `tests/latency_benchmark.py` matches PLAYBOOK 5.3 cost; the architectural claim stands, the implementation is deferred | `SKILL.md:42`, `latency_benchmark.py:300-340` |
| 3 | `SKILL.md` example query used `vector(384)` while PLAYBOOK Section 2 said `halfvec(1024)` | RESOLVED -- SKILL.md example switched to unsized `vector` to be portable across embedding models; PLAYBOOK keeps `halfvec(1024)` as the canonical default; deployed scripts use `chunk_id_col` and `vec_col` parameters so dimension is corpus-determined | `SKILL.md:107-119`, `scripts/02_create_corpus_registry.sql` |
| 4 | `snippets/bigquery_auth.py` exists in a "Postgres-native" skill | RESOLVED -- KEEP + SKILL.md frontmatter description updated to acknowledge BigQuery scope ("Postgres + BigQuery patterns ... plus BigQuery service-account boilerplate for cross-source patterns"); credential handling reviewed in claude-1 audit | `SKILL.md:3`, `snippets/bigquery_auth.py` |
| 5 | Em-dash style rule violations in SKILL.md/README.md | RESOLVED -- 13 em-dashes replaced with double-hyphens in Phase 3 fixes (commit `995a935`); also the rule scope was clarified in `EM_DASH_RULE_CLARIFICATION.md` (rule applies to Levi's personal written docs; this is a redistributable skill so em-dashes are not violations -- but we still chose double-hyphens for visual consistency in the committed skill) | `SKILL.md:154`, `README.md`, `HANDOFFS/EM_DASH_RULE_CLARIFICATION.md` |

## Red-team findings -- resolution rollup

### Claude 1 own-audit (`01_claude1_audit.md`)

- 19 findings (5 high, 8 med, 6 low) -- ALL RESOLVED in `05_claude1_fixes.md` (commit `68c1b14`)
- Sync check static gate PASS on build/claude-1 (`07_claude1_tests_recall.md` Phase 4a)

### Claude 2 own-audit (`02_claude2_audit.md`)

- 12 findings (2 high, 6 med, 4 low) -- ALL RESOLVED in `06_claude2_fixes.md` (commit `995a935`)
- Three-check sync gate PASS on build/claude-2 (`06b_claude2_sync_gate.md` Phase 3)

### Claude 2 red-team of Claude 1 (`04_claude2_redteam_of_claude1.md`)

- 8 net-new findings against code slice -- ALL RESOLVED in `05_claude1_fixes.md` (claude-1's commit `68c1b14` and `184b376`)
- Plus claude-1 self-flagged 3 fixes from live recall harness (`184b376`): scripts/01 graceful-degrade on non-superuser, scripts/02 same, scripts/05 chunk_id_col + rrf_score double precision cast + MATERIALIZED enforcement

### Claude 1 red-team of Claude 2 (`03_claude1_redteam_of_claude2.md`)

- 9 net-new findings against docs slice -- ALL RESOLVED in `06_claude2_fixes.md` (commit `995a935`)
- Cross-decisions: `result_chunk_ids BIGINT[]` (was TEXT[]); "If Levi reads only" -> "If a reader reads only"; gemini_supplements asymmetric coverage explicit; Citation chain section added; BGE 2GB VRAM downgraded to (C) confidence

### Claude 2 red-team of Claude 1 tests (`10_claude2_redteam_tests.md`)

- 7 mutations + 1 control. v1 recall harness caught only the control (function dropped).
- Root cause: 20-chunk fixture + final_k=10 + NULL fts/trgm legs = effectively vector-only smoke test
- RESOLVED in claude-1's `09b_claude1_phase4b_fixes.md` (commit `c4e6a5d`):
  - Corpus scaled 20 -> 60 chunks (18 cluster + 10 structured distractors + 32 noise)
  - Query texts shortened so `plainto_tsquery` AND-joins produce non-empty token sets
  - `pg_trgm.similarity_threshold = 0.05` session-set (default 0.3 was too strict for short queries)
  - New `precision_at_6` metric + `fts_nonnull >= 1 AND trgm_nonnull >= 1` leg-coverage gates
  - Thresholds calibrated: per-query recall_at_10 >= 0.65, mean >= 0.85, per-query precision_at_6 >= 0.50
- VALIDATED in claude-2's `13_claude2_signoff_validation.md` (commit `8e84b41`):
  - Mutation 7 (destroy 5 of 6 cluster-1 chunks) now FAILS the v2 harness with recall_at_10=0.167 < 0.65 gate; was PASS=1.000 on v1

### Claude 1 red-team of Claude 2 tests (`09_claude1_redteam_tests.md`)

- 4 mutations against latency benchmark. v1 caught 2 of 4 (M1 HNSW drop + M4 rerank-bump); MISSED M2 (drop GIN tsv) + M3 (remove MATERIALIZED).
- 11 SEV findings + 5 asks
- RESOLVED in claude-2's `12_claude2_redteam_fixes.md` (commit `680fa69`):
  - Preflight expanded 4 -> 7 checks: HNSW (canonical pg_am), GIN tsvector, GIN pg_trgm, MATERIALIZED count via pg_get_functiondef
  - Two-layer budgets: BUDGET_FLOOR_MS (fixture-scaled) + BUDGET_CEILING_MS (PLAYBOOK production)
  - README polish: PG 14+, sudo workaround for pgvector, drop uuid-ossp, SSL caveat tightened, slice-ownership tags on open-work bullets
- All 4 mutations now caught (M2 + M3 via new preflight checks)

### Cross-slice asks -- final ledger

| Source | Ask | Resolution |
|--------|-----|------------|
| 02 -> claude-1 | Confirm canonical embedding dimension/type | RESOLVED: scripts stay 384-dim for synthetic test corpus; PLAYBOOK keeps halfvec(1024) canonical; SKILL.md example uses unsized `vector`; new corpora use halfvec(1024) explicitly per PLAYBOOK Section 2 |
| 02 -> claude-1 | Confirm snippets/bigquery_auth.py is intentional | RESOLVED: KEEP; SKILL.md frontmatter updated to acknowledge BQ scope |
| 04 -> claude-1 | 5 cross-slice items (dimension drift, COMMENT ON, schema-spec, md5(NULL), etc.) | RESOLVED in `05_claude1_fixes.md` |
| 06 -> claude-1 | result_chunk_ids type (TEXT[] vs BIGINT[]) | DECIDED: BIGINT[] (chunk_id is bigserial in PLAYBOOK Section 2) |
| 06 -> claude-1 | 3-check sync gate | ACCEPTED; sync_check.sh built by claude-1 in Phase 4a |
| 09 -> claude-2 | 5 asks against latency benchmark | RESOLVED in `12_claude2_redteam_fixes.md` |
| 10 -> claude-1 | 3 asks against recall harness | RESOLVED in `09b_claude1_phase4b_fixes.md` |
| 12 -> claude-1 | 2 optional asks (strict sync_check Check 2; latency-leg vs recall-leg consistency) | claude-1's strict sync_check Check 2 implementation outlined in 09's Ask 4 answer; the NULL-leg root cause closed by claude-1's recall harness v2; consider strict Check 2 in a follow-up commit (not blocking) |

## Test harness final results

Run against fresh `test_postgres_ai_agent` DB on PG 18.4 + pgvector 0.8.2 + pg_trgm 1.6.

### `tests/sync_check.sh` (static + live)

Per claude-1 Phase 4a: 3 of 3 static checks PASS on each branch independently. Strict Check 2 (extract every `name =>` and assert each is in scripts/05 signature) is deferred to a follow-up commit per `09_claude1_redteam_tests.md` Ask 4 -- not blocking.

### `tests/run_recall.sh` (v2 corpus + queries)

```
n_queries=6  n_passed=6  n_failed=0
mean_recall_at_10=0.889  min_recall_at_10=0.667
mean_precision_at_6=0.611  min_precision_at_6=0.500
All queries: fts_nonnull >= 1 AND trgm_nonnull >= 1 (gate satisfied)
NOTICE: recall_benchmark PASSED
```

Mutation 7 (claude-2 bombshell) re-test on v2: FAILS as expected with recall_at_10=0.167 < 0.65 per-query gate. Harness is regression-detective, not a smoke test.

### `tests/latency_benchmark.py` (two-layer budgets + 7-check preflight)

```
preflight PASS: function + fixture + HNSW + GIN(tsv) + GIN(trgm) + chunk count + MATERIALIZED CTEs OK

vector_only             p50=  0.02  p95=  0.03  max=  0.03  (floor 1/3/10 ; ceiling 8/30/100 ms)
hybrid_rrf              p50=  0.95  p95=  1.02  max=  1.07  (floor 5/20/50 ; ceiling 40/120/300 ms)
hybrid_rrf_with_rerank  p50=201.29  p95=201.65  max=201.94  (floor 230/250/300 ; ceiling 340/620/1500 ms)

RESULT: PASS (all modes within both floor + ceiling budgets)
```

M1 (drop HNSW) -> exit 2 via preflight Check 3. M2 (drop GIN tsvector) -> exit 2 via NEW preflight Check 4. M3 (remove MATERIALIZED) -> exit 2 via NEW preflight Check 7. M4 (rerank bump to 700ms) -> exit 1 via FLOOR budget breach.

## Commit SHAs ready to merge

### build/claude-2 (docs slice) -- by claude-2

| Commit | Subject |
|--------|---------|
| `e751777` | merge: bring claude-2's phase 1 + phase 2 work into main |
| `1e485dd` | phase2: claude-1 red-team of claude-2 docs slice |
| `995a935` | phase3: apply all docs-slice fixes (claude-2 self-audit + claude-1 red-team) |
| `d60a32d` | phase3: claude-2 fixes handoff + STATE.md update |
| `3f5ea52` | phase2.5: clarify em-dash rule scope per Levi directive |
| `5f3cfda` | phase3 cleanup: soften em-dash style rule per claude-1 EM_DASH_RULE_CLARIFICATION |
| `1b7c2c9` | phase3 sync: align SKILL.md Quick-start example to claude-1 hybrid_rrf_search signature |
| `fd21d5c` | phase3: claude-2 sync gate run + watch-item resolution |
| `5948ce8` | phase4a: claude-2 latency benchmark + tests/README.md |
| `6ef5748` | phase4b: claude-2 red-team of recall harness |
| `a71b062` | phase4b: claude-2 STATE.md update -- Phase 4a + 4b entries |
| `680fa69` | phase4c: claude-2 fixes against claude-1 phase 4b red-team |
| `7a76e81` | phase4c: fill in commit SHA in handoff |
| `8e84b41` | phase5-prep: claude-2 validation of claude-1 recall harness v2 |
| `fa2c7dd` | phase5-prep: fill in commit SHA in handoff |

### build/claude-1 (code slice) -- by claude-1

| Commit | Subject |
|--------|---------|
| `bf26c22` | Scaffold HANDOFFS/ for two-Claude parallel verify + harden |
| `c119a1e` | phase1: claude-1 audit of code slice |
| `cd61f88` | phase1: fix STATE.md handoff-landed line (lost filename in prior commit) |
| `1e485dd` | phase2: claude-1 red-team of claude-2 docs slice |
| `4166fa3` | phase2.5: clarify em-dash rule scope per Levi directive |
| `68c1b14` | phase3: claude-1 apply all code-slice fixes (own audit + claude-2 red-team) |
| `eb1b498` | phase3: fill in commit SHA in handoff |
| `c1d7c96` | phase4a: claude-1 recall harness + sync_check static gate |
| `6fff9b9` | phase4a: fill in commit SHA in handoff |
| `184b376` | phase4a: scripts/01+02+05 fixes from live recall harness run |
| `ab873db` | phase4b: claude-1 red-team of claude-2's latency_benchmark + tests/README |
| `9a1442f` | phase4b: fill in commit SHA in handoff |
| `c4e6a5d` | phase4b: fix recall harness structural blind spot (claude-2 10_redteam findings) |
| `7ce325c` | phase4b cleanup: remove claude-2 slice files accidentally swept in by git add -A |

## Merge strategy

Both branches diverged from `main` after the initial scaffold + Phase 1 audits. Recommended merge order:

1. Merge `build/claude-1` -> `main` first (code slice includes scripts/, snippets/, tests/recall_*, tests/fixtures/, tests/sync_check.sh, tests/run_recall.sh).
2. Merge `build/claude-2` -> `main` second (docs slice includes SKILL.md, README.md, references/, tests/latency_benchmark.py, tests/README.md).
3. STATE.md, BUILD_PROTOCOL.md, and HANDOFFS/* are touched by both branches; expect minor merge conflicts on STATE.md.

After merge: re-run all three harnesses against `main` to confirm a clean integrated build. Strict sync_check Check 2 can land as a small follow-up commit on main.

## Open items explicitly deferred (NOT blockers)

| Item | Owner | Why deferred |
|------|-------|---------------|
| Scale recall corpus from 60 to 100 chunks | claude-1 (code slice) | 60 sufficient to discriminate mutation 7; scale up if real-world mutation testing shows gap |
| Explicit per-mutation regression test file | joint | precision@6 + leg-coverage gates already close most of the discriminative gap |
| rrf_score monotonicity assertion | claude-1 (code slice) | Defensive; not load-bearing for current threats |
| `--explain` mode for latency_benchmark.py | claude-2 (docs slice) | Will add if proves useful during a real regression hunt |
| MCP rerank server scaffolding | future iteration | Explicit "Out of scope" per BUILD_PROTOCOL.md |
| RAPTOR / graph layer / partitioning | future iteration | PLAYBOOK Phase 6 -- after measured gaps justify the work |
| Strict sync_check Check 2 (named-arg assertion) | claude-1 (code slice) | Implementation outlined in `09_claude1_redteam_tests.md` Ask 4; not blocking; follow-up commit on main |
| `vector_only` deleted_at filter consistency | claude-2 (docs slice) | Intentional; documented in `12_claude2_redteam_fixes.md` |
| `_percentile()` helper vs `statistics.quantiles` | claude-2 (docs slice) | Disagreement preserved; `statistics.quantiles` doesn't handle 30-element lists with n=100 cleanly |

## Sign-off statements

**Claude 2 (docs slice):** I attest that all findings against my slice have been resolved or explicitly deferred with reason; my slice's `tests/latency_benchmark.py` runs green on a fresh DB with all 7 preflight checks PASS and both BUDGET_FLOOR_MS + BUDGET_CEILING_MS satisfied across all 3 modes; the 4 mutations claude-1 ran against my benchmark are all caught after fix (was 2 of 4 before); and the docs (SKILL.md, README.md, PLAYBOOK.md, waves/) cross-cite consistently with each other and with the code slice. Ready to merge. -- [CLAUDE-2 // 2026-05-20T18:45Z]

**Claude 1 (code slice):** I attest that all findings against my slice have been resolved or explicitly deferred with reason. The 19 own-audit findings (`01_claude1_audit.md`) + 8 claude-2 red-team findings (`04_claude2_redteam_of_claude1.md`) all closed in commit `68c1b14`. Live recall harness PASS on a fresh PG 18.4 + pgvector 0.8.2 + pg_trgm 1.6 DB; the 4 scripts/01-02-05 bugs the live run exposed (ALTER ROLE on custom GUC needs superuser; CREATE EVENT TRIGGER same; rebuild_v_evidence_search() missing-view on empty registry; rrf_score numeric/double precision mismatch) all fixed in `184b376` with graceful EXCEPTION handlers so non-superuser deploys complete cleanly. Claude-2's red-team mutation 7 (`10_claude2_redteam_tests.md`) -- destroying 5 of 6 cluster-1 chunks -- correctly FAILS the v2 recall harness with `recall_at_10 = 0.167` (was PASS = 1.000 on v1); validated independently in claude-2's `13_claude2_signoff_validation.md`. `tests/sync_check.sh --live` ALL CHECKS PASS on build/claude-1. The 3 retired structural blind spots from claude-2's v1 red-team are closed: FTS leg's `plainto_tsquery` AND-semantics fixed via shorter queries; trgm leg's similarity-threshold default fixed via `SET pg_trgm.similarity_threshold = 0.05`; corpus expanded 20 -> 60 chunks with 10 structured distractors so `final_k = 10` is selective. Per-query precision@6 + leg-coverage gates installed so a future regression to vector-only retrieval will fail loudly. I concur with claude-2's two-layer (floor + ceiling) latency budgets, the expanded preflight (HNSW + GIN tsv + GIN trgm + MATERIALIZED-count source inspection), and the README polish in `12_claude2_redteam_fixes.md`. I concur with the deferred items in this document and the merge strategy. The skill is ready to merge to `main`. -- [CLAUDE-1 // 2026-05-20T11:55Z]

## Out of scope (per BUILD_PROTOCOL.md)

- Live Postgres cluster stood up for sustained tests (Levi handles separately)
- Architectural redesign of SKILL.md / README.md / PLAYBOOK.md (this pass is verify + harden)
- MCP server scaffolding for the `rerank` tool

## Commits landed this phase

To be filled in after final commit:

- `<sha>  phase5: joint sign-off (claude-2 draft; claude-1 to co-sign)`
