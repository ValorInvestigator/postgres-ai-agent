# STATE -- Two-Claude Build Tracker

## Current phase

**Phase 1 -- AUDIT OWN SLICE**

## Phase tracker

| Phase | Claude 1 handoff | Claude 2 handoff | Status |
|-------|------------------|------------------|--------|
| 1 -- Audit own slice | [DONE] `01_claude1_audit.md` | `02_claude2_audit.md` | claude-1 done; waiting on claude-2 |
| 2 -- Red-team the other | `03_claude1_redteam_of_claude2.md` | `04_claude2_redteam_of_claude1.md` | pending |
| 3 -- Fix own slice | `05_claude1_fixes.md` | `06_claude2_fixes.md` | pending |
| 4a -- Build tests harness | `07_claude1_tests_recall.md` | `08_claude2_tests_latency.md` | pending |
| 4b -- Red-team tests | `09_claude1_redteam_tests.md` | `10_claude2_redteam_tests.md` | pending |
| 5 -- Sign-off (joint) | `11_joint_signoff.md` (co-edited) | (co-edited) | pending |

## Seed inconsistencies (Phase 1 starting context)

Both Claudes should incorporate these into their Phase 1 audit:

1. `README.md:44` and `SKILL.md:79` list `tests/` directory in the repo layout; directory does not exist. (visible to: Claude 2)
2. `SKILL.md:42` references MCP `rerank` tool; no implementation anywhere in repo. (visible to: Claude 2; mention in audit but don't block)
3. `SKILL.md:105` example query uses `vector(384)`; verify `scripts/05_hybrid_rrf_search.sql` dimension assumption matches. (cross-slice; both Claudes flag)
4. `snippets/bigquery_auth.py` exists in a "Postgres-native" skill; verify it's intentional + audit credential handling. (visible to: Claude 1; credential-risk angle)
5. "No em dashes" style rule -- verify existing files comply via `rg -n '—' references/ SKILL.md README.md`. (visible to: Claude 2; em-dash specifically)

## Handoffs landed

-  (Phase 1, code slice, claude-1) -- landed 2026-05-20T08:15Z. 19 findings (5 high, 8 med, 6 low) + 4 asks of claude-2.

## Active branches

- `main` (scaffold + initial commit)
- `build/claude-1` (Claude 1's worktree branch -- to be created)
- `build/claude-2` (Claude 2's worktree branch -- to be created)
