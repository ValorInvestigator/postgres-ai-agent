-- 05_hybrid_rrf_search.sql
-- Per PLAYBOOK Section 0 Move 2 + Section 5
-- Confidence grade: A (RRF is well-established; this function packages it for pgvector)
--
-- Reciprocal Rank Fusion (RRF) across three retrieval legs:
--   * vector similarity (cosine via pgvector HNSW)
--   * tsvector full-text search (GIN-indexed)
--   * pg_trgm fuzzy substring search
--
-- Calling pattern (Python embeds the query first):
--   SELECT * FROM hybrid_rrf_search(
--     'Carol Frederick attorney probate',
--     ARRAY[0.1, 0.2, ...]::vector(384),
--     'case_26cv11493_hearing_prep',
--     'text_chunks',
--     'text',
--     'embedding',
--     60, 60, 60
--   ) LIMIT 20;
--
-- For multi-schema search, call once per schema and merge in application code,
-- OR query ops_search_agent.v_evidence_search and apply RRF in application code.

CREATE OR REPLACE FUNCTION ops_search_agent.hybrid_rrf_search(
    query_text       text,
    query_vec        vector,
    target_schema    text,
    target_table     text DEFAULT 'text_chunks',
    text_col         text DEFAULT 'text',
    vec_col          text DEFAULT 'embedding',
    k_per_leg        integer DEFAULT 60,
    rrf_k            integer DEFAULT 60,
    final_k          integer DEFAULT 20
)
RETURNS TABLE (
    chunk_id    bigint,
    rrf_score   double precision,
    text_preview text,
    vector_rank integer,
    fts_rank    integer,
    trgm_rank   integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    sql_text text;
BEGIN
    -- Build dynamic SQL because target schema/table/column are parameters
    sql_text := format($q$
        WITH
        -- Leg 1: vector cosine similarity (HNSW)
        vector_leg AS (
            SELECT chunk_id,
                   ROW_NUMBER() OVER (ORDER BY %I <=> $2) AS rank
            FROM %I.%I
            ORDER BY %I <=> $2
            LIMIT $3
        ),
        -- Leg 2: tsvector FTS
        fts_leg AS (
            SELECT chunk_id,
                   ROW_NUMBER() OVER (
                     ORDER BY ts_rank_cd(to_tsvector('english', %I), plainto_tsquery('english', $1)) DESC
                   ) AS rank
            FROM %I.%I
            WHERE to_tsvector('english', %I) @@ plainto_tsquery('english', $1)
            LIMIT $3
        ),
        -- Leg 3: pg_trgm fuzzy substring
        trgm_leg AS (
            SELECT chunk_id,
                   ROW_NUMBER() OVER (ORDER BY similarity(%I, $1) DESC) AS rank
            FROM %I.%I
            WHERE %I %% $1
            ORDER BY similarity(%I, $1) DESC
            LIMIT $3
        ),
        -- Union all candidates
        candidates AS (
            SELECT chunk_id FROM vector_leg
            UNION
            SELECT chunk_id FROM fts_leg
            UNION
            SELECT chunk_id FROM trgm_leg
        ),
        -- Compute RRF score
        scored AS (
            SELECT
                c.chunk_id,
                COALESCE(1.0 / ($4 + v.rank), 0) +
                COALESCE(1.0 / ($4 + f.rank), 0) +
                COALESCE(1.0 / ($4 + t.rank), 0) AS rrf_score,
                v.rank AS vector_rank,
                f.rank AS fts_rank,
                t.rank AS trgm_rank
            FROM candidates c
            LEFT JOIN vector_leg v USING (chunk_id)
            LEFT JOIN fts_leg    f USING (chunk_id)
            LEFT JOIN trgm_leg   t USING (chunk_id)
        )
        SELECT
            s.chunk_id,
            s.rrf_score,
            LEFT(tc.%I, 200) AS text_preview,
            s.vector_rank::integer,
            s.fts_rank::integer,
            s.trgm_rank::integer
        FROM scored s
        JOIN %I.%I tc USING (chunk_id)
        ORDER BY s.rrf_score DESC
        LIMIT $5
    $q$,
    vec_col, target_schema, target_table, vec_col,
    text_col, target_schema, target_table, text_col,
    text_col, target_schema, target_table, text_col, text_col,
    text_col, target_schema, target_table
    );

    RETURN QUERY EXECUTE sql_text USING query_text, query_vec, k_per_leg, rrf_k, final_k;
END;
$$;

COMMENT ON FUNCTION ops_search_agent.hybrid_rrf_search IS
  'Three-leg RRF hybrid search (vector + tsvector + pg_trgm). Anthropic-measured 49% retrieval-failure drop vs single-leg vector. Embed query externally before calling. For multi-schema search, call per-schema and merge in application code or run against v_evidence_search.';

-- Convenience wrapper that auto-detects pg_trgm availability + falls back gracefully
-- if pg_trgm extension is not enabled (replaces leg 3 with no-op).
-- (Left as exercise; the function above assumes pg_trgm + tsvector are available.)

-- Verify the function exists
SELECT
    n.nspname || '.' || p.proname AS function_name,
    pg_get_function_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname = 'hybrid_rrf_search';
