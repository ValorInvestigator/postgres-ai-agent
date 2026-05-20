-- 03_create_query_log.sql
-- Per PLAYBOOK Section 0 Move 4 + Section 8 (canonical schema)
-- Confidence grade: C (synthesis pattern; SQL is canonical)
--
-- Logs every agent query for drift / hallucination / cost detection.
-- Insert from any Python wrapper (see snippets/pg_query_logger.py).
-- Use for: nightly recall audits, cost reports, debugging slow queries.
--
-- COLUMN SET
--   Canonical (PLAYBOOK Section 8):
--     id, ts, session_id, agent_id, tool_name, args (JSONB),
--     result_count, result_chunk_ids (BIGINT[]),
--     latency_ms, cache_hit, rerank_used, rerank_model,
--     confidence, downstream_use, privilege_flag, error
--   Useful extras kept from earlier iterations:
--     query_text, query_text_hash, embedding_model, schema_targets,
--     k, rrf_k, top_score, user_judgment, user_judgment_at,
--     user_judgment_by, notes

CREATE SCHEMA IF NOT EXISTS ops_search_agent;

CREATE TABLE IF NOT EXISTS ops_search_agent.query_log (
    -- ===== Canonical PLAYBOOK Section 8 columns =====
    id                  bigserial PRIMARY KEY,
    ts                  timestamptz NOT NULL DEFAULT now(),
    session_id          text NOT NULL,
    agent_id            text NOT NULL,                         -- 'claude_code' | 'codex' | 'firm.records_officer'
    tool_name           text NOT NULL,                         -- 'semantic_search' | 'keyword_search' | 'hybrid_rrf_search' | 'rerank' | 'sql'
    args                jsonb NOT NULL DEFAULT '{}'::jsonb,    -- arbitrary tool args (query_text, k, schemas, ...)
    result_count        integer,                               -- canonical name (Section 8)
    result_chunk_ids    bigint[],                              -- chunks returned; chunk_id is bigserial in PLAYBOOK Section 2
    latency_ms          integer,                               -- end-to-end wall clock
    cache_hit           boolean NOT NULL DEFAULT false,
    rerank_used         boolean NOT NULL DEFAULT false,
    rerank_model        text,                                  -- which reranker (BAAI/bge-reranker-v2-m3, ...)
    confidence          double precision,                      -- CRAG-style retrieval evaluator score
    downstream_use      text,                                  -- 'cited_in_filing' | 'discarded' | 'rewritten' | NULL
    privilege_flag      boolean NOT NULL DEFAULT false,        -- privileged material in result set; sweep before disclosure
    error               text,                                  -- non-null if the query failed

    -- ===== Useful extras (kept; not in PLAYBOOK Section 8 canonical) =====
    query_text          text,                                  -- the SQL or natural-language query (mirrored from args for fast filtering)
    query_text_hash     text GENERATED ALWAYS AS (md5(COALESCE(query_text, ''))) STORED,
    embedding_model     text,                                  -- which embedding model was used for the query
    schema_targets      text[],                                -- which schemas the query targeted
    k                   integer,                               -- top-k requested
    rrf_k               integer,                               -- RRF k parameter
    top_score           double precision,                      -- best similarity / RRF score returned
    user_judgment       text,                                  -- 'good' | 'bad' | 'partial' | null
    user_judgment_at    timestamptz,
    user_judgment_by    text,
    notes               text
);

COMMENT ON TABLE ops_search_agent.query_log IS
  'One row per agent retrieval query. Drives recall audits, cost reports, and drift detection. Canonical schema per PLAYBOOK Section 8; extras (query_text, top_score, user_judgment_*) supplement the canonical set without breaking the contract.';

COMMENT ON COLUMN ops_search_agent.query_log.tool_name IS
  'Name of the tool that produced this row. Matches MCP tool names: semantic_search, keyword_search, hybrid_rrf_search, rerank, sql.';

COMMENT ON COLUMN ops_search_agent.query_log.args IS
  'JSONB blob of all tool arguments (query_text, k, schemas, filters, etc). GIN-indexed so you can filter on any arg with @> or jsonb_path_ops queries.';

COMMENT ON COLUMN ops_search_agent.query_log.result_chunk_ids IS
  'BIGINT[] of returned chunk IDs. Use array_overlap / @> to find recall regressions or to materialize "which chunk did the agent see in session X".';

COMMENT ON COLUMN ops_search_agent.query_log.confidence IS
  'CRAG-style retrieval-evaluator score 0..1. Drives self-correction loops: low confidence -> rewrite query.';

COMMENT ON COLUMN ops_search_agent.query_log.downstream_use IS
  'How the chunks were used downstream. Enum: cited_in_filing | discarded | rewritten. NULL = not yet judged.';

COMMENT ON COLUMN ops_search_agent.query_log.privilege_flag IS
  'true if any chunk in result_chunk_ids contains attorney-client privileged material. Records officer sweeps before disclosure.';

COMMENT ON COLUMN ops_search_agent.query_log.query_text_hash IS
  'MD5 of COALESCE(query_text, '''') for fast duplicate-query detection. COALESCE ensures NULL query_text yields md5('''') = ''d41d8cd98f00b204e9800998ecf8427e'' instead of NULL (which is unsearchable on a btree).';

COMMENT ON COLUMN ops_search_agent.query_log.user_judgment IS
  'Agent or human verdict on result quality. Backfill from feedback loops; query for recall regressions. Complements canonical downstream_use.';

-- ============================================================================
-- Indexes (canonical PLAYBOOK Section 8 + extras for the kept columns)
-- ============================================================================
CREATE INDEX IF NOT EXISTS query_log_session_idx     ON ops_search_agent.query_log (session_id, ts);
CREATE INDEX IF NOT EXISTS query_log_agent_idx       ON ops_search_agent.query_log (agent_id, ts);
CREATE INDEX IF NOT EXISTS query_log_tool_idx        ON ops_search_agent.query_log (tool_name, ts);
CREATE INDEX IF NOT EXISTS query_log_args_gin        ON ops_search_agent.query_log USING gin (args);
CREATE INDEX IF NOT EXISTS query_log_ts_desc_idx     ON ops_search_agent.query_log (ts DESC);
CREATE INDEX IF NOT EXISTS query_log_text_hash_idx   ON ops_search_agent.query_log (query_text_hash);
CREATE INDEX IF NOT EXISTS query_log_user_judgment_idx
    ON ops_search_agent.query_log (user_judgment)
    WHERE user_judgment IS NOT NULL;
CREATE INDEX IF NOT EXISTS query_log_downstream_use_idx
    ON ops_search_agent.query_log (downstream_use)
    WHERE downstream_use IS NOT NULL;
CREATE INDEX IF NOT EXISTS query_log_privilege_flag_idx
    ON ops_search_agent.query_log (privilege_flag)
    WHERE privilege_flag = true;

-- ============================================================================
-- Convenience views (PLAYBOOK Section 8 + observability extras)
-- ============================================================================

-- Per-session quality summary (PLAYBOOK Section 8 canonical view)
CREATE OR REPLACE VIEW ops_search_agent.session_quality AS
SELECT
    session_id,
    agent_id,
    COUNT(*) AS n_queries,
    AVG(confidence) AS avg_confidence,
    SUM((downstream_use = 'discarded')::int)::float / NULLIF(COUNT(*), 0) AS discard_rate,
    AVG(latency_ms) AS avg_latency_ms,
    SUM(rerank_used::int) AS n_rerank,
    SUM(cache_hit::int) AS n_cache_hit
FROM ops_search_agent.query_log
GROUP BY session_id, agent_id;

COMMENT ON VIEW ops_search_agent.session_quality IS
  'Per-session quality summary (PLAYBOOK Section 8). CRAG-style self-correction loops converge faster with the numeric feedback signal (avg_confidence, discard_rate).';

-- 24-hour rolling window
CREATE OR REPLACE VIEW ops_search_agent.v_query_log_24h AS
SELECT * FROM ops_search_agent.query_log
WHERE ts > now() - interval '24 hours'
ORDER BY ts DESC;

COMMENT ON VIEW ops_search_agent.v_query_log_24h IS
  '24-hour rolling window of agent queries. Use for daily drift checks.';

-- Failed / bad-judgment queries
CREATE OR REPLACE VIEW ops_search_agent.v_query_log_failed AS
SELECT * FROM ops_search_agent.query_log
WHERE error IS NOT NULL OR user_judgment = 'bad' OR downstream_use = 'discarded'
ORDER BY ts DESC;

COMMENT ON VIEW ops_search_agent.v_query_log_failed IS
  'Queries that errored, were judged bad, or discarded downstream. Triage source for recall regressions.';

-- Costly queries (latency or row-count outliers)
CREATE OR REPLACE VIEW ops_search_agent.v_query_log_costly AS
SELECT * FROM ops_search_agent.query_log
WHERE latency_ms > 5000 OR result_count > 10000
ORDER BY latency_ms DESC NULLS LAST, ts DESC;

COMMENT ON VIEW ops_search_agent.v_query_log_costly IS
  'Queries over 5s latency or returning over 10K rows. Optimize these first.';

-- Privileged-result audit trail
CREATE OR REPLACE VIEW ops_search_agent.v_query_log_privileged AS
SELECT id, ts, session_id, agent_id, tool_name, result_count, result_chunk_ids, downstream_use
FROM ops_search_agent.query_log
WHERE privilege_flag = true
ORDER BY ts DESC;

COMMENT ON VIEW ops_search_agent.v_query_log_privileged IS
  'All queries whose result set contains privileged material. Records officer reviews before any disclosure.';

-- ============================================================================
-- Verify
-- ============================================================================
SELECT 'query_log table created' AS status, COUNT(*) AS row_count
FROM ops_search_agent.query_log;
