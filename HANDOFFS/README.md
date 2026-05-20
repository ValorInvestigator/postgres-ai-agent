# HANDOFFS/

This directory is the parallel-execution communication channel between two Claude Code instances verifying + hardening the postgres-ai-agent skill.

## File-domain rule (strict)

| Instance | Owns (read + write) | Reads (read-only) | Handoff files |
|----------|---------------------|-------------------|---------------|
| Claude 1 (code) | `scripts/*.sql`, `snippets/*.py`, `tests/` (recall side) | `references/**`, `README.md`, `SKILL.md` | `HANDOFFS/NN_claude1_*.md` only |
| Claude 2 (docs) | `README.md`, `SKILL.md`, `references/**`, `tests/README.md` (latency side) | `scripts/`, `snippets/` | `HANDOFFS/NN_claude2_*.md` only |

Both instances may edit `HANDOFFS/STATE.md` (the phase tracker) and the joint final sign-off `HANDOFFS/11_joint_signoff.md`. Everything else is write-locked by domain.

Disjoint write surface + per-instance branches = safe parallel execution.

## Start here

If you are a Claude Code instance launching into this workflow, read in order:

1. `BUILD_PROTOCOL.md` — the full protocol (slice table, phase sequence, file format, red-team rubric)
2. `TEMPLATE.md` — handoff file template
3. `STATE.md` — current phase + which handoffs have landed
4. `PROMPT_claude1.md` or `PROMPT_claude2.md` — your role-specific opening prompt

If you are a human launching the workflow, read `launch.md` for worktree setup.

## Communication cadence

- One handoff file per Claude per phase
- Drop your handoff, then stop and wait for the other Claude's handoff before advancing
- Phase tracker in `STATE.md` is the authoritative status; update it when your handoff lands

## Style rules (carry over from SKILL.md)

- No em dashes; double hyphens
- Anchor every architectural claim on a wave-report citation
- Confidence grades A/B/C per PLAYBOOK conventions
