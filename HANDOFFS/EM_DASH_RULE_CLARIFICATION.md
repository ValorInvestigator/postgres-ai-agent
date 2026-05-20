# EM-DASH RULE CLARIFICATION (per Levi 2026-05-20T09:10Z)

## What changed

Levi clarified the no-em-dash rule applies ONLY to his own personal written documents (legal filings, letters to external recipients, briefs, referrals over his signature). It does NOT apply to redistributable skills, technical docs, internal scaffolding, or anything not addressed to a live human recipient over his name.

**Direct quote:** "em dash rule only applies to written docs for me"

## Scope decisions for this skill repo

The `postgres-ai-agent` skill is a redistributable technical skill. SKILL.md, README.md, PLAYBOOK.md, the wave reports, HANDOFFS files, and code documentation may use em-dashes. They are NOT violations.

## Effect on Phase 3 fixes

**Both Claudes:** SKIP the em-dash scrub. Specifically:

- `02_claude2_audit.md` flagged 13 em-dash hits across SKILL.md (7) + README.md (6) as MED-severity style violations. NOT VIOLATIONS per Levi clarification. Skip in Phase 3.
- `03_claude1_redteam_of_claude2.md` did not flag em-dashes as a top issue but mentioned them in passing. Same skip.
- `BUILD_PROTOCOL.md` Red-team rubric line: "Style rules -- SKILL.md forbids em dashes; flag any" -- this rubric item is incorrect for this skill repo. The "SKILL.md forbids em dashes" sentence inside SKILL.md (line ~142) is itself a style note that doesn't carry to skill consumers. Could be softened or removed in Phase 3 (claude-2's slice).

## Updated red-team rubric (effective Phase 3 onward)

The original `BUILD_PROTOCOL.md` red-team rubric line:

> Style rules -- SKILL.md forbids em dashes; flag any.

Replace with:

> Style rules -- consistency of voice + clear technical writing. Em-dashes are NOT a violation in this skill repo (rule applies only to Levi's personal written documents per [[feedback_em_dash_rule_scope]] auto-memory).

claude-2 can apply this change in Phase 3 (docs slice -- BUILD_PROTOCOL.md is internal scaffolding so it falls under claude-2's docs-side ownership for editing).

## Memory rule saved

`feedback_em_dash_rule_scope.md` saved to `/home/levi/.claude/projects/-home-levi/memory/`. Every future Claude Code instance auto-loads this rule.

## Sign-off

This clarification supersedes any em-dash-related finding in the Phase 1 + Phase 2 handoffs.

[CLAUDE-1 // 2026-05-20T09:10Z]
