# 04 -- Claude 2 -- Phase 2 red-team of Claude 1's slice

## Slice (target of this red-team)

- `scripts/01_enable_iterative_scan.sql`
- `scripts/02_create_corpus_registry.sql`
- `scripts/03_create_query_log.sql`
- `scripts/04_comment_on_workhorses.sql`
- `scripts/05_hybrid_rrf_search.sql`
- `snippets/bigquery_auth.py`
- `snippets/pg_query_logger.py`

## Status

REDTEAM

## Method

Read each file end-to-end. Compared every assertion against the docs slice
(SKILL.md / PLAYBOOK.md / wave_1-4). Cross-referenced Claude 1's own audit
(`HANDOFFS/01_claude1_audit.md`) to avoid duplicate flags; I confirm what he
already flagged and add what is missing from his self-audit.

## Issues raised against Claude 1's slice

### High severity -- doc-vs-code drift

- [SEV: high] `scripts/03_create_query_log.sql:11-33` -- **deployed `query_log` schema is materially different from `PLAYBOOK.md` Section 8 canonical.**

  PLAYBOOK Section 8 columns (canonical):
  `id, ts, session_id, agent_id, tool_name, args (JSONB), result_count, result_chunk_ids (text[]), latency_ms, cache_hit, rerank_used, rerank_model, confidence, downstream_use, privilege_flag, error`

  Deployed script columns:
  `query_id, submitted_at, agent_name, session_id, query_kind, query_text, query_text_hash, embedding_model, schema_targets, k, rrf_k, rerank_used, rerank_model, latency_ms, rows_returned, top_score, user_judgment, user_judgment_at, user_judgment_by, notes, error`

  Material differences:
  - **MISSING `result_chunk_ids` (text[])** -- the load-bearing column that lets you reconstruct which chunks an agent actually retrieved. Without it the log cannot answer "did this query find the right chunk?" PLAYBOOK Section 8 lists this as required for recall-regression queries.
  - **MISSING `confidence`** -- PLAYBOOK Section 8 + 6.2 specifically call out CRAG-style confidence as the feedback signal for self-correction loops.
  - **MISSING `downstream_use`** -- PLAYBOOK Section 8 lists `'cited_in_filing' | 'discarded' | 'rewritten'` enum for usage tracking.
  - **MISSING `cache_hit`** -- PLAYBOOK lists for cost reporting.
  - **MISSING `privilege_flag`** -- PLAYBOOK explicitly calls this out as Valor-specific for sealed-records sweep before disclosure.
  - **MISSING `args` (JSONB)** -- PLAYBOOK 8 stores tool args as JSONB so any tool (semantic_search, keyword_search, hybrid_search, rerank, etc.) can write to the same log shape. Script uses scalar columns specific to text-query patterns; cannot capture `rerank` tool calls cleanly.
  - **EXTRA `query_text_hash`, `user_judgment`, `user_judgment_at`, `user_judgment_by`, `notes`, `top_score`** -- not in PLAYBOOK Section 8. Some are useful additions; some duplicate other columns.

  Suggested fix: rewrite scripts/03_create_query_log.sql to match PLAYBOOK Section 8 exactly + ADD any useful extras (top_score, query_text_hash) as additional columns, keeping ALL canonical columns. Then update `snippets/pg_query_logger.py` to insert into the new column set. Also update the PLAYBOOK Section 8 to reflect any additions if the extras are kept (cross-slice; I will need to update PLAYBOOK).

- [SEV: high] `scripts/02_create_corpus_registry.sql:17-21` -- **deployed registry hardcodes Valor-specific table/column conventions that conflict with PLAYBOOK Section 2 canonical template.**

  Deployed defaults: `chunk_table DEFAULT 'text_chunks'`, `chunk_text_col DEFAULT 'text'`, `chunk_vec_col DEFAULT 'embedding'`, `embedding_model DEFAULT 'sentence-transformers/all-MiniLM-L6-v2'`, `embedding_dim DEFAULT 384`.

  PLAYBOOK Section 2 canonical: table named `chunks` (not `text_chunks`); text column named `content` (not `text`); embedding column `halfvec(1024)` with voyage-context-3 / Qwen3-Embedding-8B (not vector(384) MiniLM).

  Effect: a deployer who creates a corpus following PLAYBOOK Section 2 canonical (table `chunks`, column `content`, halfvec(1024)) will register it in `corpus_registry` and the auto-rebuild of `v_evidence_search` will silently fail because the script's `chunk_table='text_chunks'` default does not match. Or the deployer has to manually pass overrides for every corpus.

  Suggested fix: align the defaults with PLAYBOOK Section 2 -- `chunk_table='chunks'`, `chunk_text_col='content'`, `embedding_dim=1024`. Document the override pattern in script header for legacy 384-dim text_chunks corpora. The override is `INSERT INTO corpus_registry ... VALUES ('case_legacy', 'case', '...', 'all-MiniLM-L6-v2', 384, 'text_chunks', 'text', ...);` -- explicit; not silent.

- [SEV: high] `scripts/02_create_corpus_registry.sql:37-51` -- **one-time backfill via INSERT, but PLAYBOOK Section 10 requires an event trigger for ongoing auto-registration.**

  PLAYBOOK Section 10 (lines 781-801) shows `CREATE EVENT TRIGGER corpus_schema_created ON ddl_command_end WHEN TAG IN ('CREATE SCHEMA') EXECUTE FUNCTION ops_records_officer.on_corpus_schema_created();`. The event trigger fires every CREATE SCHEMA matching the corpus-naming pattern, auto-registers, AND calls `rebuild_v_evidence_search()`.

  Deployed script does one-time backfill at install time only. After installation, creating `case_eckstein` does NOT auto-register; the deployer must INSERT manually + call `rebuild_v_evidence_search()` themselves. This negates the "auto-rebuild on schema change" promise the PLAYBOOK makes.

  Suggested fix: add the `CREATE OR REPLACE FUNCTION ops_search_agent.on_corpus_schema_created()` + `CREATE EVENT TRIGGER corpus_schema_created` from PLAYBOOK Section 10 to scripts/02. Also gate it with IF NOT EXISTS for re-runnability.

### Medium severity -- MATERIALIZED + canonical query function

- [SEV: med] `scripts/05_hybrid_rrf_search.sql:50-77` -- **CTE legs are NOT `MATERIALIZED`; PLAYBOOK Section 5.1 explicitly requires it.**

  PLAYBOOK Section 5.1 line 518: "`MATERIALIZED` keeps each leg honest (planner won't fold the iterative scan)." The deployed function uses plain `WITH vector_leg AS (...), fts_leg AS (...), trgm_leg AS (...)` -- without `MATERIALIZED`, Postgres 12+ may inline the CTE definitions, which can defeat the iterative HNSW scan behavior the function depends on for accurate rank computation.

  Suggested fix: change each leg to `vector_leg AS MATERIALIZED (...)`, `fts_leg AS MATERIALIZED (...)`, `trgm_leg AS MATERIALIZED (...)` in the format string at lines 50, 60, 70.

- [SEV: med] `scripts/05_hybrid_rrf_search.sql:54,62,72` -- **`ROW_NUMBER()` used instead of `RANK()` from PLAYBOOK Section 5.1.**

  PLAYBOOK Section 5.1 example uses `RANK() OVER (ORDER BY ...)`. RANK assigns the same rank to ties; ROW_NUMBER breaks ties arbitrarily. For RRF, ROW_NUMBER produces slightly different reciprocal-rank scores when distance/relevance ties exist (which is common in trigram and fts legs).

  Suggested fix: replace `ROW_NUMBER()` with `RANK()` in all three legs at lines 54, 62, 72. The behavior diff is small but the PLAYBOOK is canonical and this is a deterministic-output discrepancy.

- [SEV: med] `scripts/03_create_query_log.sql:18` -- **generated column `md5(query_text)` returns NULL when query_text is NULL** (Claude-1 self-flagged this; confirming). `query_text` is not NOT NULL constrained, so NULL hashes are possible, and the `query_log_text_hash_idx` btree on a NULL-tolerant column makes duplicate detection broken on those rows.

  Suggested fix (per Claude-1): `md5(COALESCE(query_text, ''))`. Confirm + adopt.

- [SEV: med] `snippets/pg_query_logger.py:109-148` -- **`_insert` opens a NEW psycopg2 connection per query log row** (Claude-1 self-flagged). For an agent doing 100+ queries/min this exhausts the PG connection pool. Confirm + add concrete fix: use a single dedicated logger connection held in `PGQueryLogger.__init__`, reconnect-on-error, with a connection keepalive (`SELECT 1` heartbeat). Or accept the per-log connection cost and document the limit at 50 queries/sec.

- [SEV: med] `snippets/bigquery_auth.py:22` -- **hardcoded `DEFAULT_KEY_PATH = "/home/levi/.claude/keys/valorinvestigates-bigquery.json"`** (Claude-1 self-flagged). Confirm + add concrete fix: use `os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")` with a fallback to the parameter, and remove the Levi-specific default. Add `.env.example` at repo root showing the env-var pattern.

- [SEV: med] `snippets/bigquery_auth.py` -- **positioning conflict with skill description**. SKILL.md:1 description: "Postgres patterns for AI-agent-only consumption." But `bigquery_auth.py` is included as a snippet. SKILL.md:77 lists it as "service-account auth boilerplate" -- but for BigQuery, not Postgres. A user installing this as a Claude Code skill expects PG-only patterns; the BQ snippet is a positioning conflict.

  Suggested fix: either (a) remove `bigquery_auth.py` from this skill and put it in a sister skill, OR (b) update SKILL.md:1 to "Postgres + BigQuery patterns for AI-agent-only consumption" and explicitly note the BQ snippet is for the 27 BigQuery tables that remain unmigrated. (b) is honest to the deployment; (a) is honest to the skill's positioning. Cross-slice: I (docs) can fix the SKILL.md description if Claude 1 confirms keeping bigquery_auth.py is intentional.

- [SEV: med] `scripts/02_create_corpus_registry.sql:78-82` -- **view rebuild drops embedding column entirely** (Claude-1 self-flagged). The auto-rebuilt `v_evidence_search` is text-only; cannot be used for cross-schema vector search. PLAYBOOK Section 10 line 770 includes `c.embedding, c.embedding_model` in the projection.

  Suggested fix (per Claude-1): include `c.embedding` and `c.embedding_model` in the projection. Note that the type must be unified across schemas -- if some corpora use `vector(384)` and others use `halfvec(1024)`, the view UNION will fail type-check. Worth a header comment that this view assumes all included corpora share the same embedding type.

### Low severity -- style / portability / dead-code

- [SEV: low] `scripts/01_enable_iterative_scan.sql:19` -- **hardcodes `ALTER ROLE levi`** (Claude-1 self-flagged). Confirm + concrete fix: use psql variable `:"role"` with header documentation `psql -v role=valor_agent -f scripts/01_enable_iterative_scan.sql`. PLAYBOOK Section 0 + Section 4.3 use `valor_agent`; align scripts to the same role name OR make it explicitly a variable.

- [SEV: low] `scripts/04_comment_on_workhorses.sql:24` -- **COMMENT text says `vector(384)` and `vector_cosine_ops` consistent with deployed scripts, but inconsistent with PLAYBOOK Section 2 canonical** (`halfvec(1024)` with `halfvec_cosine_ops`). Once the dimension question is resolved (per my SKILL.md cross-slice high finding), update the COMMENT text to match. Currently the comment will mislead agents about the actual column type after a halfvec migration.

- [SEV: low] `snippets/pg_query_logger.py:151-168` -- **commented-out demo block at end of file is dead code** (Claude-1 self-flagged). Confirm + recommendation: either move the demo to `snippets/pg_query_logger_example.py` (separate file), OR uncomment + wrap with `if __name__ == "__main__":` and make it runnable against a safe default DSN.

- [SEV: low] `scripts/05_hybrid_rrf_search.sql:79-85` -- **`candidates AS (UNION ...)` uses UNION not UNION ALL**. UNION dedupes, which is the right behavior for the candidate set, but a query reviewer would expect UNION ALL with explicit DISTINCT later. Either way works; recommend adding a one-line comment `-- UNION dedupes candidate chunk_ids across legs`. Minor polish.

- [SEV: low] `snippets/bigquery_auth.py:38-43` -- **`creds.valid` freshness check has no clock-skew buffer** (Claude-1 self-flagged). Confirm + concrete fix: `if not self.creds.valid or self.creds.expiry < datetime.utcnow() + timedelta(minutes=5)` with `from datetime import datetime, timedelta` import.

- [SEV: low] `scripts/05_hybrid_rrf_search.sql:126-128` -- **header comment says "Convenience wrapper that auto-detects pg_trgm availability + falls back gracefully (Left as exercise; ...)"**. Dead-letter TODO; either implement or remove the comment. Recommend remove for now; promote to a Phase 6 task if needed.

## Confirmation of Claude 1's self-flagged findings

I concur with all 19 findings in `01_claude1_audit.md`. Specifically:

- The 4 high-severity scripts findings (hardcoded `levi` role; missing pgvector version gate; tsvector index assumption; schema-specific COMMENT ON without IF EXISTS) all match my read.
- The 3 high-severity snippet findings (hardcoded key path; clock-skew valid check; connection-per-log) all match.
- The cross-slice dimension question (`SKILL.md:105` `vector(384)`) I have already raised as my high finding #1 in `02_claude2_audit.md`. Claude 1 recommends docs reflect unsized `vector`; I will accept that as the resolution path and update SKILL.md:105 in Phase 3 to use unsized `vector` for portability.

## Net new findings (not in Claude 1's audit)

| File | Finding | Severity |
|------|---------|----------|
| scripts/03 | query_log schema drift from PLAYBOOK Section 8 (5 missing canonical columns) | high |
| scripts/02 | corpus_registry default `text_chunks` / `text` / 384 contradicts PLAYBOOK Section 2 canonical | high |
| scripts/02 | missing event trigger for auto-registration of new schemas | high |
| scripts/05 | CTE legs not MATERIALIZED per PLAYBOOK Section 5.1 | med |
| scripts/05 | ROW_NUMBER vs RANK divergence from PLAYBOOK | med |
| snippets/bigquery_auth.py | positioning conflict with "Postgres-native" skill description | med |
| scripts/05 | UNION vs UNION ALL on candidates | low |
| scripts/05 | dead-letter TODO comment about pg_trgm fallback | low |

## Asks of Claude 1

1. Confirm the resolution path for the dimension question (Section "Confirmation" above + my 02_claude2_audit.md high finding #1). If you accept that SKILL.md:105 moves to unsized `vector` and the scripts stay at 384-dim, I'll update SKILL.md in Phase 3.

2. Confirm scope for the scripts/03 query_log canonical-schema rewrite. Three options: (a) align the deployed schema to PLAYBOOK Section 8 (rewrites scripts/03 + pg_query_logger.py); (b) update PLAYBOOK Section 8 to match the deployed schema (cross-slice, I rewrite Section 8); (c) document the deployed-vs-canonical drift and ship both (less clean but defers the rewrite). Recommend (a) for skill cleanliness, since the deployed columns are missing the load-bearing fields (result_chunk_ids, confidence, downstream_use, privilege_flag). Your call.

3. Confirm scope for the scripts/02 corpus_registry defaults rewrite. The same three options apply. The PLAYBOOK Section 2 canonical (`chunks` / `content` / `halfvec(1024)`) is the "right" answer; the deployed default (`text_chunks` / `text` / `vector(384)`) reflects current Valor deployment. Recommend keep `chunks`/`content`/`halfvec(1024)` as the registry defaults (skill canonical) and explicitly document the override pattern for legacy 384-dim corpora.

4. Confirm scope for scripts/02 event trigger addition. PLAYBOOK Section 10 specifies an event trigger; deployed script omits it. Recommend add the event trigger from PLAYBOOK Section 10 verbatim (lines 781-801).

5. Confirm whether `snippets/bigquery_auth.py` stays in this skill or moves. If stays, I'll update SKILL.md:1 description to acknowledge the BQ scope; if moves, you remove the file and I'll update SKILL.md:77 to drop the reference.

## Commits landed this phase

(none -- red-team only; commits land in Phase 3 fixes phase)

## Open questions / deferred

- The PLAYBOOK Section 8 `result_chunk_ids` field is a text[] in PLAYBOOK but should probably be bigint[] since chunk_id is bigserial in the canonical schema. Minor type-mismatch in PLAYBOOK Section 8 itself; I'll note as a docs-side fix in Phase 3 of my own slice.
- Performance: should the query_log have a partitioned-by-month or BRIN index on `submitted_at` for high-write workloads? Deferred to Phase 4b after we measure write rate.
- The `audit_log` table from PLAYBOOK Section 9 is not in any scripts/ file. Deferred -- the audit-log is intended to be applied per-corpus-schema via trigger, which lives in the canonical schema template (PLAYBOOK Section 2), not in a workhorse script. No action needed in scripts/ slice.

[CLAUDE-2 // 2026-05-20T08:45Z]
