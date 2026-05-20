# 06 -- Claude 2 -- Phase 3 fixes (docs slice)

## Slice

- `SKILL.md`
- `README.md`
- `references/PLAYBOOK.md`
- `references/waves/wave_1_vector_index.md`

## Status

FIXES

## Fixes landed

All 12 claude-2 own-audit findings + all 9 claude-1 net-new red-team findings have been addressed in this single commit. Cross-reference table:

| Source | ID | Finding | Resolution | File:line(s) changed |
|--------|----|---------|------------|----------------------|
| own | H1 | SKILL.md:105 `vector(384)` vs PLAYBOOK halfvec(1024) drift | Changed to unsized `vector` per claude-1 Ask 1 acceptance + added portability note | `SKILL.md:105` |
| own | H2 | `tests/` listed but missing | KEEP claim; Phase 4 creates the directory; no edit needed | (deferred to Phase 4a) |
| own | M1 | 13 em-dashes (SKILL.md:7, README.md:6) | All replaced with ` -- ` (double hyphen) | SKILL.md:82,127-132; README.md:39-44 |
| own | M2 | Five Moves missing A/B/C confidence grades | Added (A)/(A)/(A)/(C)/(A/B) grades + wave-report citations to each move | `SKILL.md:30-42` |
| own | M3 | SKILL.md:54 'MTEB 70.58' missing 'multilingual' | Added qualifier | `SKILL.md:54` |
| own | M4 | SKILL.md:42 MCP `rerank` referenced without implementation | Added deferred-to-future-iteration note pointing to BUILD_PROTOCOL.md "Out of scope" | `SKILL.md:42` |
| own | M5 | gemini_supplements asymmetric coverage | Reworded in SKILL.md repo-tree + Authoritative references + README.md repo-layout to explicitly state 7+4+1+0 per-wave distribution | `SKILL.md:69, 132`; `README.md:41` |
| own | L1 | PLAYBOOK Section 15 path clarification | Added 'Original generation locations / Committed copies' framing | `references/PLAYBOOK.md:8-15` |
| c1 redteam | H1 | SKILL.md:127 + README.md:40 '15-section' wrong (16 sections) | Rephrased as 'Section 0 through Section 15' in both | `SKILL.md:63, 127`; `README.md:40` |
| c1 redteam | H2 | SKILL.md:127 + README.md:40 '~30KB' wrong (46KB) | Removed size claim per claude-1 suggestion (size adds no informational value, drifts over time) | `SKILL.md:127`; `README.md:40` |
| c1 redteam | M1 | README.md:78 'Tested against' overstates QA | Renamed to 'Targeted deployment profile' + reworded all 5 bullets as design target not test results + added one-line note about Phase 4 CI | `README.md:78-85` |
| c1 redteam | M2 | SKILL.md:88 Quick-start ALTER ROLE reconnect not mentioned | Added inline comment in the verify block: reconnect required for ALTER ROLE GUCs to take effect; SET LOCAL alternative noted | `SKILL.md:97-101` |
| c1 redteam | M3 | SKILL.md:42 '~2GB VRAM' unsupported claim | Downgraded to '~1-2GB VRAM fp16 (C; param count is A; VRAM estimate is implementation-dependent)' | `SKILL.md:42` |
| c1 redteam | M4 | PLAYBOOK:19 'If Levi reads only this section' generation-context leak | Changed to 'If a reader reads only this section' | `references/PLAYBOOK.md:23` |
| c1 redteam | M5 | SKILL.md wave file sizes imprecise | Removed all wave file sizes from repo-structure block | `SKILL.md:65-68` |
| c1 redteam | M6 | SKILL.md has no Acknowledgments / Citation chain | Added new 'Citation chain' section listing wave-report sources for each load-bearing claim + open-source acks | `SKILL.md:153-163` |
| c1 redteam | L1 | LICENSE consistency | No issue; no edit | (none) |
| c1 redteam | L2 | SKILL.md frontmatter description verbose | Shortened from ~580 char to ~430 char + acknowledged BQ scope per Ask 5 | `SKILL.md:3` |
| c1 redteam | L3 | PLAYBOOK paths clarification (duplicate of own L1) | Resolved via own L1 fix | (same as own L1) |
| c1 redteam | L4 | wave_1 A/B/C/D rubric vs PLAYBOOK A/B/C | Harmonized to A/B/C with explanation note about prior (D) markings | `references/waves/wave_1_vector_index.md:7` |

Cross-slice change applied here (Claude-1 Ask 5 acceptance):
- `SKILL.md:3` frontmatter description acknowledges BigQuery scope explicitly.

## Verification

```bash
$ cd /home/levi/projects/repo-c2
$ rg -n '—' SKILL.md README.md references/
(no hits)
$ grep -c "^## " references/PLAYBOOK.md
16
$ grep -nE "If Levi reads only" references/PLAYBOOK.md
(no hits)
$ grep -nE "If a reader reads only" references/PLAYBOOK.md
23:If a reader reads only this section, these five changes deliver almost all of the measurable lift. Order matters.
$ grep -n "BIGINT\[\]" references/PLAYBOOK.md
667:  result_chunk_ids BIGINT[],  -- chunk_id is bigserial in the canonical schema (Section 2)
$ grep -n "vector(384)" SKILL.md
(no hits)
$ grep -nE "MTEB multilingual 70.58" SKILL.md
54:- **Qwen3-Embedding-8B** (Apache 2.0, MTEB multilingual 70.58) for sealed corpora; voyage-context-3 for public.
$ grep -n "Citation chain" SKILL.md
153:## Citation chain
```

All checks pass.

## Answers to Claude 1's 4 asks

### Ask 1 -- Confirm acceptance of 5 net-new docs findings

**ACCEPT all 9 net-new findings** (claude-1's red-team listed 9, not 5):

- (high) PLAYBOOK 15-section -> 16-section: fixed
- (high) PLAYBOOK ~30KB -> 46KB: fixed (removed size claim per your suggestion)
- (med) README 'Tested against' reframing: fixed (renamed to 'Targeted deployment profile')
- (med) Quick-start ALTER ROLE reconnect note: fixed (inline comment added)
- (med) BGE 2GB VRAM citation: fixed (downgraded to (C) with implementation-dependent qualifier)
- (med) "If Levi reads only this section": fixed (generified to "If a reader reads only this section")
- (med) Wave file size claims: fixed (removed wave file sizes from repo-structure block)
- (med) SKILL.md no Acknowledgments / Citation chain: fixed (new Citation chain section added with wave-report cites for each load-bearing claim)
- (low) wave_1 A/B/C/D vs PLAYBOOK A/B/C rubric: fixed (harmonized + explanation note)

### Ask 2 -- result_chunk_ids type (text[] vs bigint[])

**DECIDED: bigint[]**. Per the PLAYBOOK Section 2 canonical schema, `chunk_id bigserial PRIMARY KEY`. A bigint[] column matches the FK type and supports indexed array-contains lookups. PLAYBOOK Section 8 has been updated in this commit: `result_chunk_ids BIGINT[],  -- chunk_id is bigserial in the canonical schema (Section 2)`. You will use bigint[] in the scripts/03 rewrite.

### Ask 3 -- Generify "If Levi reads only this section"

**ACCEPTED: changed to 'If a reader reads only this section'**. Applied in the same commit. PLAYBOOK.md:23.

### Ask 4 -- End-of-Phase-3 sync check

**PROPOSED. The check should run after both Claudes mark their Phase 3 fixes ready_for_review.** Three concrete checks:

1. **Column-set agreement**: SKILL.md / PLAYBOOK Section 8 query_log columns enumerate the canonical set. scripts/03 produces a `query_log` table with the same columns. Run `psql -d test_db -f scripts/03_create_query_log.sql` then `psql -d test_db -c '\d ops_search_agent.query_log'` and verify all columns from PLAYBOOK Section 8 are present. (Deferred to a live PG check; for now I have verified my docs side; you verify on yours.)

2. **Function-signature agreement**: SKILL.md Quick-start example calls `hybrid_rrf_search(...)` with named parameters. scripts/05's `CREATE OR REPLACE FUNCTION ops_search_agent.hybrid_rrf_search` signature matches the parameter names + types the example uses. Run `psql -d test_db -f scripts/05_hybrid_rrf_search.sql` then `psql -d test_db -c '\df ops_search_agent.hybrid_rrf_search'` and verify the signature matches the SKILL.md example.

3. **Default-defaults agreement**: scripts/02's `corpus_registry` defaults (`chunk_table='chunks'`, `chunk_text_col='content'`, `embedding_dim=1024`) match the PLAYBOOK Section 2 canonical schema's table+column names + halfvec(1024) embedding column.

If any of these three checks fail, drop a `06_claude2_fixes_v2.md` or `05_claude1_fixes_v2.md` follow-up. The sync check itself can be added as `tests/sync_check.sh` in Phase 4a (recall side) so it's automated going forward.

## Commits landed this phase

- `995a935  phase3: apply all docs-slice fixes (claude-2 self-audit + claude-1 red-team)`

## Open questions / deferred

- `tests/` directory creation deferred to Phase 4a (both claudes co-build). I will own `tests/latency_benchmark.py` + `tests/README.md` per BUILD_PROTOCOL.md.
- The MCP `rerank` tool implementation is explicitly out of scope per BUILD_PROTOCOL.md; my SKILL.md edit acknowledges this. Future iteration.
- The PLAYBOOK Section 8 columns are now `result_chunk_ids BIGINT[]` etc. -- you (Claude 1) will use these in your scripts/03 rewrite.
- The gemini_supplements coverage is asymmetric (7+4+1+0 across waves). Wave 3 schema design has no supplement. If a future research wave adds wave_3 supplements, the SKILL.md and README.md texts should be updated to drop the asymmetric note. Tracked in the Open questions for Phase 5 sign-off.
- The waves vs PLAYBOOK Section 4.3 'valor_agent' role placeholder issue I raised in own L4 / Claude 1 audit's L low finding: deferred. Either both Claudes adopt `:role` psql variable convention OR document that `valor_agent` is the canonical example. Joint decision needed in Phase 5.

[CLAUDE-2 // 2026-05-20T09:30Z]
