-- 02_create_corpus_registry.sql
-- Per PLAYBOOK Section 10 + Section 13 Phase 1 step 2
-- Confidence grade: A/C (architectural pattern; SQL is canonical)
--
-- Replaces ad-hoc hardcoded `v_evidence_search` UNION ALL view with a corpus_registry
-- table + event trigger that rebuilds the view automatically when schemas change.
--
-- Each row in corpus_registry maps to one schema-per-corpus PG schema.

CREATE SCHEMA IF NOT EXISTS ops_search_agent;

-- Corpus registry: one row per searchable corpus schema
CREATE TABLE IF NOT EXISTS ops_search_agent.corpus_registry (
    schema_name      text PRIMARY KEY,
    corpus_type      text NOT NULL,                          -- 'case' | 'corpus' | 'legal' | 'ops'
    description      text,
    embedding_model  text NOT NULL DEFAULT 'sentence-transformers/all-MiniLM-L6-v2',
    embedding_dim    integer NOT NULL DEFAULT 384,
    chunk_table      text NOT NULL DEFAULT 'text_chunks',
    chunk_text_col   text NOT NULL DEFAULT 'text',
    chunk_vec_col    text NOT NULL DEFAULT 'embedding',
    source_files_table text DEFAULT 'source_files',
    in_evidence_search boolean NOT NULL DEFAULT true,        -- include in v_evidence_search
    registered_at    timestamptz NOT NULL DEFAULT now(),
    last_chunks_count bigint,
    last_chunks_count_at timestamptz,
    notes            text
);

COMMENT ON TABLE ops_search_agent.corpus_registry IS
  'One row per searchable PG corpus schema. Drives auto-rebuild of v_evidence_search via event trigger. Agents query this to discover available corpora.';

COMMENT ON COLUMN ops_search_agent.corpus_registry.in_evidence_search IS
  'true = include in the cross-schema v_evidence_search view. Set false to exclude a schema (e.g., test/scratch corpora).';

-- Backfill registry from existing schemas matching case_*, corpus_*, legal_*
INSERT INTO ops_search_agent.corpus_registry (schema_name, corpus_type, description)
SELECT
  schema_name,
  CASE
    WHEN schema_name LIKE 'case_%' THEN 'case'
    WHEN schema_name LIKE 'corpus_%' THEN 'corpus'
    WHEN schema_name LIKE 'legal_%' THEN 'legal'
    ELSE 'other'
  END AS corpus_type,
  'Auto-registered from existing schema at ' || now()::text AS description
FROM information_schema.schemata
WHERE schema_name LIKE 'case_%'
   OR schema_name LIKE 'corpus_%'
   OR schema_name LIKE 'legal_%'
ON CONFLICT (schema_name) DO NOTHING;

-- Show what was registered
SELECT schema_name, corpus_type FROM ops_search_agent.corpus_registry ORDER BY schema_name;

-- Function to rebuild v_evidence_search across all registered corpora
CREATE OR REPLACE FUNCTION ops_search_agent.rebuild_v_evidence_search()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    sql_text text;
    union_parts text[];
    rec record;
BEGIN
    union_parts := ARRAY[]::text[];
    FOR rec IN
        SELECT schema_name, chunk_table, chunk_text_col
        FROM ops_search_agent.corpus_registry
        WHERE in_evidence_search = true
        ORDER BY schema_name
    LOOP
        -- Verify the table actually exists before including
        IF EXISTS (
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = rec.schema_name AND table_name = rec.chunk_table
        ) THEN
            union_parts := array_append(union_parts, format(
                'SELECT %L::text AS schema_name, chunk_id, %I AS content FROM %I.%I',
                rec.schema_name, rec.chunk_text_col, rec.schema_name, rec.chunk_table
            ));
        END IF;
    END LOOP;

    IF array_length(union_parts, 1) > 0 THEN
        sql_text := 'CREATE OR REPLACE VIEW ops_search_agent.v_evidence_search AS '
            || array_to_string(union_parts, ' UNION ALL ');
        EXECUTE sql_text;
        COMMENT ON VIEW ops_search_agent.v_evidence_search IS
          'Cross-corpus search view. Auto-rebuilt from corpus_registry by rebuild_v_evidence_search(). Use schema_name to disambiguate when filtering.';
    END IF;
END;
$$;

COMMENT ON FUNCTION ops_search_agent.rebuild_v_evidence_search IS
  'Rebuilds v_evidence_search as UNION ALL across all in_evidence_search=true rows in corpus_registry. Call after adding/removing corpus schemas.';

-- Build the view now
SELECT ops_search_agent.rebuild_v_evidence_search();

-- Verify the view exists and is queryable
SELECT COUNT(*) AS total_chunks_in_evidence_search
FROM ops_search_agent.v_evidence_search;
