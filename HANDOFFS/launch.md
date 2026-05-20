# Launch -- Two-Claude Parallel Build

Short instructions for Levi to spin up the two Claude Code instances against the postgres-ai-agent repo.

## One-time setup (from `/home/levi/projects/postgres-ai-agent`)

```bash
cd /home/levi/projects/postgres-ai-agent

# Make sure main is up-to-date with the scaffold
git pull --rebase origin main

# Create both worktrees on dedicated branches off main
git worktree add ../repo-c1 -b build/claude-1
git worktree add ../repo-c2 -b build/claude-2

# Verify
git worktree list
# Expected output:
# /home/levi/projects/postgres-ai-agent      <sha> [main]
# /home/levi/projects/repo-c1                <sha> [build/claude-1]
# /home/levi/projects/repo-c2                <sha> [build/claude-2]
```

## Launch Claude 1 (code slice)

In a new terminal:

```bash
cd /home/levi/projects/repo-c1
claude
```

(Or whatever command launches Claude Code on your system.)

Then paste the contents of `HANDOFFS/PROMPT_claude1.md` as the opening message. Claude 1 will begin Phase 1 (audit own slice) and drop `HANDOFFS/01_claude1_audit.md`.

## Launch Claude 2 (docs slice)

In a separate terminal (parallel):

```bash
cd /home/levi/projects/repo-c2
claude
```

Then paste the contents of `HANDOFFS/PROMPT_claude2.md`. Claude 2 will begin Phase 1 and drop `HANDOFFS/02_claude2_audit.md`.

## How the handoffs synchronize

The `HANDOFFS/` directory is on `main` and inherited by both worktrees, but the two worktrees are on separate branches. To see the other Claude's handoff, each one needs to:

```bash
# Pull the other Claude's handoff from main (or the other branch)
git fetch origin
git merge --ff-only origin/build/claude-<other-number>
```

OR (simpler): both Claudes can commit handoffs directly to `main`. The trade-off:
- Commits to `main`: handoffs are immediately visible to the other worktree after `git pull`; but `main` history gets noisy
- Commits to per-branch: handoffs need explicit fetch/merge to cross over

**Recommended**: both Claudes commit handoffs to their own branch, then push to the other's branch as a tracking ref. Simpler: have both Claudes push to `main` for `HANDOFFS/` only, while keeping fix-commits on their own branch. (This is the pattern Claude 1's PROMPT and Claude 2's PROMPT both follow.)

Alternative simpler model: both Claudes operate on `main` directly. File-domain rule (Claude 1 owns code, Claude 2 owns docs) makes conflicts impossible since they edit different files. The `build/claude-1` and `build/claude-2` branches exist only as failover.

## Monitoring progress

`HANDOFFS/STATE.md` is the authoritative phase tracker. Both Claudes update it when their handoff lands. To see status from the main worktree:

```bash
cd /home/levi/projects/postgres-ai-agent
git pull
cat HANDOFFS/STATE.md
ls -la HANDOFFS/
```

## Tearing down (after Phase 5 sign-off)

```bash
cd /home/levi/projects/postgres-ai-agent

# Merge each branch into main (or open PRs)
git merge --no-ff build/claude-1
git merge --no-ff build/claude-2

# Push consolidated main
git push origin main

# Clean up worktrees
git worktree remove ../repo-c1
git worktree remove ../repo-c2

# Delete now-merged branches
git branch -D build/claude-1 build/claude-2
git push origin --delete build/claude-1 build/claude-2
```

## Notes

- This workflow assumes single-user safety: only Levi pushes to GitHub. If two pushes race, the second one will need a rebase.
- The `tests/` directory (Phase 4) is the only file-domain overlap (both Claudes write into `tests/`, but to different files). The `tests/README.md` is Claude 2's; everything else under `tests/` is Claude 1's.
- If a Claude crashes mid-phase, the other Claude can keep working in their own slice. Re-launch the crashed Claude with the same PROMPT file -- it will read STATE.md and pick up where it left off.
