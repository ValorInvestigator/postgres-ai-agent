# 02 -- Claude 2 -- Phase 1 audit (docs slice)

## Slice

- `SKILL.md`
- `README.md`
- `references/PLAYBOOK.md`
- `references/waves/wave_1_vector_index.md`
- `references/waves/wave_2_ingest_pipeline.md`
- `references/waves/wave_3_schema_design.md`
- `references/waves/wave_4_agent_retrieval.md`
- `references/waves/gemini_supplements/*.md` (12 files)

## Status

AUDIT

## Findings

Listed by severity (high / med / low). Each finding has `file:line` and a concrete suggested fix.

### High severity

- [SEV: high] `SKILL.md:54` + `SKILL.md:105` + `references/PLAYBOOK.md:120,155,167,250` -- **embedding-dimension architecture drift.** SKILL.md and PLAYBOOK declare `halfvec(1024)` as the canonical default ("halfvec by default" SKILL.md:54; canonical DDL uses `halfvec(1024)` in PLAYBOOK Section 2). But SKILL.md:105's example query uses `:query_embedding::vector(384)`. And the actual deployed scripts (read-only from my slice) use vector(384) with sentence-transformers/all-MiniLM-L6-v2 -- see `scripts/02_create_corpus_registry.sql:18` (DEFAULT 384), `scripts/04_comment_on_workhorses.sql:15,18,24` (`vector(384)`, `all-MiniLM-L6-v2`). Either PLAYBOOK is aspirational and scripts are legacy, OR scripts must migrate to halfvec(1024). Suggested fix: pick one canonical and align. If halfvec(1024) is the goal, add a migration paragraph to PLAYBOOK Section 13 Phase 3 (already exists at line 893 "Migrate to halfvec partial HNSW") explicitly listing the 384-dim corpora as the migration target. Then update SKILL.md:105 example to `halfvec(1024)`. If vector(384) is the actual current state, update SKILL.md:54 to "halfvec(1024) for new corpora; existing 384-dim corpora preserved during migration." Cross-slice ask to Claude 1.

- [SEV: high] `SKILL.md:79` + `README.md:44` -- **`tests/` directory listed in repo-structure trees but does not exist** (seed inconsistency from STATE.md). Suggested fix: keep the references where they are; Phase 4 of this build creates `tests/`. No edit needed in Phase 1 / Phase 3 -- the directory will be created in Phase 4a by both Claudes. Flag here for tracking; resolves at Phase 4 sign-off.

### Medium severity

- [SEV: med] `SKILL.md:82,127-132` + `README.md:39-44` -- **13 em-dash style violations**. Style rule at `SKILL.md:142` ("No em dashes. Use double hyphens.") and `README.md:101` ("No em dashes. Double hyphens.") are violated by the very files that state the rule. Specifically:
  - `SKILL.md:82` "Phase 1 — same-day low-risk wins"
  - `SKILL.md:127` "PLAYBOOK.md — full 15-section..."
  - `SKILL.md:128` "wave_1_vector_index.md — HNSW..."
  - `SKILL.md:129` "wave_2_ingest_pipeline.md — Docling..."
  - `SKILL.md:130` "wave_3_schema_design.md — schema-per-corpus..."
  - `SKILL.md:131` "wave_4_agent_retrieval.md — MCP tool..."
  - `SKILL.md:132` "gemini_supplements/ — Gemini Pro deep-dives..."
  - `README.md:39` "SKILL.md — Claude Code skill metadata..."
  - `README.md:40` "PLAYBOOK.md — 15-section consolidated..."
  - `README.md:41` "waves/ — the four authoritative..."
  - `README.md:42` "scripts/ — Phase 1 SQL ready..."
  - `README.md:43` "snippets/ — Python boilerplate..."
  - `README.md:44` "tests/ — regression harness..."
  Suggested fix: replace `—` (U+2014) with ` -- ` (space + double hyphen + space) on each of the 13 lines. PLAYBOOK and all four wave files have 0 em-dashes (clean). Will fix in Phase 3.

- [SEV: med] `SKILL.md:28-42` -- **Five Moves section omits A/B/C confidence grades.** PLAYBOOK Section 0 lists the same five moves with grades: #1 (A), #2 (A), #3 (A), #4 (C), #5 (A/B). SKILL.md lists them with no grades. SKILL.md:134-138 even establishes the grading rubric for the file. Style rule at `SKILL.md:144` says "Anchor every architectural claim on a wave-report citation." The Five Moves section is the most-read part of the skill and should carry its grades. Suggested fix: append the same (A) / (A) / (A) / (C) / (A/B) grades to SKILL.md moves 1-5, and add a sentence in each move tying back to the relevant wave-report section. Will fix in Phase 3.

- [SEV: med] `SKILL.md:54` -- **"MTEB 70.58" missing the "multilingual" qualifier.** PLAYBOOK:301,314 and wave_2_ingest_pipeline.md:15,205 all specify "MTEB **multilingual** 70.58" for Qwen3-Embedding-8B. SKILL.md:54 drops the qualifier. The multilingual variant of MTEB is a different benchmark from the standard MTEB v2 ranking; dropping the qualifier is a benchmark-name error that misrepresents the metric. Suggested fix: change SKILL.md:54 to "Qwen3-Embedding-8B (Apache 2.0, MTEB multilingual 70.58)". Will fix in Phase 3.

- [SEV: med] `SKILL.md:42` + `references/PLAYBOOK.md:27,536,551` -- **MCP `rerank` tool referenced without implementation.** The skill describes `rerank(query, docs[], model='bge-v2-m3')` as one of the 10 MCP tools but there is no MCP server scaffolding anywhere in the repo. The BUILD_PROTOCOL marks this "out of scope" for the current pass. Suggested fix: leave the references in (the skill describes a target architecture), but add a one-line "(MCP server scaffolding deferred to future iteration; see BUILD_PROTOCOL.md `## Out of scope`)" note in SKILL.md right after the move-5 paragraph and in PLAYBOOK Section 6.4 closing. Will fix in Phase 3.

- [SEV: med] `SKILL.md:132` + `README.md:41` -- **gemini_supplements coverage is asymmetric across waves, but the docs imply per-wave parity.** Actual layout: 7 supplements for wave 4 (`postgres_ai_agent_retrieval_gemini_*`), 4 for wave 2 ingest (`postgres_ai_ingest_gemini_*`), 1 for wave 1 vector index (`postgres_ai_vector_index_gemini.md`), and **0 for wave 3 schema design**. SKILL.md:132 says "Gemini Pro deep-dives on specific subtopics" -- plural and generic, but reader expects per-wave parity. Suggested fix: in SKILL.md:132 and README.md:41 reword to "Gemini Pro deep-dives concentrated on agent retrieval and ingest pipeline subtopics (per-wave coverage is asymmetric; wave 3 schema design has no supplement)." Low-priority polish; will fix in Phase 3 alongside the other doc edits.

### Low severity

- [SEV: low] `SKILL.md:115-123` (Phased migration plan table) vs `references/PLAYBOOK.md:875-918` (Section 13) -- **substantive consistency check passed.** Both list six phases ordered by leverage. Phase themes match. SKILL.md is the abridged table; PLAYBOOK Section 13 has the full substeps. Phase 3 wording slight rephrase ("Index modernization (halfvec, partial indexes, 3-way RRF)") vs PLAYBOOK ("halfvec partial HNSW"). Substantively equivalent. No edit needed.

- [SEV: low] `SKILL.md:46-54` Architecture decisions (locked) -- **all 9 bullets cross-checked against PLAYBOOK Section 1** (schema-per-corpus, no RLS, no mega-matview, trigger audit, PG-native graph, defer partitioning, halfvec default, Docling/Marker/Surya cascade, Qwen3 / voyage). All substantively consistent. No edit needed.

- [SEV: low] `README.md:81` and `references/PLAYBOOK.md:5` -- **"37 schemas, ~2.4M chunks" cross-doc consistency check passed.** wave_1:4 and wave_3:32,306 both reference 2.4M chunks. wave_3:543 "Migration plan for existing 37 schemas" matches. No drift.

- [SEV: low] `SKILL.md:144` style rule "Postgres 16, pgvector 0.8.2, pg_trgm, uuid-ossp baseline assumed" -- **cross-check against PLAYBOOK:5** "Postgres 16, pgvector 0.8.2, pg_trgm, uuid-ossp." Match. No edit.

- [SEV: low] `references/PLAYBOOK.md:8-13` -- **mentions per-wave reports living at `/mnt/linux-storage/research/waves/postgres_ai_*.md`** while the actual files in `references/waves/` are named `wave_1_vector_index.md`, `wave_2_ingest_pipeline.md`, etc. PLAYBOOK Section 15 has the same `/mnt/linux-storage/` paths. This is intentional source-trail metadata (the originals live at those paths; the references are committed copies). Suggested fix: add a one-line note in PLAYBOOK Section 15 making explicit that the `/mnt/linux-storage/...` paths are the original generation locations and the committed copies live at `references/waves/wave_N_*.md`. Will fix in Phase 3 for clarity.

## Issues raised against the other slice (preliminary -- formal red-team in Phase 2)

These are observed while auditing my own slice but pertain to Claude 1's slice. They will be re-stated formally in `04_claude2_redteam_of_claude1.md` during Phase 2.

- [SEV: high cross-slice] `scripts/02_create_corpus_registry.sql:18` -- `embedding_dim integer NOT NULL DEFAULT 384`. SKILL.md and PLAYBOOK declare halfvec(1024) as the default; scripts hard-code 384. (See High Finding #1 above.)
- [SEV: high cross-slice] `scripts/04_comment_on_workhorses.sql:15,18,24` -- COMMENT ON content states vector(384) with all-MiniLM-L6-v2; PLAYBOOK Section 2 canonical DDL is halfvec(1024) with voyage-context-3 / Qwen3-Embedding-8B.
- [SEV: med cross-slice] `scripts/05_hybrid_rrf_search.sql:13` -- example block uses `vector(384)`. Should be aligned with whichever canonical the team picks.

## Asks of the other Claude

- Confirm the canonical embedding dimension/type. Should the deployed scripts target halfvec(1024) per the PLAYBOOK canonical, OR should the docs acknowledge the 384-dim sentence-transformers/all-MiniLM-L6-v2 deployment as the current legacy state and document the migration? This decision drives my SKILL.md:105 fix.
- Confirm whether scripts/ files have any other dimension-implicit assumptions I should be aware of when I write the SKILL.md fixes in Phase 3.
- Confirm that the snippets/bigquery_auth.py credential handling is intentional. SKILL.md:77 lists it as "service-account auth boilerplate." I will not edit snippets, but if you confirm in your audit that the credential handling is safe, I will leave the SKILL.md description as-is.

## Commits landed this phase

(none yet -- audit only; commits land in Phase 3 fixes)

## Open questions / deferred

- Phase 4 tests/ harness will be co-built by Claude 1 (recall side) + Claude 2 (latency side); deferred per BUILD_PROTOCOL.md.
- MCP `rerank` tool scaffolding intentionally out of scope per BUILD_PROTOCOL.md.
- gemini_supplements/ asymmetric coverage flagged but not blocking; can be deferred to a future iteration if Phase 3 timeline is tight.
- The PLAYBOOK Section 4.3 example uses `valor_agent` as the role name; this is consistent across SKILL.md and PLAYBOOK but reads as a specific user. Consider adding a brief note that this is a placeholder role name a deployer should substitute. Low priority; deferred unless cross-slice review flags it.
