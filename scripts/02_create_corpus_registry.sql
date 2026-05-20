-- 02_create_corpus_registry.sql
-- Per PLAYBOOK Section 10 + Section 13 Phase 1 step 2
-- Confidence grade: A/C (architectural pattern; SQL is canonical)
--
-- Replaces ad-hoc hardcoded `v_evidence_search` UNION ALL view with a corpus_registry
-- table + event trigger that rebuilds the view automatically when schemas change.
--
-- Each row in corpus_registry maps to one schema-per-corpus PG schema.
--
-- CANONICAL DEFAULTS (PLAYBOOK Section 2)
--   chunk_table     = 'chunks'        (NOT 'text_chunks')
--   chunk_text_col  = 'content'       (NOT 'text')
--   chunk_vec_col   = 'embedding'
--   embedding_dim   = 1024            (halfvec; voyage-context-3 or Qwen3-Embedding-8B)
--   embedding_model = 'voyageai/voyage-context-3'
--
-- LEGACY OVERRIDE for older 384-dim text_chunks corpora:
--   INSERT INTO ops_search_agent.corpus_registry
--     (schema_name, corpus_type, embedding_model, embedding_dim,
--      chunk_table, chunk_text_col, chunk_vec_col)
--   VALUES
--     ('case_legacy', 'case',
--      'sentence-transformers/all-MiniLM-L6-v2', 384,
--      'text_chunks', 'text', 'embedding');

CREATE SCHEMA IF NOT EXISTS ops_search_agent;

-- Corpus registry: one row per searchable corpus schema
CREATE TABLE IF NOT EXISTS ops_search_agent.corpus_registry (
    schema_name        text PRIMARY KEY,
    corpus_type        text NOT NULL,                          -- 'case' | 'corpus' | 'legal' | 'ops'
    description        text,
    embedding_model    text NOT NULL DEFAULT 'voyageai/voyage-context-3',
    embedding_dim      integer NOT NULL DEFAULT 1024,
    chunk_table        text NOT NULL DEFAULT 'chunks',
    chunk_text_col     text NOT NULL DEFAULT 'content',
    chunk_vec_col      text NOT NULL DEFAULT 'embedding',
    chunk_id_col       text NOT NULL DEFAULT 'id',             -- canonical: chunks.id (PLAYBOOK Section 2)
    source_files_table text DEFAULT 'source_files',
    in_evidence_search boolean NOT NULL DEFAULT true,          -- include in v_evidence_search
    registered_at      timestamptz NOT NULL DEFAULT now(),
    last_chunks_count  bigint,
    last_chunks_count_at timestamptz,
    notes              text
);

COMMENT ON TABLE ops_search_agent.corpus_registry IS
  'One row per searchable PG corpus schema. Drives auto-rebuild of v_evidence_search via event trigger. Agents query this to discover available corpora. Defaults match PLAYBOOK Section 2 canonical (chunks/content/halfvec(1024)); register legacy 384-dim corpora with explicit overrides.';

COMMENT ON COLUMN ops_search_agent.corpus_registry.in_evidence_search IS
  'true = include in the cross-schema v_evidence_search view. Set false to exclude a schema (e.g., test/scratch corpora).';

COMMENT ON COLUMN ops_search_agent.corpus_registry.chunk_id_col IS
  'Name of the primary key column in chunk_table (default ''id'' per PLAYBOOK Section 2 canonical schema; override for legacy corpora that use chunk_id).';

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
-- Projection includes the embedding column so the view can be used for vector search.
-- IMPORTANT: all included corpora MUST share the same embedding type (vector(N) or
-- halfvec(N) with matching N). Mixed-type corpora will fail the UNION ALL type check.
-- Exclude mismatched legacy corpora via in_evidence_search = false.
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
        SELECT schema_name, chunk_table, chunk_text_col, chunk_vec_col,
               chunk_id_col, embedding_model
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
                'SELECT %L::text AS schema_name, %I AS chunk_id, %I AS content, '
                '%I AS embedding, %L::text AS embedding_model '
                'FROM %I.%I',
                rec.schema_name,
                rec.chunk_id_col,
                rec.chunk_text_col,
                rec.chunk_vec_col,
                rec.embedding_model,
                rec.schema_name,
                rec.chunk_table
            ));
        END IF;
    END LOOP;

    -- Drop existing view so projection changes (e.g. added embedding column) take effect
    EXECUTE 'DROP VIEW IF EXISTS ops_search_agent.v_evidence_search';
    IF array_length(union_parts, 1) > 0 THEN
        sql_text := 'CREATE VIEW ops_search_agent.v_evidence_search AS '
            || array_to_string(union_parts, ' UNION ALL ');
        EXECUTE sql_text;
    ELSE
        -- No registered corpora yet: create an empty placeholder view so
        -- downstream code that expects v_evidence_search to exist still works.
        -- Cast literals so PG can infer column types without rows.
        EXECUTE $emp$
            CREATE VIEW ops_search_agent.v_evidence_search AS
            SELECT
                NULL::text   AS schema_name,
                NULL::bigint AS chunk_id,
                NULL::text   AS content,
                NULL::vector AS embedding,
                NULL::text   AS embedding_model
            WHERE false
        $emp$;
    END IF;
    COMMENT ON VIEW ops_search_agent.v_evidence_search IS
      'Cross-corpus search view. Auto-rebuilt from corpus_registry by rebuild_v_evidence_search() and the corpus_schema_created event trigger. Use schema_name to disambiguate when filtering. All included corpora must share the same embedding type.';
END;
$$;

COMMENT ON FUNCTION ops_search_agent.rebuild_v_evidence_search IS
  'Rebuilds v_evidence_search as UNION ALL across all in_evidence_search=true rows in corpus_registry. Called automatically by the corpus_schema_created event trigger; call manually after updating in_evidence_search or chunk_*_col registry entries.';

-- View for orphan rows (schema dropped externally but registry row remains)
CREATE OR REPLACE VIEW ops_search_agent.v_corpus_registry_orphans AS
SELECT cr.*
FROM ops_search_agent.corpus_registry cr
WHERE NOT EXISTS (
    SELECT 1 FROM information_schema.schemata s
    WHERE s.schema_name = cr.schema_name
);

COMMENT ON VIEW ops_search_agent.v_corpus_registry_orphans IS
  'Registry rows whose schema_name no longer exists in information_schema.schemata. Triage source for stale registry entries; cleanup with DELETE FROM corpus_registry WHERE schema_name IN (SELECT schema_name FROM v_corpus_registry_orphans).';

-- ============================================================================
-- Event trigger: auto-register newly created case_*, corpus_*, legal_* schemas
-- Per PLAYBOOK Section 10 lines 781-801
-- ============================================================================
CREATE OR REPLACE FUNCTION ops_search_agent.on_corpus_schema_created()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN
        SELECT * FROM pg_event_trigger_ddl_commands()
        WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        IF obj.object_identity ~ '^(case_|corpus_|legal_)' THEN
            INSERT INTO ops_search_agent.corpus_registry(schema_name, corpus_type)
            VALUES (
                obj.object_identity,
                split_part(obj.object_identity, '_', 1)
            )
            ON CONFLICT (schema_name) DO NOTHING;
            PERFORM ops_search_agent.rebuild_v_evidence_search();
        END IF;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION ops_search_agent.on_corpus_schema_created IS
  'Event-trigger callback. Fires on CREATE SCHEMA; auto-registers schemas matching case_*/corpus_*/legal_* and rebuilds v_evidence_search. Set in_evidence_search = false on the new row to opt out post-hoc.';

-- Drop + recreate the trigger so re-runs of this script update the callback target.
-- CREATE EVENT TRIGGER requires superuser. We wrap it so a non-superuser
-- deploy still completes -- the function above exists either way; only the
-- automatic CREATE SCHEMA hook is lost, and the operator can INSERT into
-- corpus_registry manually + call rebuild_v_evidence_search() themselves.
DO $$
BEGIN
    EXECUTE 'DROP EVENT TRIGGER IF EXISTS corpus_schema_created';
    EXECUTE 'CREATE EVENT TRIGGER corpus_schema_created '
            'ON ddl_command_end WHEN TAG IN (''CREATE SCHEMA'') '
            'EXECUTE FUNCTION ops_search_agent.on_corpus_schema_created()';
    EXECUTE 'COMMENT ON EVENT TRIGGER corpus_schema_created IS '
            '''Auto-registers new case_*/corpus_*/legal_* schemas into '
            'ops_search_agent.corpus_registry and rebuilds v_evidence_search. '
            'Disable temporarily with ALTER EVENT TRIGGER corpus_schema_created DISABLE;''';
    RAISE NOTICE 'Event trigger corpus_schema_created installed; new CREATE SCHEMA will auto-register.';
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE 'CREATE EVENT TRIGGER blocked: current user lacks superuser privilege. '
                     'on_corpus_schema_created() function still exists but auto-registration is OFF. '
                     'Either rerun as a superuser, OR INSERT each new corpus into '
                     'ops_search_agent.corpus_registry manually and call rebuild_v_evidence_search().';
END $$;

-- Build the view now from any backfilled rows
SELECT ops_search_agent.rebuild_v_evidence_search();

-- Verify the view exists and is queryable
SELECT COUNT(*) AS total_chunks_in_evidence_search
FROM ops_search_agent.v_evidence_search;
