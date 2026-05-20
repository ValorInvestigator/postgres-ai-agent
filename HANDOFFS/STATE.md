# STATE -- Two-Claude Build Tracker

## Current phase

**Phase 4b -- RED-TEAM TESTS** (claude-2 done; waiting on claude-1 for `09_claude1_redteam_tests.md`)

## Phase tracker

| Phase | Claude 1 handoff | Claude 2 handoff | Status |
|-------|------------------|------------------|--------|
| 1 -- Audit own slice | [DONE] `01_claude1_audit.md` | [DONE] `02_claude2_audit.md` | both done |
| 2 -- Red-team the other | [DONE] `03_claude1_redteam_of_claude2.md` | [DONE] `04_claude2_redteam_of_claude1.md` | both done |
| 3 -- Fix own slice | [DONE] `05_claude1_fixes.md` | [DONE] `06_claude2_fixes.md` | both done |
| 4a -- Build tests harness | [DONE] `07_claude1_tests_recall.md` | [DONE] `08_claude2_tests_latency.md` | both done |
| 4b -- Red-team tests | `09_claude1_redteam_tests.md` | [DONE] `10_claude2_redteam_tests.md` | claude-2 done; waiting on claude-1 |
| 5 -- Sign-off (joint) | `11_joint_signoff.md` (co-edited) | (co-edited) | pending (blocked on 09 + Phase 4b cross-asks) |

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
- `06_claude2_fixes.md` (Phase 3 fixes, docs slice, claude-2) -- landed 2026-05-20T09:30Z. All 21 findings (12 own + 9 redteam) resolved in 1 commit (995a935). Answers all 4 claude-1 asks (Ask 2 bigint[] confirmed; Ask 3 generification applied; Ask 4 sync-check proposed).
- `06b_claude2_sync_gate.md` (Phase 3 sync gate, docs slice, claude-2) -- landed 2026-05-20T11:00Z (fd21d5c). 3-check static gate result + watch-item resolution against build/claude-1 Phase 3 commits.
- `08_claude2_tests_latency.md` (Phase 4a, latency benchmark, claude-2) -- landed 2026-05-20T15:00Z (5948ce8). Built `tests/latency_benchmark.py` (456 lines, 3 retrieval modes, exit codes 0/1/2) + `tests/README.md`. Documented PLAYBOOK Section 6.2 budgets.
- `10_claude2_redteam_tests.md` (Phase 4b, red-team of recall harness, claude-2) -- landed 2026-05-20T17:00Z (6ef5748). 7 mutations + 1 control. All 7 recall-degradation mutations passed undetected. Root cause: 20-chunk fixture + final_k=10 = no eliminations possible. fts_rank + trgm_rank return NULL throughout (effectively vector-only test). 3 cross-slice asks of claude-1 (scale corpus, diagnose NULL fts/trgm, decide on mutation-test file).

## Active branches

- `main` (scaffold + Phase 1 audits)
- `build/claude-1` (Claude 1's worktree branch)
- `build/claude-2` (Claude 2's worktree branch -- worktree at `/home/levi/projects/repo-c2/`)
