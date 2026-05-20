-- 05_hybrid_rrf_search.sql
-- Per PLAYBOOK Section 0 Move 2 + Section 5.1
-- Confidence grade: A (RRF is well-established; this function packages it for pgvector)
--
-- Reciprocal Rank Fusion (RRF) across three retrieval legs:
--   * vector similarity (cosine via pgvector HNSW)
--   * tsvector full-text search
--   * pg_trgm fuzzy substring search
--
-- Calling pattern (Python embeds the query first):
--   SELECT * FROM ops_search_agent.hybrid_rrf_search(
--     'Carol Frederick attorney probate',
--     ARRAY[0.1, 0.2, ...]::vector,    -- unsized: portable across embedding dims
--     'case_26cv11493_hearing_prep',
--     'chunks',
--     'content',
--     'embedding',
--     60, 60, 60
--   ) LIMIT 20;
--
-- For multi-schema search, call once per schema and merge in application code,
-- OR query ops_search_agent.v_evidence_search and apply RRF in application code.
--
-- INDEX PREREQUISITES (caller is responsible for these on the target table):
--   * HNSW on <vec_col> with the matching ops class (vector_cosine_ops or
--     halfvec_cosine_ops). Without HNSW the vector leg falls to sequential scan.
--   * GIN tsvector index. Either:
--       (a) a generated column: ALTER TABLE ... ADD COLUMN content_tsv tsvector
--           GENERATED ALWAYS AS (to_tsvector('english', <text_col>)) STORED;
--           CREATE INDEX ... USING gin (content_tsv);
--       (b) an expression index: CREATE INDEX ... USING gin
--           (to_tsvector('english', <text_col>));
--       Without one, the fts_leg falls to sequential scan on 100K+ row corpora.
--   * pg_trgm GIN/GIST: CREATE INDEX ... USING gin (<text_col> gin_trgm_ops);
--     Without it, the trgm_leg falls to sequential scan + the % operator is slow.
--
-- See PLAYBOOK Section 2 for the canonical chunks table that ships all three.

CREATE OR REPLACE FUNCTION ops_search_agent.hybrid_rrf_search(
    query_text       text,
    query_vec        vector,
    target_schema    text,
    target_table     text DEFAULT 'chunks',
    text_col         text DEFAULT 'content',
    vec_col          text DEFAULT 'embedding',
    chunk_id_col     text DEFAULT 'id',
    k_per_leg        integer DEFAULT 60,
    rrf_k            integer DEFAULT 60,
    final_k          integer DEFAULT 20
)
RETURNS TABLE (
    chunk_id     bigint,
    rrf_score    double precision,
    text_preview text,
    vector_rank  integer,
    fts_rank     integer,
    trgm_rank    integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Dynamic SQL parameter map (passed via EXECUTE ... USING):
    --   $1 -> query_text   (text, FTS + trgm match)
    --   $2 -> query_vec    (vector, vector leg distance)
    --   $3 -> k_per_leg    (integer, LIMIT for each leg)
    --   $4 -> rrf_k        (integer, RRF denominator constant)
    --   $5 -> final_k      (integer, final LIMIT after fusion)
    sql_text text;
BEGIN
    -- CTE legs are MATERIALIZED so the planner cannot inline them; without this,
    -- Postgres 12+ may fold the iterative-scan vector leg, defeating recall.
    -- RANK() is used (not ROW_NUMBER) so tied scores share rank, matching the
    -- canonical RRF formula in PLAYBOOK Section 5.1.
    sql_text := format($q$
        WITH
        -- Leg 1: vector cosine similarity (HNSW)
        vector_leg AS MATERIALIZED (
            SELECT %I AS chunk_id,
                   RANK() OVER (ORDER BY %I <=> $2) AS rank
            FROM %I.%I
            ORDER BY %I <=> $2
            LIMIT $3
        ),
        -- Leg 2: tsvector FTS (requires GIN index on to_tsvector('english', <text_col>))
        fts_leg AS MATERIALIZED (
            SELECT %I AS chunk_id,
                   RANK() OVER (
                     ORDER BY ts_rank_cd(to_tsvector('english', %I), plainto_tsquery('english', $1)) DESC
                   ) AS rank
            FROM %I.%I
            WHERE to_tsvector('english', %I) @@ plainto_tsquery('english', $1)
            LIMIT $3
        ),
        -- Leg 3: pg_trgm fuzzy substring (requires GIN/GIST trgm index on <text_col>)
        trgm_leg AS MATERIALIZED (
            SELECT %I AS chunk_id,
                   RANK() OVER (ORDER BY similarity(%I, $1) DESC) AS rank
            FROM %I.%I
            WHERE %I %% $1
            ORDER BY similarity(%I, $1) DESC
            LIMIT $3
        ),
        -- UNION dedupes candidate chunk_ids across legs (a chunk may rank in more than one).
        candidates AS (
            SELECT chunk_id FROM vector_leg
            UNION
            SELECT chunk_id FROM fts_leg
            UNION
            SELECT chunk_id FROM trgm_leg
        ),
        -- Compute RRF score. COALESCE handles the leg-misses (chunk did not appear in a leg).
        -- Cast the numerator to double precision so the score type matches the
        -- function declaration (otherwise PG infers numeric from the 1.0 literal).
        scored AS (
            SELECT
                c.chunk_id,
                COALESCE(1.0::double precision / ($4 + v.rank), 0) +
                COALESCE(1.0::double precision / ($4 + f.rank), 0) +
                COALESCE(1.0::double precision / ($4 + t.rank), 0) AS rrf_score,
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
        JOIN %I.%I tc ON tc.%I = s.chunk_id
        ORDER BY s.rrf_score DESC
        LIMIT $5
    $q$,
    -- vector_leg placeholders
    chunk_id_col, vec_col, target_schema, target_table, vec_col,
    -- fts_leg placeholders
    chunk_id_col, text_col, target_schema, target_table, text_col,
    -- trgm_leg placeholders
    chunk_id_col, text_col, target_schema, target_table, text_col, text_col,
    -- final SELECT placeholders
    text_col, target_schema, target_table, chunk_id_col
    );

    RETURN QUERY EXECUTE sql_text USING query_text, query_vec, k_per_leg, rrf_k, final_k;
END;
$$;

COMMENT ON FUNCTION ops_search_agent.hybrid_rrf_search IS
  'Three-leg RRF hybrid search (vector + tsvector + pg_trgm). PLAYBOOK Section 5.1 canonical implementation: MATERIALIZED CTE legs + RANK() over rank ties. Anthropic-measured ~49% retrieval-failure drop vs single-leg vector (see references/waves/wave_4_agent_retrieval.md). Embed the query externally before calling. Caller is responsible for HNSW + GIN tsvector + pg_trgm indexes on the target table -- see file header.';

-- Verify the function exists
SELECT
    n.nspname || '.' || p.proname AS function_name,
    pg_get_function_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname = 'hybrid_rrf_search'
  AND n.nspname = 'ops_search_agent';
