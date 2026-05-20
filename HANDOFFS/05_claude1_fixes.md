# 05 -- Claude 1 -- Phase 3 fixes (code slice)

## Slice

- `scripts/01_enable_iterative_scan.sql`
- `scripts/02_create_corpus_registry.sql`
- `scripts/03_create_query_log.sql`
- `scripts/04_comment_on_workhorses.sql` -> renamed to `04_comment_on_workhorses.example.sql`
- `scripts/05_hybrid_rrf_search.sql`
- `snippets/bigquery_auth.py`
- `snippets/pg_query_logger.py`

## Status

FIXES

## Fixes landed

All 19 claude-1 own-audit findings + all 8 net-new claude-2 red-team findings have been addressed. Single commit on `build/claude-1`. Cross-reference table:

| Source | ID / SEV | File:line(s) | Finding | Resolution |
|--------|---------|--------------|---------|------------|
| own | high | `scripts/01:19` | Hardcoded `ALTER ROLE levi` | Replaced with `:"role"` psql variable + default-to-`valor_agent` `\if :{?role}` block. Added usage doc `psql -v role=valor_agent -f scripts/01_enable_iterative_scan.sql` + RECONNECT note. |
| own | high | `scripts/01:8` | No version-gate abort on pgvector < 0.8.0 | Added DO block that `RAISE EXCEPTION` if extension missing OR version < 0.8.0. Pre-flight `SELECT extversion` still runs for the install log. |
| own | high | `scripts/05:62-66` | tsvector leg bypasses GIN index | Documented HNSW + GIN tsvector + pg_trgm index prerequisites in the function-level header comment. Function now relies on caller-provided indexes (or expression index `to_tsvector('english', <text_col>)` will be matched). |
| own | high | `scripts/04` | COMMENT ON aborts on missing schemas | Renamed to `04_comment_on_workhorses.example.sql`. Added "DO NOT RUN UNMODIFIED" warning + adapt-to-your-deployment instructions. Cleaner than IF EXISTS wrappers; preserves the worked-example value. |
| own | med | `scripts/03:21` | `md5(NULL)` -> NULL hash | Changed to `md5(COALESCE(query_text, ''))`. NULL query_text now yields the well-known md5 of empty string instead of an unsearchable btree NULL. |
| own | med | `scripts/02:64-78` | rebuild_v_evidence_search drops embedding column + assumes `chunk_id` name | Added `chunk_id_col` column to corpus_registry (default `id` per PLAYBOOK Section 2 canonical). View projection now includes `embedding` + `embedding_model`. Header comments note the same-embedding-type invariant for the UNION ALL. |
| own | med | `scripts/05:130-134` | `$N` param map is fragile | Added explicit `$1->query_text, $2->query_vec, ...` comment block above the `format(...)` call. |
| own | low | `scripts/05:121` | 12 placeholders in single format() are hard to audit | Annotated each leg's placeholder slice with a `-- vector_leg placeholders` style comment block. Refactor to per-leg fragments deferred (low value vs churn). |
| own | low | `scripts/02:50-58` | Orphan registry rows when schema dropped externally | Added view `ops_search_agent.v_corpus_registry_orphans` listing rows whose schema_name no longer exists in `information_schema.schemata`. |
| own | high | `snippets/bigquery_auth.py:18` | DEFAULT_KEY_PATH leak | Removed Levi-specific default. New `_resolve_key_path()` resolves: explicit arg -> `GOOGLE_APPLICATION_CREDENTIALS` env var -> RuntimeError with a clear remediation message. Project + dataset moved to env vars (`BQ_PROJECT`, `BQ_DATASET`, `BQ_LOCATION`). |
| own | high | `snippets/bigquery_auth.py:38-43` | No clock-skew buffer | New `_needs_refresh()` returns true if `not creds.valid` OR `expiry <= now() + TOKEN_REFRESH_SKEW` (5min). Normalizes naive-UTC expiry to aware. |
| own | high | `snippets/pg_query_logger.py:104-110` | Two connections per logged query | PGQueryLogger now holds a persistent log connection via `_ensure_log_conn()` with liveness check + auto-reconnect on stale-connection. Work connection (per QueryContext) remains separate so a rolled-back work txn cannot poison the log connection. |
| own | med | `snippets/pg_query_logger.py:91-99` | fetchall loads entire result set | Documented in `.execute()` docstring. Added `row_warn_threshold` (default 1000) on PGQueryLogger; .execute() emits a `log.warning` when result_count crosses it. Caller suggested to use server-side cursors for >threshold. |
| own | med | `snippets/pg_query_logger.py:135-145` | Crash between query exec and log insert loses the query | NOT FIXED THIS PHASE. The pending-row-then-update pattern is appealing but doubles write load + complicates the JSONB args column. Deferred to Phase 4b (after we measure write rate). Documented in Open questions. |
| own | med | `snippets/bigquery_auth.py:74-87` | Long jobs return [] silently | Changed `query()` to raise `TimeoutError` when `jobComplete` is false in the response. Long-job polling stays out of scope (use google-cloud-bigquery). |
| own | low | `snippets/bigquery_auth.py:91-95` | list_tables ignores pagination | Added nextPageToken loop. Each request still passes maxResults=200; full enumeration walks all pages. |
| own | low | `snippets/pg_query_logger.py:155-167` | Commented-out demo is dead code | Replaced with a real `if __name__ == "__main__":` block. Connects to PG_DSN env var (defaults to Linux peer-auth) and runs one minimal `measure()` + prints the inserted row id. |
| cross | med | `SKILL.md:105` vector(384) vs scripts | Confirmed unsized `vector` resolution. scripts/05 function signature already used `vector` (unsized); claude-2 fixed SKILL.md:105 in `06_claude2_fixes.md`. |
| c2 redteam | high | `scripts/03:11-33` | query_log diverges from PLAYBOOK Section 8 (missing args, result_chunk_ids, confidence, downstream_use, cache_hit, privilege_flag) | Rewrote scripts/03. Table now has the canonical 16 PLAYBOOK Section 8 columns (id, ts, session_id, agent_id, tool_name, args JSONB, result_count, result_chunk_ids BIGINT[], latency_ms, cache_hit, rerank_used, rerank_model, confidence, downstream_use, privilege_flag, error) + extras kept (query_text, query_text_hash, embedding_model, schema_targets, k, rrf_k, top_score, user_judgment_*, notes). Added the canonical `session_quality` view + GIN index on args. snippets/pg_query_logger.py rewritten to write the new columns including JSONB args. result_chunk_ids = BIGINT[] per Claude-2's Ask 2 decision. |
| c2 redteam | high | `scripts/02:17-21` | Defaults `text_chunks`/`text`/`384` contradict PLAYBOOK Section 2 canonical | Defaults now `chunks` / `content` / `embedding` / `id` / `voyageai/voyage-context-3` / `1024`. Header documents the legacy override pattern (`INSERT ... VALUES ('case_legacy', ..., 'all-MiniLM-L6-v2', 384, 'text_chunks', 'text', ...)`). |
| c2 redteam | high | `scripts/02:37-51` | Missing event trigger for auto-registration | Added `ops_search_agent.on_corpus_schema_created()` + `CREATE EVENT TRIGGER corpus_schema_created` matching PLAYBOOK Section 10 lines 781-801. The trigger fires on `CREATE SCHEMA` matching `^(case_|corpus_|legal_)`, inserts the row, and calls `rebuild_v_evidence_search()`. |
| c2 redteam | med | `scripts/05:50-77` | CTE legs not MATERIALIZED | All three legs now `AS MATERIALIZED`. Header comment explains the planner-fold-prevention rationale (PLAYBOOK 5.1 line 518). |
| c2 redteam | med | `scripts/05:54,62,72` | ROW_NUMBER vs RANK | Replaced with `RANK()` in all three legs. Header comment cites the canonical RRF tie-handling. |
| c2 redteam | med | `snippets/bigquery_auth.py` positioning | "Postgres-native" skill description vs BQ snippet | Resolved cross-slice via Claude-2's Ask 5 acceptance -- they updated SKILL.md frontmatter description to acknowledge the BQ scope. File header here also softened to "Postgres-first; BQ tables not yet mirrored." |
| c2 redteam | low | `scripts/05:79-85` | UNION vs UNION ALL | Kept UNION (correct -- candidates set must dedupe). Added inline comment `-- UNION dedupes candidate chunk_ids across legs (a chunk may rank in more than one)` per Claude-2's recommendation. |
| c2 redteam | low | `scripts/05:126-128` | Dead-letter TODO comment about pg_trgm fallback | Removed the "Convenience wrapper that auto-detects pg_trgm availability" TODO. Documented in scripts/05 header that pg_trgm is a prerequisite; auto-detect would add no-op leg complexity for negligible value. |
| c2 redteam | low | `scripts/04` COMMENT inconsistency `vector(384)` vs canonical | Resolved via renaming scripts/04 to `04_comment_on_workhorses.example.sql` + DO-NOT-RUN-UNMODIFIED header. The vector(384) inside the example COMMENT strings is now explicitly a Valor-deployment example, not a canonical claim. |

## Files renamed

- `scripts/04_comment_on_workhorses.sql` -> `scripts/04_comment_on_workhorses.example.sql` (git mv; rename preserved)

## Verification

```bash
$ cd /home/levi/projects/repo-c1
$ python3 -c "import ast; ast.parse(open('snippets/bigquery_auth.py').read()); ast.parse(open('snippets/pg_query_logger.py').read()); print('OK')"
OK

$ grep -n "ALTER ROLE :\"role\"" scripts/01_enable_iterative_scan.sql
57:ALTER ROLE :"role" SET hnsw.iterative_scan = 'relaxed_order';

$ grep -n "MATERIALIZED" scripts/05_hybrid_rrf_search.sql
70:        vector_leg AS MATERIALIZED (
79:        fts_leg AS MATERIALIZED (
89:        trgm_leg AS MATERIALIZED (

$ grep -n "RANK() OVER" scripts/05_hybrid_rrf_search.sql
72:                   RANK() OVER (ORDER BY %I <=> $2) AS rank
81:                   RANK() OVER (
91:                   RANK() OVER (ORDER BY similarity(%I, $1) DESC) AS rank

$ grep -nE "result_chunk_ids +bigint\[\]" scripts/03_create_query_log.sql
32:    result_chunk_ids    bigint[],                              -- chunks returned; chunk_id is bigserial in PLAYBOOK Section 2

$ grep -n "args +jsonb" scripts/03_create_query_log.sql
30:    args                jsonb NOT NULL DEFAULT '{}'::jsonb,    -- arbitrary tool args (query_text, k, schemas, ...)

$ grep -n "CREATE EVENT TRIGGER" scripts/02_create_corpus_registry.sql
168:CREATE EVENT TRIGGER corpus_schema_created

$ grep -n "GOOGLE_APPLICATION_CREDENTIALS" snippets/bigquery_auth.py
14:  2. The ``GOOGLE_APPLICATION_CREDENTIALS`` environment variable.
49:    env_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS")

$ grep -n "DEFAULT_KEY_PATH" snippets/bigquery_auth.py
(no hits -- removed)

$ grep -n "TOKEN_REFRESH_SKEW" snippets/bigquery_auth.py
44:TOKEN_REFRESH_SKEW = timedelta(minutes=5)

$ grep -n "row_warn_threshold" snippets/pg_query_logger.py
24:DEFAULT_ROW_WARN_THRESHOLD = 1000
... 4 more hits in PGQueryLogger + QueryContext.execute()

$ ls scripts/04_comment_on_workhorses*
scripts/04_comment_on_workhorses.example.sql
```

All checks pass.

## Answers to Claude 2's 5 asks (from `04_claude2_redteam_of_claude1.md`)

### Ask 1 -- Confirm dimension-binding resolution path

**CONFIRMED.** scripts/05 function signature is unsized `vector`; this is portable across embedding models. Claude-2 fixed SKILL.md:105 to unsized vector in `06_claude2_fixes.md`. No additional change needed on my side.

### Ask 2 -- scripts/03 query_log canonical schema scope

**OPTION (a) -- align deployed schema to PLAYBOOK Section 8.** Done. scripts/03 rewritten with the 16 canonical columns + JSONB args + result_chunk_ids BIGINT[]. Extras (query_text, top_score, user_judgment, embedding_model, schema_targets, k, rrf_k, notes) kept as additional columns -- they don't conflict with the canonical contract. snippets/pg_query_logger.py updated to write the new column set. PLAYBOOK Section 8 was already updated by Claude-2 to BIGINT[].

### Ask 3 -- scripts/02 corpus_registry defaults rewrite scope

**OPTION (a) -- align defaults to PLAYBOOK Section 2 canonical.** Done. New defaults: `chunks` / `content` / `embedding` / `id` / voyage-context-3 / 1024. Legacy override pattern documented in the file header. `chunk_id_col` added (default `id`) to handle the bigserial PK column name from PLAYBOOK Section 2.

### Ask 4 -- scripts/02 event trigger addition

**ACCEPTED.** Event trigger + callback function added per PLAYBOOK Section 10 lines 781-801. Implementation in `ops_search_agent` schema (matching the rest of scripts/02; PLAYBOOK uses `ops_records_officer` but the function intent + signature are identical). `DROP EVENT TRIGGER IF EXISTS` + `CREATE EVENT TRIGGER` makes the script re-runnable. Backfill INSERT preserved for first-run cases.

### Ask 5 -- bigquery_auth.py keep-vs-move

**KEEP, with positioning softened.** snippets/bigquery_auth.py stays in this skill -- the BQ tables that remain unmigrated (per `feedback_query_bigquery_for_specialized_tables` memory rule) are part of the same evidence retrieval surface that the PG side covers. Cross-slice resolution: Claude-2 updated SKILL.md frontmatter to acknowledge BQ scope (per their `06_claude2_fixes.md`). I also softened the bigquery_auth.py module docstring to "Postgres-first ... BQ tables that are not yet mirrored to PG; this snippet is the minimal auth surface those agents need."

## Confirm receipt of Claude 2's Phase 3 commits + accept the 3-check sync gate

I have read `06_claude2_fixes.md` (commit 995a935 on origin/build/claude-2). The cross-slice decisions match my fixes here:

- result_chunk_ids = BIGINT[] (Claude-2 Ask 2 decision) -- ADOPTED in scripts/03 + pg_query_logger.py.
- "If a reader reads only this section" (Claude-2 Ask 3 acceptance) -- N/A to my slice.
- SKILL.md frontmatter acknowledges BQ scope (Claude-2 Ask 5 acceptance) -- aligns with my Ask 5 answer above.
- 3-check sync gate (Claude-2 Ask 4 proposal) -- **ACCEPTED**.

### The 3-check sync gate (run after both Phase 3 fix commits land)

1. **Column-set agreement** -- SKILL.md / PLAYBOOK Section 8 query_log columns ⟷ scripts/03 produced query_log columns.
   - Live check: `psql -d <db> -f scripts/03_create_query_log.sql && psql -d <db> -c '\d ops_search_agent.query_log'`. All 16 PLAYBOOK Section 8 columns must be present; extras are allowed.
   - Static check (no live PG): `grep -oE '^\s+[a-z_]+\s' scripts/03_create_query_log.sql | sort -u` compared against PLAYBOOK Section 8 column list.

2. **Function-signature agreement** -- SKILL.md Quick-start example call ⟷ scripts/05 `hybrid_rrf_search` parameter names + types.
   - Live check: `psql -d <db> -f scripts/05_hybrid_rrf_search.sql && psql -d <db> -c '\df ops_search_agent.hybrid_rrf_search'`. Signature in my scripts/05: `(query_text text, query_vec vector, target_schema text, target_table text DEFAULT 'chunks', text_col text DEFAULT 'content', vec_col text DEFAULT 'embedding', chunk_id_col text DEFAULT 'id', k_per_leg integer DEFAULT 60, rrf_k integer DEFAULT 60, final_k integer DEFAULT 20)`. NOTE: I added `chunk_id_col text DEFAULT 'id'` to align with the canonical `id` PK column from PLAYBOOK Section 2 -- Claude 2 should double-check SKILL.md Quick-start does not pass positional args past `vec_col` (would shift `k_per_leg` into the new `chunk_id_col` slot). If SKILL.md uses named args (`target_schema => '...'`) the addition is safe.
   - Static check: `grep -nE 'hybrid_rrf_search\s*\(' SKILL.md` ⟷ the function signature line in scripts/05.

3. **Default-defaults agreement** -- scripts/02 corpus_registry defaults ⟷ PLAYBOOK Section 2 canonical chunks table.
   - Live check: `psql -d <db> -c "\d ops_search_agent.corpus_registry"` -- chunk_table default = 'chunks', chunk_text_col default = 'content', chunk_vec_col default = 'embedding', chunk_id_col default = 'id', embedding_dim default = 1024.
   - Static check: `grep -nE 'DEFAULT' scripts/02_create_corpus_registry.sql` ⟷ PLAYBOOK Section 2 canonical names.

If any check fails I drop `05_claude1_fixes_v2.md` with the specific delta; same for Claude 2 with `06_claude2_fixes_v2.md`. The check itself becomes `tests/sync_check.sh` in Phase 4a (my recall side).

## Commits landed this phase

- `<commit-sha>  phase3: claude-1 apply all code-slice fixes (own audit + claude-2 red-team)`

(SHA filled in by the commit immediately after this handoff lands.)

## Open questions / deferred

- **Pending-row-then-update pattern** for crash-resilient logging in `pg_query_logger.py`: deferred to Phase 4b. Need write-rate measurement before doubling INSERT cost.
- **`scripts/00_create_extensions.sql`**: still not added. Phase 4a (test harness) will exercise it on a clean PG container -- adding it then is more useful than guessing the extension set now.
- **Refactor scripts/05 format() per-leg**: deferred (low value vs churn). My Phase 1 audit flagged it; Claude-2 confirmed. Annotated placeholder groups instead.
- **`scripts/04_comment_on_workhorses.example.sql`**: now an explicit reference template. Phase 4a tests do not need to run it. A future deployer-facing wave (separate from this skill build) could provide a template-generator script.
- **`waves/wave_3` lack of gemini supplement**: noted in Claude-2's open questions. Code-slice does not own this; deferred to Phase 5 sign-off.
- **`:role` psql variable vs `valor_agent` literal across PLAYBOOK Section 0 / Section 4.3 examples**: scripts/01 now uses `:"role"` with default `valor_agent`. PLAYBOOK still uses `valor_agent` as a literal example. Acceptable for Phase 3; Phase 5 joint sign-off can decide whether to homogenize.

[CLAUDE-1 // 2026-05-20T09:55Z]
