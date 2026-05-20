# 01 -- Claude 1 -- Phase 1 Audit (Code Slice)

## Slice

- `scripts/01_enable_iterative_scan.sql`
- `scripts/02_create_corpus_registry.sql`
- `scripts/03_create_query_log.sql`
- `scripts/04_comment_on_workhorses.sql`
- `scripts/05_hybrid_rrf_search.sql`
- `snippets/bigquery_auth.py`
- `snippets/pg_query_logger.py`
- `tests/` (currently empty -- see Finding 1)

## Status

AUDIT

## Findings

### scripts/ findings

- **[SEV: high]** `scripts/01_enable_iterative_scan.sql:19` -- Hardcodes `ALTER ROLE levi SET hnsw.iterative_scan = 'relaxed_order';`. The PLAYBOOK Section 0 example uses `valor_agent` (the playbook's canonical agent role name). Skill consumers will not have a role named `levi`. **Fix:** Replace with `:role` psql variable: `ALTER ROLE :"role" SET hnsw.iterative_scan = 'relaxed_order';` and document `psql -v role=valor_agent ...` invocation in the header comment. Add a fallback session-level `SET LOCAL hnsw.iterative_scan` for users who cannot ALTER ROLE.

- **[SEV: high]** `scripts/01_enable_iterative_scan.sql:8` -- Pre-flight `SELECT extname, extversion` check only prints; it does not abort if the version is below 0.8.0 (the feature gate). A consumer on pgvector 0.7.x will get the `unrecognized configuration parameter` error from this session, which is what we hit earlier in the audit conversation. **Fix:** Add a DO block that raises an exception if `pgvector >= 0.8.0` is not satisfied, or at minimum prints a clear error message.

- **[SEV: high]** `scripts/05_hybrid_rrf_search.sql:62-66` -- The tsvector leg of the RRF function uses inline `to_tsvector('english', %I)` and `to_tsvector('english', %I) @@ plainto_tsquery(...)`. This bypasses any GIN index built on a generated `content_tsv` column. On a 238K-chunk corpus this will fall to sequential scan. The PLAYBOOK Section 2 canonical template recommends a `content_tsv` generated column with GIN index. **Fix:** Document the assumption in the function header: "Caller is responsible for ensuring a `to_tsvector('english', <text_col>)` expression index OR a `content_tsv` generated column exists on the target table." Optionally provide a companion DDL script `scripts/00_create_fts_indexes.sql` that adds the indexes idempotently.

- **[SEV: high]** `scripts/04_comment_on_workhorses.sql` -- All 50+ `COMMENT ON` statements reference schemas + tables specific to Levi's deployment (`case_26cv11493`, `case_bingaman_dhs`, `corpus_oregon_public_records_filesystem`, `ops_gmail`, `ops_search_agent`). If any of these schemas does not exist on a consumer's PG cluster, the script will abort at the first missing reference. **Fix:** Either (a) wrap each block in a DO block with an `IF EXISTS` guard and skip silently, OR (b) rename the file to `04_comment_on_workhorses.example.sql` and add a header comment explaining this is a Valor-specific reference template that consumers adapt to their schema names. Option (b) is cleaner for a redistributable skill.

- **[SEV: med]** `scripts/03_create_query_log.sql:21` -- `query_text_hash text GENERATED ALWAYS AS (md5(query_text)) STORED` -- `md5(NULL)` returns NULL, which violates the generated-column STORED contract if query_text is null. Currently allowed because `query_text` itself is not NOT NULL, but the resulting NULL hashes complicate the `query_log_text_hash_idx` btree (NULL entries are not searchable on a btree). **Fix:** `md5(COALESCE(query_text, ''))`.

- **[SEV: med]** `scripts/02_create_corpus_registry.sql:64-78` -- `rebuild_v_evidence_search()` builds a UNION ALL with hardcoded column projection `chunk_id, %I AS content`. If any registered corpus has its chunk_id column named differently (e.g., `id` instead of `chunk_id`), the view rebuild silently fails. Also the projection drops the embedding column entirely, so the view is text-only and cannot be used for vector search. **Fix:** Add a `chunk_id_col` column to `corpus_registry` (default `chunk_id`) and include the embedding column in the view projection when a `vec_col` is registered.

- **[SEV: med]** `scripts/05_hybrid_rrf_search.sql:130-134` -- `EXECUTE sql_text USING query_text, query_vec, k_per_leg, rrf_k, final_k;` binds positional params `$1..$5`. The dynamic SQL uses `$1` (query_text), `$2` (query_vec), `$3` (k_per_leg), `$4` (rrf_k for the RRF formula), `$5` (final_k). Need to verify that `$3` (`LIMIT $3`) is being used as `k_per_leg` everywhere it appears, and `$4` is only in the RRF formula. **Fix:** Add a comment in the SQL string that maps `$N -> param name` for maintainability. Spot-check confirmed the binding order matches but it's fragile.

- **[SEV: low]** `scripts/05_hybrid_rrf_search.sql:121` -- The `format(...)` arg list has 12 placeholders interleaved across legs. Hard to audit by eye. **Fix:** Refactor to build each leg's SQL fragment separately, then concatenate. Easier to maintain and individually testable.

- **[SEV: low]** `scripts/02_create_corpus_registry.sql:50-58` -- `INSERT INTO ... ON CONFLICT (schema_name) DO NOTHING` -- if a corpus is registered but later renamed in `information_schema.schemata`, the orphan registry row persists. **Fix:** Add a separate cleanup query that flags `corpus_registry` rows whose `schema_name` no longer exists in `information_schema.schemata`. Could be a view: `v_corpus_registry_orphans`.

### snippets/ findings

- **[SEV: high]** `snippets/bigquery_auth.py:18` -- `DEFAULT_KEY_PATH = "/home/levi/.claude/keys/valorinvestigates-bigquery.json"`. For a redistributable skill, this is environment-specific and leaks the canonical credential location. **Fix:** Use environment variable `GOOGLE_APPLICATION_CREDENTIALS` with a fallback to a path the user explicitly passes. Remove the hardcoded Levi-specific path entirely. Add a `.env.example` at repo root showing the env-var pattern.

- **[SEV: high]** `snippets/bigquery_auth.py:38-43` -- `self._token()` checks `if not self.creds.valid` then calls `creds.refresh(tr.Request())`. Per google-auth docs, `creds.valid` returns True if the token exists AND has not expired, but the freshness check is based on `expiry` which is updated by `refresh()`. For long-running agents that may hold a `BigQueryClient` for hours, the valid check needs to account for clock skew. **Fix:** Refresh proactively if `not self.creds.valid OR self.creds.expiry < datetime.utcnow() + timedelta(minutes=5)` -- gives a 5-minute safety margin.

- **[SEV: high]** `snippets/pg_query_logger.py:104-110` -- `_insert` opens a brand-new connection per query log row: `with psycopg2.connect(self.dsn) as conn`. The comment says "fresh connection because ctx._conn may have been rolled back" but this creates two connections per logged query. For a high-volume agent doing 100+ queries/min this exhausts the PG connection pool. **Fix:** Use a savepoint pattern on the original connection, OR use a single dedicated logger connection held in the PGQueryLogger instance with a connection-keepalive check. Document the trade-off in the file header.

- **[SEV: med]** `snippets/pg_query_logger.py:91-99` -- `QueryContext.execute()` does `self._cur.fetchall()` even for non-SELECT queries (DDL guard at line 96 catches it via `_cur.description is None`). However, large SELECTs are loaded fully into memory before being returned. For an agent retrieval pattern this is usually fine (top-k results), but a `SELECT * FROM big_table` would OOM. **Fix:** Add a `limit_warning` threshold (e.g., warn if rows_returned > 1000) and document the in-memory fetch behavior.

- **[SEV: med]** `snippets/pg_query_logger.py:135-145` -- The INSERT into `query_log` happens AFTER the query has executed. If the agent crashes between query execution and log insert, the query is invisible. **Fix:** Insert a pending-row BEFORE query execution with status='running', then UPDATE with results after. Tradeoff is doubled write load; acceptable for an observability layer.

- **[SEV: med]** `snippets/bigquery_auth.py:74-87` -- The `query()` method does a synchronous POST and parses the JSON response inline. For BigQuery jobs > 10s, the API returns a `jobReference` and the client must poll. Current implementation will return empty `[]` for any query that doesn't complete in `timeoutMs`. **Fix:** Detect `jobComplete=false` in the response and either (a) raise an exception, OR (b) poll the `jobReference` until complete. Document the current synchronous-only limitation.

- **[SEV: low]** `snippets/bigquery_auth.py:91-95` -- `list_tables` does no pagination beyond `maxResults=200`. The valor_consolidated `valor_investigations` dataset currently has 34 tables; well under 200. But for a redistributable skill, add `nextPageToken` handling for larger datasets.

- **[SEV: low]** `snippets/pg_query_logger.py:155-167` -- The commented-out demo at the bottom imports nothing it doesn't already have, but the `if __name__ == "__main__"` block is fully commented. Either uncomment + make it runnable (with safe defaults), or remove. Currently it's dead code that adds nothing.

### tests/ findings

- **[SEV: high]** `tests/` directory exists (empty). Both `README.md:44` and `SKILL.md:79` (Claude 2's slice) advertise a `tests/` directory with content. My Phase 4 deliverables (recall side) are not yet built. **Fix:** Built in Phase 4a per `BUILD_PROTOCOL.md`. No action this phase. NOTE: this finding is partially cross-slice; the docs claim must be reconciled with the actual state. Claude 2 should flag in `02_claude2_audit.md` as the docs-side analog.

### Cross-slice findings (raised here for Claude 2's attention)

- **[SEV: med]** `SKILL.md:105` references `vector(384)` in the Quick-start example. `scripts/05_hybrid_rrf_search.sql:13` mirrors this with `ARRAY[0.1, 0.2, ...]::vector(384)`. The actual function signature `query_vec vector` is dimension-unspecified (portable). Either: (a) the docs/example should match the function signature and use unsized `vector`, OR (b) the function should constrain to a documented dimension. Recommend (a) -- the skill is portable across embedding models, and 384 is only Levi's `all-MiniLM-L6-v2` choice. Claude 2 owns the SKILL/README change.

## Asks of Claude 2

1. Confirm the doc-vs-code dimension-binding decision (cross-slice Finding above): docs should reflect unsized `vector` to keep the skill portable. If you agree, update SKILL.md and README.md accordingly in Phase 3. If you disagree, raise in your `04_claude2_redteam_of_claude1.md`.

2. The em-dash audit you will run for STATE.md seed inconsistency #5 -- I observed during my audit that `README.md:39-44, 82, 127-132` and `SKILL.md:82, 127-132` contain `—` characters (real em-dashes). Plus our own HANDOFFS files have several. Flag all in your audit; we both need to fix in Phase 3.

3. The `tests/` directory claim in your docs is currently unsubstantiated. Decide whether to (a) keep the claim and rely on me to build it in Phase 4, OR (b) soften the claim until Phase 4 lands. If (a), note the cross-Phase dependency in your STATE.md update.

4. The MCP `rerank` tool reference in SKILL.md:42 (per STATE.md seed inconsistency #2) is also unsubstantiated. This sits squarely in your slice. Decide: (a) remove the reference, (b) move to a "Roadmap" section as future work, OR (c) add an actual MCP tool implementation. I recommend (b) for this iteration.

## Commits landed this phase

- (none -- audit-only phase, no source-code edits)
- `bf26c22  Scaffold HANDOFFS/ for two-Claude parallel verify + harden` (the scaffold itself, landed before Phase 1 began)

## Open questions / deferred

- The PLAYBOOK Section 0 cites "Anthropic-measured 49% retrieval-failure drop; 67% with reranker." I have not verified the citation chain in my slice (the actual measurement lives in references/waves/wave_4_agent_retrieval.md). Claude 2 audits this.

- Hybrid RRF function performance: I have not benchmarked the function against a live corpus. Phase 4a (recall benchmark) will both verify the recall claim and surface performance gaps. Recommend testing against `case_26cv11493_hearing_prep.text_chunks` (24K rows, real evidence corpus).

- The `tests/run_recall.sh` script (Phase 4a) needs to decide whether to require live PG access or run against a deterministic synthetic corpus. Recommend synthetic by default with a `--live` flag for integration testing.

- Whether to add `scripts/00_create_extensions.sql` that ensures `pgvector`, `pg_trgm`, `uuid-ossp` are loaded before scripts/01-05 run. Phase 1 found that Levi's box has them, but a redistributable skill should not assume.

[CLAUDE-1 // 2026-05-20T08:15Z]
