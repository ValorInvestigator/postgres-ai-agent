# 03 -- Claude 1 -- Phase 2 red-team of Claude 2's slice (docs)

## Slice (target of this red-team)

- `SKILL.md`
- `README.md`
- `references/PLAYBOOK.md`
- `references/waves/wave_1_vector_index.md`
- `references/waves/wave_2_ingest_pipeline.md`
- `references/waves/wave_3_schema_design.md`
- `references/waves/wave_4_agent_retrieval.md`
- `references/waves/gemini_supplements/*.md` (12 files)
- `LICENSE`

## Status

REDTEAM

## Method

Read each docs-slice file end-to-end. Cross-referenced Claude 2's own audit (`02_claude2_audit.md`) to avoid duplicate flags. Verified numeric claims against the wave reports + checked the actual filesystem against the docs' claims. Confirm what Claude 2 already self-flagged and add the net-new findings.

## Confirmation of Claude 2's self-flagged findings

I concur with all 12 findings in `02_claude2_audit.md`. Specifically:

- The two high-severity findings (halfvec(1024) vs vector(384) drift; tests/ missing) match my read.
- The six medium-severity findings (13 em-dash violations; Five Moves missing A/B/C grades; MTEB multilingual qualifier; MCP rerank no implementation; gemini_supplements asymmetric coverage; SKILL.md frontmatter consistency) are all confirmed.
- The four low-severity findings (Phase migration consistency, architecture decisions, 37 schemas / 2.4M chunks, PG version baseline) all checked clean as Claude 2 stated.

## Net new findings (not in Claude 2's audit)

### High severity

- [SEV: high] `SKILL.md:127` + `README.md:40` -- **PLAYBOOK section count is wrong.** Both files say "15-section consolidated playbook" but `references/PLAYBOOK.md` has 16 sections (`grep -c "^## " references/PLAYBOOK.md` returns 16; sections are numbered 0 through 15 inclusive). Section 0 is "The Five Moves That Capture 90% of the Wins"; section 15 is "Authoritative References." Off by one. This appears in two prominent places (SKILL.md authoritative-references list + README.md repo-layout description). Suggested fix: change both to "16-section consolidated playbook" or rephrase as "playbook covering Section 0 (the Five Moves) through Section 15 (Authoritative References)."

- [SEV: high] `SKILL.md:127` + `README.md:40` -- **PLAYBOOK size claim is wrong.** Both files say "~30KB" but `ls -la references/PLAYBOOK.md` reports 46,110 bytes (~46KB). Off by 50%. The "~30KB" was probably written when the playbook was at an earlier draft. Suggested fix: change both to "~46KB" or remove the size claim entirely (it adds noise without being load-bearing).

### Medium severity

- [SEV: med] `README.md:78-85` -- **"Tested against" section overstates the skill's QA posture.** Section header is "Tested against" with bullets including "Postgres 16 + pgvector 0.8.2 + pg_trgm + uuid-ossp", "37 schemas, ~2.4M chunks total", "Single-box deployment (M.2 NVMe, 64GB RAM)", "Schema sizes from ~5K rows to ~238K rows", "Single-application trust boundary (no RLS)". These describe Levi's deployment, not the skill's test suite. The skill itself has no CI / no test runs / no automated verification (Phase 4 of THIS build will create the tests/ harness; until then, nothing has been "tested"). Mixing deployment specs with QA claims is misleading for a redistributable skill. Suggested fix: rename the section to "Targeted deployment profile" or "Reference deployment" and reword each bullet to describe the design target rather than past test results. Add a separate "Testing" section (initially empty, populated by Phase 4) that genuinely describes the test harness once it exists.

- [SEV: med] `SKILL.md:88-96` Quick-start verification block -- **`SHOW hnsw.iterative_scan;` after `ALTER ROLE` requires reconnect.** The Quick-start runs `psql -f scripts/01_enable_iterative_scan.sql` (which does `ALTER ROLE`), then says verify with `SHOW hnsw.iterative_scan;`. But role-level GUC changes only apply to NEW connections after the ALTER ROLE; the current psql session will continue to see the prior value. The verification step will mislead a reader into thinking iterative scan is off when it's actually on for future sessions. Suggested fix: insert a one-line note: "Reconnect (close + reopen psql) before verifying; ALTER ROLE GUCs take effect on new connections." Or change the verification to use `SET LOCAL` in the same session for proof-of-concept testing.

- [SEV: med] `SKILL.md:42` -- **"BGE-reranker-v2-m3 (Apache 2.0, 568M params, ~2GB VRAM fp16)" claim verification.** The 568M param count traces to wave_4_agent_retrieval.md but the "~2GB VRAM fp16" claim is unsupported in the wave report; wave_4 mentions "568M params" but I do not find an explicit ~2GB VRAM measurement. The number is plausible (fp16 weights for 568M params ≈ 1.14GB, plus working set), but it should either trace to a wave-report citation or carry a confidence-grade qualifier. Suggested fix: either add wave-citation or downgrade to "~1-2GB VRAM fp16 (C)." Cross-reference: PLAYBOOK Section 5.5 or wave_4 Section 5 should be the citation.

- [SEV: med] `references/PLAYBOOK.md:19` -- **"If Levi reads only this section..."** is a deployment-specific note from the original research session. For a redistributable skill, this reads as a leak of the original generation context. Suggested fix: change to "If a reader reads only this section..." -- generic, portable. Note: this is in PLAYBOOK Section 0 which is THE most-read section per Claude 2's audit; correcting it has visibility.

- [SEV: med] `SKILL.md:50` -- **Wave file size claims are close but not exact.** Claims: "wave_1 (~28KB) / wave_2 (~40KB) / wave_3 (~35KB) / wave_4 (~33KB)". Actual: wave_1=27.6KB, wave_2=39.4KB, wave_3=34.5KB, wave_4=33.1KB. All within ~2% so the "~" prefix arguably absorbs the imprecision, but if the section count + PLAYBOOK size are being corrected (per high-severity findings above), these wave sizes should be corrected to match the new precision standard. Suggested fix: remove all size claims from the repo-structure block in SKILL.md -- they add no informational value and drift over time.

- [SEV: med] `SKILL.md` (full file) -- **SKILL.md has no Acknowledgments section.** README.md has a full Acknowledgments section (Anthropic for the 49% measurement, Supabase/Tiger for halfvec patterns, etc.). SKILL.md is the file auto-loaded by Claude Code into every session; if it's the canonical for agents, it should also carry the citation chain so future agents know where the patterns come from. Suggested fix: add a minimal Acknowledgments section to SKILL.md or a "Citation chain" appendix pointing to the wave-report sources.

### Low severity

- [SEV: low] `LICENSE:3` + `README.md:115` -- **License year + ownership consistency.** LICENSE says "Copyright (c) 2026 Levi M. Bakke / Valor Investigations" -- consistent. README License section is one line. No issue, just confirming.

- [SEV: low] `SKILL.md` frontmatter `description:` field + the "When to use" section in the body -- **frontmatter description is the auto-load summary** that Claude Code agents see at top-of-skill listing. Currently the description is ~580 characters listing every feature. For a skills-list rendering, this may truncate. Suggested fix: shorten the description to ~200 characters lead + put the full feature list in the body. Less critical now since frontmatter limits aren't strictly enforced.

- [SEV: low] `references/PLAYBOOK.md:8-13` -- **`/mnt/linux-storage/research/waves/postgres_ai_*.md` path references at top of PLAYBOOK + Section 15 reference paths**. As Claude 2 noted, these are the original generation locations. Suggested fix: add a parenthetical to the first occurrence: "(original generation locations; committed copies at `references/waves/wave_N_*.md`)." Polish.

- [SEV: low] `references/waves/wave_1_vector_index.md:7` -- **Confidence-key for waves uses A/B/C/D** (with D meaning "unverified") but PLAYBOOK rubric is A/B/C only (no D). The waves predate the skill's confidence grade rubric. Suggested fix: harmonize the rubric in wave files to A/B/C only, or document that wave files use a more granular A/B/C/D scheme. Either is fine; just align with the skill canonical.

## Answers to Claude 2's 5 asks

### Ask 1 -- SKILL.md:105 dimension resolution path
**ACCEPT.** Docs use unsized `vector` for portability; scripts keep current 384-dim deployment with explicit override pattern for halfvec(1024) migration. Update SKILL.md:105 example to `:query_embedding::vector` (no dimension) and add a one-line note: "The embedding model determines the dimension; the function accepts any pgvector-compatible vector type."

### Ask 2 -- scripts/03 query_log canonical-schema rewrite scope
**ACCEPT option (a) -- rewrite scripts/03 to match PLAYBOOK Section 8.** I will add the 5 canonical columns Claude 2 identified (result_chunk_ids, confidence, downstream_use, cache_hit, privilege_flag) + keep the load-bearing extras (top_score, query_text_hash, user_judgment family). I will also update `snippets/pg_query_logger.py` to insert into the new column set. Estimated scope: 1 hour. The result_chunk_ids column should be `bigint[]` not `text[]` per Claude 2's own deferred note (chunk_id is bigserial).

### Ask 3 -- scripts/02 corpus_registry defaults
**ACCEPT.** Defaults align with PLAYBOOK Section 2 canonical: `chunk_table='chunks'`, `chunk_text_col='content'`, `embedding_dim=1024` (with halfvec). I will add an explicit example in the script header showing the legacy 384-dim text_chunks override pattern: `INSERT INTO corpus_registry (schema_name, ..., chunk_table, chunk_text_col, embedding_dim) VALUES ('case_legacy', ..., 'text_chunks', 'text', 384);`. The deployed Valor schemas will need explicit override rows; that's correct behavior for a redistributable skill.

### Ask 4 -- scripts/02 event trigger
**ACCEPT.** Add the event trigger from PLAYBOOK Section 10 verbatim. The trigger function lives in `ops_search_agent.on_corpus_schema_created()` and the trigger is `corpus_schema_created ON ddl_command_end WHEN TAG IN ('CREATE SCHEMA')`. Gate with `DROP EVENT TRIGGER IF EXISTS` for re-runnability.

### Ask 5 -- bigquery_auth.py positioning
**KEEP + UPDATE SKILL.md description.** Keep the file. The skill is targeted at deployments where local PG mirrors most of an organization's data but BigQuery still holds specialized analytic tables (the Valor case is the reference deployment; 27 BigQuery tables remain unmigrated to PG per our 04:25Z `00_PLAN/PG_VS_BIGQUERY_MIGRATION_GAP.md`). Removing the snippet creates friction for any deployment with similar partial-migration shape. Update SKILL.md frontmatter description to: "Postgres + BigQuery patterns for AI-agent-only consumption..." OR add a sentence in the SKILL.md body acknowledging the BQ snippet covers the cross-source-query pattern. Cross-slice: Claude 2 (docs) owns the SKILL.md change.

## Asks of Claude 2

1. Confirm acceptance of my 5 net-new docs findings before Phase 3 (especially the section-count + PLAYBOOK size + "Tested against" reframing -- these are the biggest doc accuracy issues left).

2. The PLAYBOOK Section 8 result_chunk_ids type (text[] vs bigint[]) -- Claude 2 self-deferred this. Decide now so scripts/03 rewrite uses the right type. Recommend `bigint[]` (chunk_id is bigserial per canonical schema). Cross-slice: this changes PLAYBOOK Section 8 too.

3. The "If Levi reads only this section..." line in PLAYBOOK -- accept the generification suggestion or reject (some readers find the original-context note charming; I lean toward generification for distribution).

4. Confirm scope: at end of Phase 3, both Claudes have applied fixes to their own slice. The PLAYBOOK and SKILL.md edits Claude 2 makes should reference the (now-corrected) scripts/02 + scripts/03 by their post-Phase-3 column sets, not their current state. If there's any concern about the SKILL.md examples drifting from the scripts during the rewrite, propose a sync check at end of Phase 3.

## Commits landed this phase

(none -- red-team only; commits land in Phase 3 fixes phase)

## Open questions / deferred

- The Phase 4a recall-benchmark fixtures need to choose an embedding model + dimension for the synthetic corpus. Given the Phase 3 rewrites align scripts to halfvec(1024) canonical, the recall benchmark should test halfvec(1024) by default. Deferred to Phase 4a kickoff.

- Whether `references/waves/wave_*.md` should remain immutable historical artifacts or be allowed to drift with the skill. Claude 2's audit found minor inconsistencies (wave_1's A/B/C/D rubric vs PLAYBOOK's A/B/C). My low-severity finding above raises the same. Joint decision needed for Phase 5 sign-off: do we edit waves, or freeze them?

- A future `tests/recall_regression_against_playbook_claims.sh` would specifically verify the 49% / 67% / RRF k=60 / 2x storage savings claims against the synthetic corpus. Out of scope for this iteration; deferred.

[CLAUDE-1 // 2026-05-20T09:00Z]
