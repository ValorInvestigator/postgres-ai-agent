# BUILD PROTOCOL -- Two-Claude Parallel Verify + Harden of postgres-ai-agent

Single source of truth for the workflow. A colleague reading only this file should be able to launch their Claude Code instance and act.

## Goal

Verify the postgres-ai-agent skill ships internally-consistent docs + working SQL/Python. Drift between PLAYBOOK/SKILL claims and the actual SQL/Python is the primary risk. Two Claude Code instances run in parallel against disjoint slices of the repo, audit their own slice, red-team the other, fix their own slice, and jointly build the missing `tests/` harness.

## Slice ownership

| | Claude 1 (Code) | Claude 2 (Docs) |
|---|---|---|
| Owns | `scripts/*.sql`, `snippets/*.py`, future `tests/` (recall side) | `README.md`, `SKILL.md`, `references/PLAYBOOK.md`, `references/waves/**`, future `tests/README.md` (latency side) |
| Reads (read-only) | docs slice | code slice |
| Writes handoffs | `HANDOFFS/NN_claude1_*.md` only | `HANDOFFS/NN_claude2_*.md` only |
| Worktree | `git worktree add ../repo-c1 build/claude-1` | `git worktree add ../repo-c2 build/claude-2` |

File-domain rule is strict: Claude 1 never edits docs, Claude 2 never edits code. Both can read everything. Both can edit their own handoff files + STATE.md.

## Handoff sequence

| Phase | Claude 1 | Claude 2 |
|-------|----------|----------|
| 1. Audit own slice | `01_claude1_audit.md` | `02_claude2_audit.md` |
| 2. Red-team the other | `03_claude1_redteam_of_claude2.md` | `04_claude2_redteam_of_claude1.md` |
| 3. Fix own slice | `05_claude1_fixes.md` (commit SHAs) | `06_claude2_fixes.md` (commit SHAs) |
| 4a. Build tests harness | `07_claude1_tests_recall.md` | `08_claude2_tests_latency.md` |
| 4b. Red-team tests | `09_claude1_redteam_tests.md` | `10_claude2_redteam_tests.md` |
| 5. Sign-off (co-edited) | `11_joint_signoff.md` | `11_joint_signoff.md` |

Cadence: drop your handoff, then stop and wait for the other Claude's handoff to land before starting the next phase.

## Handoff file format

Every handoff file has these sections, in this order:

```markdown
# NN -- Claude X -- <phase>

## Slice
<files this handoff covers>

## Status
<one of: AUDIT | REDTEAM | FIXES | TESTS | SIGNOFF>

## Findings (or: Issues raised against the other slice)
- [SEV: high|med|low] <file:line> -- <concrete issue> -- <suggested fix>
- ...

## Asks of the other Claude
- <thing you need them to do or confirm before you can proceed>

## Commits landed this phase
- <sha>  <one-line subject>

## Open questions / deferred
- <items deferred to a later phase or to the user>
```

Use `TEMPLATE.md` as the starting point.

## Red-team rubric

When reviewing the other slice, look for:

- **Doc-vs-code drift** -- claims in PLAYBOOK/SKILL that the SQL/Python does not actually do, or does differently
- **Missing artifacts** -- repo-structure tables that reference files/dirs that do not exist (seed: `tests/`)
- **Unverified numbers** -- "49%", "67%", "2x storage savings", "MTEB 70.58" -- each must be tied back to a wave-report citation; flag unsupported ones
- **Footguns in code** -- broken SQL (wrong schema names, missing extensions assumed), Python with missing imports, untestable functions, credentials risk in `snippets/bigquery_auth.py`
- **Version assumptions** -- pgvector 0.8.2 and Postgres 16 baseline; does any script silently require newer features?
- **Hidden invariants** -- embedding dimensions (the `vector(384)` in SKILL.md line ~105 vs whatever the scripts assume), halfvec usage, HNSW parameters
- **Style rules** -- SKILL.md forbids em dashes; flag any

Every red-team finding must include `file:line`, severity (high/med/low), and a concrete suggested fix -- not just "this looks wrong."

## Phase 4 -- tests/ sub-slice

| Claude | Builds | Verifies |
|---|---|---|
| Claude 1 | `tests/fixtures/seed_corpus.sql` (small synthetic corpus), `tests/recall_benchmark.sql` (runs `hybrid_rrf_search`, asserts recall@10 >= threshold on labelled queries), `tests/run_recall.sh` | Recall numbers match playbook claims |
| Claude 2 | `tests/latency_benchmark.py` (uses the existing `snippets/pg_query_logger.py` pattern to time vector-only vs hybrid vs hybrid+rerank), `tests/README.md` (how to run both harnesses) | p50/p95 latency stays under a documented budget |

Each red-teams the other's harness once (handoffs 09 and 10). Specifically:
- Claude 1's recall test: does it actually fail when retrieval is broken?
- Claude 2's latency test: does it isolate the leg being measured?

## Seed inconsistencies (Phase 1 starting context)

These are already visible from a 10-minute scan; both Claudes should start with these in their audit:

- `README.md:44` and `SKILL.md:79` list `tests/`; directory missing.
- `SKILL.md:42` references MCP `rerank` tool; no implementation anywhere in repo.
- `SKILL.md:105` example query uses `vector(384)`; `scripts/05_hybrid_rrf_search.sql` should be checked for the actual dimension assumption.
- `snippets/bigquery_auth.py` exists in a "Postgres-native" skill; verify it's intentional + audit for credential handling.
- "No em dashes" style rule -- run `rg -n ' -- ' references/ SKILL.md README.md` to be sure existing files comply (note: `--` is allowed; `—` is not).

## Sign-off (Phase 5)

`HANDOFFS/11_joint_signoff.md` is co-edited. Final content must include:

- Every seed inconsistency resolved or explicitly deferred (with reason)
- All red-team findings closed (or rejected with reason)
- Commit SHAs across both branches ready to merge into `main`
- Test harness run results (recall + latency) consistent with PLAYBOOK claims

## Out of scope

- Standing up a live Postgres cluster for the tests/ runs (Levi handles separately)
- Editing the SKILL.md / README.md / PLAYBOOK.md fundamental architecture; this pass is verify + harden, not redesign
- MCP server scaffolding for the `rerank` tool (deferred to a future iteration)

## Style rules (mandatory)

- No em dashes; double hyphens only
- Anchor architectural claims on a wave-report citation
- Confidence-grade every assertion in handoffs the same way PLAYBOOK does: A / B / C
