# PROMPT FOR CLAUDE 1 (CODE SLICE)

Copy-paste this as the opening message to the Claude Code instance running in worktree `../repo-c1` on branch `build/claude-1`.

---

You are Claude 1 on a two-instance parallel verify + harden workflow against the postgres-ai-agent skill.

## Read first

1. `HANDOFFS/BUILD_PROTOCOL.md` -- single source of truth for the workflow
2. `HANDOFFS/TEMPLATE.md` -- handoff file format
3. `HANDOFFS/STATE.md` -- current phase + seed inconsistencies

## Your slice (write surface)

- `scripts/*.sql`
- `snippets/*.py`
- future `tests/` recall-side files (Phase 4a)
- your own handoff files: `HANDOFFS/NN_claude1_*.md`

## Hard constraints

- You may NEVER edit anything under `references/`, `README.md`, or `SKILL.md` (that's Claude 2's surface)
- You may read everything
- You may edit `HANDOFFS/STATE.md` (the phase tracker) when your handoff lands
- No em dashes; double hyphens only
- Confidence-grade every claim (A/B/C per PLAYBOOK conventions)
- Commit every change with a descriptive message

## Phase 1 -- Audit your slice (your first action)

1. Read every file in `scripts/` and `snippets/` end-to-end.
2. Read `references/PLAYBOOK.md` so you understand what the SQL/Python is claiming to implement.
3. Audit your slice against:
   - Does each SQL script actually do what its header comment claims?
   - Are there hidden invariants (embedding dimensions, halfvec usage, HNSW parameters, extension assumptions) that should be documented or hardcoded explicitly?
   - Does `snippets/bigquery_auth.py` handle credentials safely? Is it appropriate to include in a "Postgres-native" skill?
   - Does `snippets/pg_query_logger.py` actually work against the `ops_search_agent.query_log` schema created by `scripts/03_create_query_log.sql`? Verify column-by-column.
   - Does `scripts/05_hybrid_rrf_search.sql` correctly implement RRF with the parameter signature claimed in `SKILL.md` Quick-start?
   - Are there missing files (e.g., `tests/` per the seed inconsistencies)?
4. Drop your findings as `HANDOFFS/01_claude1_audit.md` using `TEMPLATE.md` format. Severity high/med/low. Every finding has file:line + concrete suggested fix.
5. Commit the handoff file with message `phase1: claude-1 audit of code slice`.
6. **STOP and wait** for `HANDOFFS/02_claude2_audit.md` to land before starting Phase 2.

## Then -- Phase 2 (red-team the other slice)

Once `02_claude2_audit.md` lands, switch perspective:
1. Read every file in Claude 2's slice (`README.md`, `SKILL.md`, `references/PLAYBOOK.md`, `references/waves/**`)
2. Apply the red-team rubric in `BUILD_PROTOCOL.md`
3. Drop findings as `HANDOFFS/03_claude1_redteam_of_claude2.md`
4. Commit; wait for `04_claude2_redteam_of_claude1.md`

## Then -- Phase 3 (fix your slice)

Apply Claude 2's red-team findings against your slice. For each finding:
- Accept + fix (commit, list SHA in handoff), OR
- Reject with explicit written reason in `05_claude1_fixes.md`

## Phase 4 + 5

See `BUILD_PROTOCOL.md`. You build `tests/recall_benchmark.sql` + supporting recall fixtures + `tests/run_recall.sh`.

## Start now

Begin Phase 1. Drop `HANDOFFS/01_claude1_audit.md` as your first action.
