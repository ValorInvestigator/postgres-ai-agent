-- 03_create_query_log.sql
-- Per PLAYBOOK Section 0 Move 4 + Section 8
-- Confidence grade: C (synthesis pattern; SQL is canonical)
--
-- Logs every agent query for drift / hallucination / cost detection.
-- Insert from any Python wrapper (see snippets/pg_query_logger.py).
-- Use for: nightly recall audits, cost reports, debugging slow queries.

CREATE SCHEMA IF NOT EXISTS ops_search_agent;

CREATE TABLE IF NOT EXISTS ops_search_agent.query_log (
    query_id          bigserial PRIMARY KEY,
    submitted_at      timestamptz NOT NULL DEFAULT now(),
    agent_name        text,                                  -- 'claude-code', 'codex', 'firm-records-officer', etc.
    session_id        text,                                  -- correlates queries from one session
    query_kind        text NOT NULL,                         -- 'vector' | 'fts' | 'trgm' | 'hybrid_rrf' | 'rerank' | 'sql'
    query_text        text,                                  -- the SQL or natural-language query
    query_text_hash   text GENERATED ALWAYS AS (md5(query_text)) STORED,
    embedding_model   text,                                  -- which model the query was embedded with
    schema_targets    text[],                                -- which schemas the query targeted
    k                 integer,                               -- top-k requested
    rrf_k             integer,                               -- RRF k parameter
    rerank_used       boolean,
    rerank_model      text,                                  -- which reranker
    latency_ms        integer,                               -- end-to-end wall clock
    rows_returned     integer,
    top_score         double precision,                      -- best similarity score returned
    user_judgment     text,                                  -- 'good' | 'bad' | 'partial' | null
    user_judgment_at  timestamptz,
    user_judgment_by  text,
    notes             text,
    error             text                                   -- non-null if the query failed
);

COMMENT ON TABLE ops_search_agent.query_log IS
  'One row per agent retrieval query. Drives recall audits, cost reports, and drift detection. Insert from any Python wrapper or MCP tool.';

COMMENT ON COLUMN ops_search_agent.query_log.query_text_hash IS
  'MD5 of query_text for fast duplicate-query detection. Use to find recurring queries.';

COMMENT ON COLUMN ops_search_agent.query_log.user_judgment IS
  'Agent or human verdict on result quality. Backfill from feedback loops; query for recall regressions.';

-- Indexes for the common query patterns
CREATE INDEX IF NOT EXISTS query_log_submitted_at_idx ON ops_search_agent.query_log (submitted_at DESC);
CREATE INDEX IF NOT EXISTS query_log_agent_session_idx ON ops_search_agent.query_log (agent_name, session_id);
CREATE INDEX IF NOT EXISTS query_log_query_kind_idx ON ops_search_agent.query_log (query_kind, submitted_at DESC);
CREATE INDEX IF NOT EXISTS query_log_text_hash_idx ON ops_search_agent.query_log (query_text_hash);
CREATE INDEX IF NOT EXISTS query_log_user_judgment_idx ON ops_search_agent.query_log (user_judgment) WHERE user_judgment IS NOT NULL;

-- Convenience views for common audits
CREATE OR REPLACE VIEW ops_search_agent.v_query_log_24h AS
SELECT * FROM ops_search_agent.query_log
WHERE submitted_at > now() - interval '24 hours'
ORDER BY submitted_at DESC;

COMMENT ON VIEW ops_search_agent.v_query_log_24h IS
  '24-hour rolling window of agent queries. Use for daily drift checks.';

CREATE OR REPLACE VIEW ops_search_agent.v_query_log_failed AS
SELECT * FROM ops_search_agent.query_log
WHERE error IS NOT NULL OR user_judgment = 'bad'
ORDER BY submitted_at DESC;

COMMENT ON VIEW ops_search_agent.v_query_log_failed IS
  'Queries that errored or were judged bad. Triage source for recall regressions.';

CREATE OR REPLACE VIEW ops_search_agent.v_query_log_costly AS
SELECT * FROM ops_search_agent.query_log
WHERE latency_ms > 5000 OR rows_returned > 10000
ORDER BY latency_ms DESC NULLS LAST, submitted_at DESC;

COMMENT ON VIEW ops_search_agent.v_query_log_costly IS
  'Queries over 5s latency or returning over 10K rows. Optimize these first.';

-- Verify
SELECT 'query_log table created' AS status, COUNT(*) AS row_count
FROM ops_search_agent.query_log;
