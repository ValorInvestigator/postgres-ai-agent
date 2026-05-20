# PROMPT FOR CLAUDE 2 (DOCS SLICE)

Copy-paste this as the opening message to the Claude Code instance running in worktree `../repo-c2` on branch `build/claude-2`.

---

You are Claude 2 on a two-instance parallel verify + harden workflow against the postgres-ai-agent skill.

## Read first

1. `HANDOFFS/BUILD_PROTOCOL.md` -- single source of truth for the workflow
2. `HANDOFFS/TEMPLATE.md` -- handoff file format
3. `HANDOFFS/STATE.md` -- current phase + seed inconsistencies

## Your slice (write surface)

- `README.md`
- `SKILL.md`
- `references/PLAYBOOK.md`
- `references/waves/**`
- future `tests/README.md` (Phase 4b, latency side)
- your own handoff files: `HANDOFFS/NN_claude2_*.md`

## Hard constraints

- You may NEVER edit anything under `scripts/` or `snippets/` (that's Claude 1's surface)
- You may read everything
- You may edit `HANDOFFS/STATE.md` (the phase tracker) when your handoff lands
- No em dashes; double hyphens only
- Confidence-grade every claim (A/B/C per PLAYBOOK conventions)
- Commit every change with a descriptive message

## Phase 1 -- Audit your slice (your first action)

1. Read `SKILL.md` and `README.md` end-to-end.
2. Read `references/PLAYBOOK.md` end-to-end.
3. Spot-check `references/waves/wave_1_vector_index.md` through `wave_4_agent_retrieval.md` for claims SKILL/PLAYBOOK depends on.
4. Audit your slice against:
   - Em-dash audit: `rg -n '—' references/ SKILL.md README.md` -- list every hit
   - Repo-structure tables that reference non-existent paths (seed: `tests/` per STATE.md)
   - Unverified numeric claims: 49%, 67%, 2x storage savings, MTEB 70.58, 568M params, k=60, 384-dim -- each should trace to a wave-report citation
   - Cross-document consistency: SKILL.md "Five Section 0 moves" wording must match PLAYBOOK Section 0; PLAYBOOK Section 13 phase plan must match SKILL.md "Phased migration plan" table
   - Confidence-grade coverage: do all assertions in SKILL + PLAYBOOK carry an A/B/C grade per PLAYBOOK style?
   - MCP `rerank` tool reference in SKILL.md without implementation -- how should the doc handle this?
5. Drop your findings as `HANDOFFS/02_claude2_audit.md` using `TEMPLATE.md` format. Severity high/med/low. Every finding has file:line + concrete suggested fix.
6. Commit the handoff file with message `phase1: claude-2 audit of docs slice`.
7. **STOP and wait** for `HANDOFFS/01_claude1_audit.md` to land before starting Phase 2.

## Then -- Phase 2 (red-team the other slice)

Once `01_claude1_audit.md` lands, switch perspective:
1. Read every file in Claude 1's slice (`scripts/`, `snippets/`)
2. Apply the red-team rubric in `BUILD_PROTOCOL.md`
3. Drop findings as `HANDOFFS/04_claude2_redteam_of_claude1.md`
4. Commit; wait for `03_claude1_redteam_of_claude2.md`

## Then -- Phase 3 (fix your slice)

Apply Claude 1's red-team findings against your slice. For each finding:
- Accept + fix (commit, list SHA in handoff), OR
- Reject with explicit written reason in `06_claude2_fixes.md`

## Phase 4 + 5

See `BUILD_PROTOCOL.md`. You build `tests/latency_benchmark.py` + `tests/README.md` (how to run both harnesses).

## Start now

Begin Phase 1. Drop `HANDOFFS/02_claude2_audit.md` as your first action.
