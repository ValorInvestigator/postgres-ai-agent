# STATE -- Two-Claude Build Tracker

## Current phase

**Phase 5 -- JOINT SIGN-OFF** (claude-2 drafted, claude-1 co-signed; ready to merge to main)

## Phase tracker

| Phase | Claude 1 handoff | Claude 2 handoff | Status |
|-------|------------------|------------------|--------|
| 1 -- Audit own slice | [DONE] `01_claude1_audit.md` | [DONE] `02_claude2_audit.md` | both done |
| 2 -- Red-team the other | [DONE] `03_claude1_redteam_of_claude2.md` | [DONE] `04_claude2_redteam_of_claude1.md` | both done |
| 3 -- Fix own slice | [DONE] `05_claude1_fixes.md` | [DONE] `06_claude2_fixes.md` | both done; sync gate static checks PASS on each branch independently |
| 4a -- Build tests harness | [DONE] `07_claude1_tests_recall.md` | [DONE] `08_claude2_tests_latency.md` | both done |
| 4b -- Red-team tests | [DONE] `09_claude1_redteam_tests.md` | [DONE] `10_claude2_redteam_tests.md` | both done |
| 4c -- Fixes against the other's red-team | [DONE] `09b_claude1_phase4b_fixes.md` | [DONE] `12_claude2_redteam_fixes.md` | both done |
| 5 -- Sign-off (joint) | [DONE] `11_joint_signoff.md` (co-edited) | [DONE] (co-edited) | both signed; ready to merge |

## Seed inconsistencies (Phase 1 starting context)

Both Claudes should incorporate these into their Phase 1 audit:

1. `README.md:44` and `SKILL.md:79` list `tests/` directory in the repo layout; directory does not exist. (visible to: Claude 2)
2. `SKILL.md:42` references MCP `rerank` tool; no implementation anywhere in repo. (visible to: Claude 2; mention in audit but don't block)
3. `SKILL.md:105` example query uses `vector(384)`; verify `scripts/05_hybrid_rrf_search.sql` dimension assumption matches. (cross-slice; both Claudes flag)
4. `snippets/bigquery_auth.py` exists in a "Postgres-native" skill; verify it's intentional + audit credential handling. (visible to: Claude 1; credential-risk angle)
5. "No em dashes" style rule -- verify existing files comply via `rg -n '—' references/ SKILL.md README.md`. (visible to: Claude 2; em-dash specifically)

## Handoffs landed

- `01_claude1_audit.md` (Phase 1, code slice, claude-1) -- landed 2026-05-20T08:15Z. 19 findings (5 high, 8 med, 6 low) + 4 asks of claude-2.
- `02_claude2_audit.md` (Phase 1, docs slice, claude-2) -- landed 2026-05-20T08:20Z. 12 findings (2 high, 6 med, 4 low) + 3 cross-slice asks of claude-1.
- `04_claude2_redteam_of_claude1.md` (Phase 2, code slice red-team, claude-2) -- landed 2026-05-20T08:45Z. 8 net-new findings + confirmation of all 19 claude-1 self-flagged findings. 5 asks of claude-1.
- `03_claude1_redteam_of_claude2.md` (Phase 2, docs slice red-team, claude-1) -- landed 2026-05-20T09:00Z. 9 net-new findings (2 high, 6 med, 1 low) + confirmation of all 12 claude-2 self-flagged findings. Answers all 5 claude-2 asks. 4 cross-slice asks of claude-2.
- `06_claude2_fixes.md` (Phase 3, docs slice fixes, claude-2) -- landed 2026-05-20T09:30Z (on origin/build/claude-2 @ 995a935). All 12 own + 9 claude-1 red-team findings resolved in a single commit. result_chunk_ids decided as BIGINT[]. 3-check sync gate proposed.
- `05_claude1_fixes.md` (Phase 3, code slice fixes, claude-1) -- landed 2026-05-20T09:55Z (on build/claude-1). All 19 own + 8 claude-2 red-team findings resolved in a single commit. scripts/04 renamed to .example.sql. ACCEPTS the 3-check sync gate.
- `07_claude1_tests_recall.md` (Phase 4a, recall harness + sync gate, claude-1) -- landed 2026-05-20T10:20Z (on build/claude-1). Shipped tests/fixtures/seed_corpus.sql + tests/recall_benchmark.sql + tests/run_recall.sh + tests/sync_check.sh. All 3 static sync checks PASS on build/claude-1. 4 asks of claude-2 for Phase 4b red-team.
- `08_claude2_tests_latency.md` (Phase 4a, latency harness + tests/README.md, claude-2) -- landed 2026-05-20T10:45Z (on origin/build/claude-2 @ 5948ce8). Shipped tests/latency_benchmark.py (3 modes: vector_only / hybrid_rrf / hybrid_rrf_with_rerank stub) + tests/README.md (full harness docs). 4 asks of claude-1 for Phase 4b red-team.
- `09_claude1_redteam_tests.md` (Phase 4b, red-team of claude-2's tests, claude-1) -- landed 2026-05-20T10:55Z (on build/claude-1). Net-new findings: 1 high (no GIN preflight), 5 med (budget calibration, rerank stub semantics, autocommit doc, HNSW preflight robustness, README prereq drift), 4 low. Live mutation results: 2/4 mutations caught (M1 + M4); M2 + M3 missed because 20-row corpus is too small. 5 asks of claude-2 + answers to claude-2's 4 asks.
- `10_claude2_redteam_tests.md` (Phase 4b, red-team of claude-1's recall harness, claude-2) -- landed 2026-05-20T11:10Z (on origin/build/claude-2). Brutal finding: my recall harness was effectively vector-only because plainto_tsquery AND-semantics + over-specific queries made FTS/trgm legs return zero rows for all queries. Only the "function dropped" control mutation was detected. 7 mutations + recommendations.
- `09b_claude1_phase4b_fixes.md` (Phase 4b followup, address claude-2's findings, claude-1) -- landed 2026-05-20T11:25Z (on build/claude-1). Expanded seed corpus to 60 chunks (+10 structured distractors +30 padding), shortened queries so all 3 legs fire, added precision@6 metric + leg-coverage assertion + pg_trgm.similarity_threshold=0.05 session setting. Recalibrated thresholds to baseline floor (recall@10>=0.65, precision@6>=0.50, mean recall@10>=0.85, leg-coverage gates). All 6 queries PASS post-fix.
- `12_claude2_redteam_fixes.md` (Phase 4c, claude-2's fixes against claude-1's red-team, claude-2) -- landed 2026-05-20T18:00Z (on origin/build/claude-2 @ 680fa69). Added preflight Check 4 (GIN tsvector via pg_am), Check 5 (GIN pg_trgm), Check 7 (MATERIALIZED count via pg_get_functiondef). Two-layer budgets (BUDGET_FLOOR_MS + BUDGET_CEILING_MS). HNSW check upgraded to pg_am canonical. README polish (drop uuid-ossp, sudo workaround, PG 14+ range, SSL caveat). 4/4 mutations now caught.
- `13_claude2_signoff_validation.md` (Phase 5 prep, claude-2's validation of claude-1 recall harness v2, claude-2) -- landed 2026-05-20T18:30Z (on origin/build/claude-2 @ 8e84b41). Confirmed v2 recall harness catches mutation 7 (5 of 6 cluster-1 chunks destroyed) with recall_at_10=0.167 < 0.65 gate; was PASS=1.000 on v1.
- `11_joint_signoff.md` (Phase 5, claude-2 drafted + claude-1 co-signed, joint) -- claude-2 draft landed 2026-05-20T18:45Z (on origin/build/claude-2 @ 8c05428); claude-1 co-sign landed 2026-05-20T11:55Z (on build/claude-1). Both sign-offs in place. Skill is ready to merge to main.

## Active branches

- `main` (scaffold + Phase 1 audits)
- `build/claude-1` (Claude 1's worktree branch)
- `build/claude-2` (Claude 2's worktree branch -- worktree at `/home/levi/projects/repo-c2/`)
