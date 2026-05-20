# Postgres-for-AI-Agents Schema Design: Conventions for `valor_consolidated`

**Audience:** Levi Bakke / Valor Investigations
**Subject:** Standardize the 37-schema `valor_consolidated` Postgres deployment before scaling further
**Date:** 2026-05-19
**Confidence grades:** A = canonical Postgres/pgvector docs, B = vendor blogs (Crunchy, Supabase, Neon), C = community/GitHub issues, D = inferred from primary sources

---

## TL;DR

1. **Keep schema-per-corpus.** Levi's existing pattern (`case_*` / `corpus_*` / `ops_*` / `legal_*`) is the right shape for an LLM-driven, evidence-grade workload. Migrating to one mega-table with a `corpus_id` partition key buys nothing meaningful and burns the existing migration provenance, RLS isolation potential, and per-corpus index tuning. **(A/B)**
2. **Adopt a frozen canonical table set** -- `source_files`, `chunks`, `entities`, `entity_mentions`, `chunk_relations`, `audit_log` -- and a frozen column set inside each. Drift between schemas is the actual cost driver, not the schema count.
3. **The UNION ALL view (`v_evidence_search`) stays a regular view, not a matview.** Add a `schema_registry` table + DDL-driven view-rebuild trigger so new corpora self-register. Matview only if read latency on the UNION measurably hurts -- and only with `REFRESH ... CONCURRENTLY` plus a `UNIQUE` index. **(A)**
4. **JSONB for "structured-but-evolving metadata," flat columns for everything the agent filters or sorts on.** Use `jsonb_path_ops` GIN. Anything queried `WHERE x = 'y'` more than 5x/week earns a flat column or expression index. **(A)**
5. **Partition only when a single `chunks` table crosses ~5M rows AND HNSW build memory becomes a problem.** Default partitioning key: `RANGE (ingested_at)` monthly. Build one HNSW index per partition; the planner prunes by `ingested_at` before vector scan. **(A/C)**
6. **Skip RLS.** Single-application, single-user system. RLS adds per-row policy evaluation overhead and zero security gain. Enforce at the application layer. **(A)**
7. **Comments on everything.** `COMMENT ON TABLE/COLUMN/SCHEMA` is the single most leveraged change Levi can make for LLM agent introspection -- every table comment is one less mistake a head/worker makes guessing column semantics. **(A)**
8. **Audit log = trigger-driven JSONB table per schema, not pgaudit.** pgaudit writes to the Postgres log file (CSV); litigation evidence needs queryable, indexed, timestamped row-level diffs. Trigger pattern is canonical. **(A)**

---

## 1. Schema-per-corpus vs Single Mega-Table

### Decision: keep schema-per-corpus

**Trade-offs analyzed:**

| Dimension | Schema-per-corpus (current) | Single table + `corpus_id` |
|---|---|---|
| **pgvector HNSW index size** | Each schema's `chunks` table has its own HNSW; index size scales linearly per corpus. No cross-corpus index contention. **(A)** | One giant HNSW. pgvector docs explicitly warn: "indexes build significantly faster when the graph fits into `maintenance_work_mem`" -- once HNSW exceeds the configured RAM (default 64MB, recommend 8GB), build slows dramatically and a NOTICE fires: "hnsw graph no longer fits into maintenance_work_mem after 100000 tuples." **(A)** |
| **Practical HNSW ceiling** | pgvector ships no hard row cap; community guidance (Supabase, Crunchy, Neon) treats **~5-10M vectors per single HNSW** as the comfort zone before partitioning becomes mandatory **(B/C)**. Schema-per-corpus naturally enforces this. | Levi's `corpus_oregon_public_records_filesystem` alone is 238,659 chunks; the cross-schema UNION view already hits 2.4M chunks. A single mega-table would push past the comfort zone within the next 2-3 ingest cycles. |
| **Cross-corpus search** | UNION ALL view (the existing `ops_records_officer.v_evidence_search` pattern). Postgres can push predicates into each branch. **(A)** | Native -- just `WHERE corpus_id = ANY(...)`. But: every vector search scans the global HNSW; filters apply *after* ANN traversal (pgvector issue #980), so corpus filtering is a post-filter, not a pre-filter. **(C)** |
| **search_path performance** | `SET search_path TO case_bingaman_dhs, public` is constant-time lookup; namespace resolution cost is negligible at <1000 schemas. **(A)** | N/A |
| **ALTER TABLE / migration friction** | Schema drift is the real cost. If every `chunks` table has a slightly different DDL, agents can't write portable SQL. **Mitigated by mandating a canonical DDL template (see Section 2).** | One ALTER hits one table -- but also locks 2.4M rows. Schema-per-corpus localizes lock scope to one corpus. |
| **Permissions / RLS** | Per-schema GRANT is trivial. RLS is unnecessary (Section 7). | Forces RLS or `WHERE corpus_id IN (allowed_list)` on every query. |
| **Drop / archive a corpus** | `DROP SCHEMA case_foo CASCADE` -- atomic, fast, reversible-by-restore. | `DELETE FROM chunks WHERE corpus_id = 'foo'` -- slow, vacuum-heavy, breaks HNSW. |
| **Migration provenance** | Levi's `migration` schema already tracks `sqlite_sources`, `chroma_sources`, `import_runs` per source. Schema-per-corpus aligns with this. | Would require a parallel `corpus_id` dimension everywhere. Redundant. |

**Recommendation:** Schema-per-corpus stays. The cost is **enforced uniformity within each schema**, not schema count itself.

---

## 2. Standard Table Set (Canonical DDL)

Every new `case_*`, `corpus_*`, or `legal_*` schema should be created from this template. Treat this DDL as immutable; deviations require a documented rationale in the schema's `__schema_meta` table.

```sql
-- ============================================================
-- CANONICAL VALOR CORPUS SCHEMA TEMPLATE v1
-- Run as: psql -d valor_consolidated -f valor_corpus_template.sql -v schema=case_foo
-- ============================================================

CREATE SCHEMA IF NOT EXISTS :"schema";
SET search_path TO :"schema", public;

-- Self-documentation row -- every schema MUST have one
CREATE TABLE __schema_meta (
    key text PRIMARY KEY,
    value text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE __schema_meta IS
    'One row per metadata key for this schema. Required keys: corpus_type, owner_matter, embedding_model, embedding_dim, parser_version, created_at, ddl_template_version.';

INSERT INTO __schema_meta(key, value) VALUES
    ('ddl_template_version', '1'),
    ('created_at', now()::text);

-- ============================================================
-- source_files: one row per ingested file
-- ============================================================
CREATE TABLE source_files (
    id              bigserial PRIMARY KEY,
    path            text NOT NULL,
    sha256          char(64) NOT NULL,
    size_bytes      bigint NOT NULL,
    mime            text,
    parser          text NOT NULL,            -- 'pdfminer', 'unstructured', 'mailparse', etc.
    parser_version  text NOT NULL,
    ingested_at     timestamptz NOT NULL DEFAULT now(),
    status          text NOT NULL DEFAULT 'ok',  -- ok | failed | quarantined | superseded
    error_message   text,
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT source_files_sha256_unique UNIQUE (sha256)
);
CREATE INDEX source_files_ingested_at_idx ON source_files (ingested_at);
CREATE INDEX source_files_status_idx ON source_files (status) WHERE status <> 'ok';
CREATE INDEX source_files_metadata_gin ON source_files USING gin (metadata jsonb_path_ops);

COMMENT ON TABLE source_files IS
    'One row per ingested file. sha256 is the dedupe key. status=ok means chunks were successfully written; failed/quarantined files are kept so re-ingestion does not re-process them.';
COMMENT ON COLUMN source_files.parser IS
    'Parser library used (pdfminer, unstructured, mailparse, etc.). Combined with parser_version to make ingestion reproducible.';
COMMENT ON COLUMN source_files.metadata IS
    'JSONB. Holds parser-specific fields (page_count, author, document_type, etc.). Promote to flat columns when filtered >5x/week.';

-- ============================================================
-- chunks: the vector + FTS table
-- ============================================================
CREATE TABLE chunks (
    id                bigserial PRIMARY KEY,
    source_file_id    bigint NOT NULL REFERENCES source_files(id) ON DELETE CASCADE,
    chunk_idx         int NOT NULL,         -- 0-indexed order within the source file
    content           text NOT NULL,
    content_tsv       tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
    embedding         vector(1024),         -- nullable so chunks can land before embedding
    embedding_model   text,                  -- e.g. 'text-embedding-3-large', 'nomic-embed-text-v1.5'
    chunk_method      text NOT NULL,        -- 'recursive_char', 'semantic', 'fixed_token', etc.
    chunk_size_tokens int,
    metadata          jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chunks_unique UNIQUE (source_file_id, chunk_idx)
);
CREATE INDEX chunks_content_tsv_gin ON chunks USING gin (content_tsv);
CREATE INDEX chunks_metadata_gin ON chunks USING gin (metadata jsonb_path_ops);
CREATE INDEX chunks_source_file_id_idx ON chunks (source_file_id);
-- Create HNSW AFTER bulk insert; remove the inline definition.
-- CREATE INDEX chunks_embedding_hnsw ON chunks USING hnsw (embedding vector_cosine_ops)
--     WITH (m = 16, ef_construction = 64);

COMMENT ON TABLE chunks IS
    'Embeddings + FTS. content_tsv is a stored generated column so writers do not have to remember to update it. HNSW vector index is created AFTER bulk load (pgvector best practice).';
COMMENT ON COLUMN chunks.embedding_model IS
    'Model name AS WRITTEN BY THE EMBEDDER. Mixing models in one column requires per-row filtering on this column at query time.';
COMMENT ON COLUMN chunks.metadata IS
    'JSONB. Holds page numbers, span offsets, document section, etc. Indexed with jsonb_path_ops GIN.';

-- ============================================================
-- entities: canonical named-entity registry (NER + dedup)
-- ============================================================
CREATE TABLE entities (
    id            bigserial PRIMARY KEY,
    name          text NOT NULL,
    type          text NOT NULL,        -- person | org | location | date | case | docket | statute | other
    canonical_id  bigint REFERENCES entities(id),  -- self-FK for alias -> canonical resolution
    metadata      jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT entities_name_type_unique UNIQUE (name, type)
);
CREATE INDEX entities_canonical_idx ON entities (canonical_id) WHERE canonical_id IS NOT NULL;
CREATE INDEX entities_type_idx ON entities (type);
CREATE INDEX entities_name_trgm ON entities USING gin (name gin_trgm_ops);  -- pg_trgm fuzzy match

COMMENT ON TABLE entities IS
    'Named-entity registry. Use canonical_id to alias "Patty Bingaman" -> "Patricia Bingaman" without losing the variant.';

-- ============================================================
-- entity_mentions: chunk <-> entity edges with span offsets
-- ============================================================
CREATE TABLE entity_mentions (
    id           bigserial PRIMARY KEY,
    chunk_id     bigint NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
    entity_id    bigint NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    span_start   int,
    span_end     int,
    confidence   real,
    extractor    text NOT NULL,           -- 'spacy_en_core_web_lg', 'llm_gpt5_pro', etc.
    metadata     jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX entity_mentions_chunk_idx ON entity_mentions (chunk_id);
CREATE INDEX entity_mentions_entity_idx ON entity_mentions (entity_id);

COMMENT ON TABLE entity_mentions IS
    'Chunk-to-entity edges. Multiple extractors may produce overlapping mentions; do not dedupe -- preserve provenance.';

-- ============================================================
-- chunk_relations: graph-style edges between chunks
-- ============================================================
CREATE TABLE chunk_relations (
    id          bigserial PRIMARY KEY,
    src_chunk_id bigint NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
    dst_chunk_id bigint NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
    relation    text NOT NULL,            -- 'cites' | 'replies_to' | 'attaches' | 'references' | 'supersedes'
    confidence  real,
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chunk_relations_unique UNIQUE (src_chunk_id, dst_chunk_id, relation)
);
CREATE INDEX chunk_relations_src_idx ON chunk_relations (src_chunk_id);
CREATE INDEX chunk_relations_dst_idx ON chunk_relations (dst_chunk_id);
CREATE INDEX chunk_relations_relation_idx ON chunk_relations (relation);

COMMENT ON TABLE chunk_relations IS
    'Directed graph edges between chunks. Use sparingly -- only when the relation is load-bearing for retrieval (citation graphs, email threads, exhibit attachments).';

-- ============================================================
-- audit_log: append-only event stream (see Section 8 for trigger)
-- ============================================================
CREATE TABLE audit_log (
    id          bigserial PRIMARY KEY,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    actor       text NOT NULL,            -- 'system' | 'agent:<id>' | 'user:levi' | 'migration'
    action      text NOT NULL,            -- 'insert' | 'update' | 'delete' | 'ingest' | 'reindex'
    target_table text NOT NULL,
    target_pk   bigint,
    before      jsonb,
    after       jsonb,
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX audit_log_occurred_at_idx ON audit_log (occurred_at);
CREATE INDEX audit_log_target_idx ON audit_log (target_table, target_pk);
CREATE INDEX audit_log_actor_idx ON audit_log (actor);

COMMENT ON TABLE audit_log IS
    'Append-only event log for litigation evidence. Populated by triggers on chunks/source_files/entities. Never UPDATE or DELETE from this table outside of court-supervised redaction.';
```

**Conventions baked in:**

- `bigserial` PK everywhere (matches existing schemas; `bigint` ceiling is irrelevant in practice).
- `metadata jsonb NOT NULL DEFAULT '{}'::jsonb` on every table -- never `NULL`, so `metadata->>'foo'` is always safe.
- `created_at` / `ingested_at` / `occurred_at` on everything; `timestamptz` (not `timestamp`).
- Generated `content_tsv` so callers can't forget to populate it.
- `pg_trgm` GIN on `entities.name` for fuzzy-match dedup.
- HNSW deferred to a post-load step (matches pgvector docs).

**(A/B confidence; aligned with pgvector docs + existing valor_consolidated patterns.)**

---

## 3. JSONB Metadata Patterns

### Rules

1. **Default landing zone for parser/extractor output is `metadata jsonb`.** Promote a key to a flat column when ANY of the following is true:
   - It's queried `WHERE x = ?` or `ORDER BY x` more than 5x/week.
   - It's a foreign key or has referential integrity meaning.
   - It's NOT NULL on every row (then it's not really "metadata," it's a column).
   - The agent's `information_schema` introspection needs to find it without reading JSON keys.
2. **GIN index with `jsonb_path_ops` is the default.** Docs (A): "`jsonb_path_ops` index is usually much smaller than a `jsonb_ops` index over the same data, and the specificity of searches is better." Only switch to default `jsonb_ops` if you actively use the key-exists operators (`?`, `?|`, `?&`) -- which you usually don't, you use `@>` containment.
3. **Add expression indexes for hot JSON paths.** If `metadata->>'court'` is hit constantly, add `CREATE INDEX chunks_court_idx ON chunks ((metadata->>'court'));` -- the GIN won't help an equality+sort query.
4. **JSONB performance traps to avoid (A):**
   - **Row-level lock on whole row when JSONB updates.** Don't store frequently-mutated fields in JSONB on a hot table -- promote them.
   - **Atomic value rule:** "JSON documents should each represent an atomic datum that business rules dictate cannot reasonably be further subdivided." Don't dump entire 50KB chart notes into one `metadata` field.
   - **Empty `{}` indexes:** `jsonb_path_ops` produces no entries for `{}`. If you frequently filter on "metadata has any key," use `jsonb_ops` or a `metadata <> '{}'` predicate index.
5. **Agent-queryable metadata pattern:** keep top-level keys SHORT, FLAT, and DOCUMENTED in `__schema_meta`:

```jsonc
// chunks.metadata example for case_bingaman_dhs
{
  "page": 12,
  "section": "VI.A",
  "doc_type": "deposition",
  "deponent": "Glenn Null",
  "exhibit_ref": "PX-104",
  "page_range": [12, 18]
}
```

NOT this:
```jsonc
{ "document": { "pagination": { "page": 12, "range": [12, 18] } } }  // deep nesting -> path queries get ugly fast
```

---

## 4. Declarative Partitioning

### When to partition

Default: **don't partition until the corpus's `chunks` table crosses ~5M rows** AND either (a) HNSW build runs out of `maintenance_work_mem`, or (b) per-time-window queries dominate. Levi's largest single corpus is 238K chunks today -- partitioning is premature.

### When the threshold trips, choose the key:

| Workload | Partition strategy | Why |
|---|---|---|
| Time-series ingest (FOIA productions, daily news scrapes) | **RANGE (ingested_at)** monthly | Postgres 16+ partition pruning is constant-time; old months can be detached and archived; HNSW index per partition keeps build memory bounded. **(A)** |
| Many small tenants, unknown growth | **HASH (source_file_id)** with 16 or 32 partitions | Even distribution; no skew. Docs (A): "If you find yourself with a large number of small customers, consider partition by HASH and choose a reasonable number of partitions rather than trying to partition by LIST." |
| Few large categories, known fixed set | **LIST (corpus_id)** | Only if categories are stable. Cite (A): not ideal if categories "grow significantly over time." |

### Partitioning + HNSW interaction

**Postgres 16+ partition pruning:** Driven by partition bounds, not indexes (A). So if you partition by `ingested_at` and query `WHERE ingested_at >= '2026-01-01'`, the planner skips all earlier partitions BEFORE the vector scan begins -- this is the win.

**Index inheritance:** `CREATE INDEX ... ON parent_table` automatically propagates to all current AND future partitions (A). For HNSW:

```sql
-- On the partitioned parent
CREATE INDEX ON chunks USING hnsw (embedding vector_cosine_ops);
```

This creates one HNSW per partition automatically. Each is small enough to fit in `maintenance_work_mem` -- which is the whole point.

**Caveat (A):** `CONCURRENTLY` is NOT supported on partitioned-table indexes directly. To rebuild HNSW concurrently:
1. `CREATE INDEX ... ON ONLY parent_table` (marks parent index invalid).
2. `CREATE INDEX CONCURRENTLY ... ON each_partition`.
3. `ALTER INDEX parent_index ATTACH PARTITION partition_index`.

**Cross-partition vector queries:** Planner scans every non-pruned partition's HNSW and merges results. This is fine for top-K queries (each partition contributes K candidates, merger picks global top-K). It's NOT fine for queries that need a global rank without partition predicates -- which is why you partition on something the agent will routinely filter on (time, category, etc.).

**pgvector + partitioning resolution (C):** GitHub issue #891 confirmed pgvector supports HASH/RANGE/LIST partitioning with HNSW. The community pattern: keep per-partition HNSW small (under 10M vectors / 5GB), expect linear query-time scaling with partition count when no pruning predicate is supplied.

### Partition count guidance (A)

- Query planner handles "up to a few thousand partitions" but planning time grows with count.
- Memory per session: "each partition requires its metadata to be loaded into the local memory of each session that touches it." For Levi's agent firm with persistent connections this matters.
- **Practical cap: 100-500 partitions per table.** For monthly RANGE partitioning that's 8-40 years of history -- plenty.

---

## 5. Cross-Schema Search View

### Current state

`ops_records_officer.v_evidence_search` is a `UNION ALL` view across 6 schemas (2.4M chunks). Adding a new schema means manually editing the view DDL -- the friction point Levi flagged.

### Recommendation: registration table + DDL-rebuild trigger (NOT a matview)

**Why not a matview:**
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` requires a `UNIQUE` index on the matview -- non-trivial when the source rows have schema-local primary keys (chunks.id=42 exists in every schema). Either composite `(schema_name, id)` or surrogate UUID required.
- 2.4M-row REFRESH takes minutes; concurrent refresh holds more locks longer than the default. Docs (A): "without CONCURRENTLY a refresh which affects a lot of rows will tend to use fewer resources and complete more quickly, but could block other connections... CONCURRENTLY may be faster in cases where a small number of rows are affected." 2.4M rows is NOT a small change.
- A regular `UNION ALL` view lets the planner push predicates into each branch (partition-wise filter pushdown). For most queries (`WHERE content_tsv @@ ...`, `ORDER BY embedding <=> ...`), the cost dominates in the underlying indexes, not the UNION.

**The pattern:**

```sql
-- 1. Registration table -- ground truth for "which schemas exist"
CREATE TABLE ops_records_officer.corpus_registry (
    schema_name    text PRIMARY KEY,
    corpus_type    text NOT NULL,        -- 'case' | 'corpus' | 'legal' | 'ops'
    owner_matter   text,                  -- e.g. '23PR02271 Bingaman'
    embedding_model text,
    embedding_dim  int,
    included_in_search boolean NOT NULL DEFAULT true,
    registered_at  timestamptz NOT NULL DEFAULT now(),
    metadata       jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- 2. Function that rebuilds v_evidence_search from the registry
CREATE OR REPLACE FUNCTION ops_records_officer.rebuild_v_evidence_search()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    rec record;
    sql_parts text[] := ARRAY[]::text[];
BEGIN
    FOR rec IN
        SELECT schema_name FROM ops_records_officer.corpus_registry
        WHERE included_in_search = true ORDER BY schema_name
    LOOP
        sql_parts := array_append(sql_parts, format(
            'SELECT %L::text AS schema_name, c.id, c.source_file_id, c.chunk_idx, ' ||
            'c.content, c.content_tsv, c.embedding, c.embedding_model, ' ||
            'c.metadata, c.created_at FROM %I.chunks c',
            rec.schema_name, rec.schema_name
        ));
    END LOOP;

    EXECUTE 'DROP VIEW IF EXISTS ops_records_officer.v_evidence_search';
    EXECUTE 'CREATE VIEW ops_records_officer.v_evidence_search AS ' ||
            array_to_string(sql_parts, ' UNION ALL ');
END;
$$;

-- 3. Event trigger so new schemas auto-register and view auto-rebuilds
-- (Only fire when the new schema matches our naming convention)
CREATE OR REPLACE FUNCTION ops_records_officer.on_corpus_schema_created()
RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE
    obj record;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
        WHERE command_tag = 'CREATE SCHEMA'
    LOOP
        IF obj.object_identity ~ '^(case_|corpus_|legal_)' THEN
            INSERT INTO ops_records_officer.corpus_registry(schema_name, corpus_type)
            VALUES (
                obj.object_identity,
                split_part(obj.object_identity, '_', 1)
            )
            ON CONFLICT (schema_name) DO NOTHING;
            PERFORM ops_records_officer.rebuild_v_evidence_search();
        END IF;
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER corpus_schema_created
    ON ddl_command_end
    WHEN TAG IN ('CREATE SCHEMA')
    EXECUTE FUNCTION ops_records_officer.on_corpus_schema_created();
```

**Now:** `CREATE SCHEMA case_eckstein` auto-registers + auto-rebuilds the view. Removing a corpus from search: `UPDATE corpus_registry SET included_in_search = false WHERE schema_name = '...'; SELECT rebuild_v_evidence_search();`

**(B/C confidence; pattern is canonical for "many-similar-tables" sharding, e.g. Citus pre-distributed-table era.)**

### When to upgrade to a matview

Only if `EXPLAIN ANALYZE` on `v_evidence_search` shows scan-time dominating index-time (e.g., parsing the view definition takes longer than executing it). At 2.4M rows that's not happening. Revisit at 50M+.

---

## 6. Naming Conventions for Agent Introspection

LLM agents read `information_schema` to discover what's available. Self-documenting names + universal `COMMENT ON` are higher leverage than any docstring.

### Naming rules

1. **Schema prefix encodes corpus type:**
   - `case_*` -- one active legal matter (e.g., `case_26cv11493`, `case_bingaman_dhs`)
   - `corpus_*` -- one ingest source bundle (e.g., `corpus_oregon_public_records_filesystem`)
   - `legal_*` -- one legal-research project (e.g., `legal_438_research`, `legal_eocco_medicaid`)
   - `ops_*` -- firm operational state (e.g., `ops_records_officer`, `ops_complaints`)
   - `__staging` / `__migration` -- transient (double-underscore prefix sorts last in `\dn`)

2. **Table names are nouns, plural, lowercase, snake_case.** `source_files`, `chunks`, `entities`. NEVER `tbl_chunks`, NEVER `Chunks`. Matches existing pattern.

3. **Column names spell out the noun.** `source_file_id` not `sf_id`. `embedding_model` not `emb_mdl`. Agent token cost is irrelevant; agent confusion cost is enormous.

4. **Foreign key columns end in `_id`.** Always.

5. **Boolean columns start with `is_` or `has_`.** `is_redacted`, `has_attachments`.

6. **Timestamps end in `_at`.** `ingested_at`, `created_at`, `occurred_at`.

7. **JSONB columns are named `metadata`** unless they have a more specific role (e.g., `before`, `after` in `audit_log`).

### COMMENT ON everything

Levi's information_schema introspection becomes 10x more useful when `COMMENT ON` is everywhere:

```sql
COMMENT ON SCHEMA case_bingaman_dhs IS
  'Russell Bingaman / Patricia Bingaman v. DHS records. Linked matter: 23PR02271 (Bingaman guardianship), 26CV11493 (Bakke v ODHS dismissed without prejudice). Owner: levi. DDL template v1.';

COMMENT ON TABLE chunks IS
  'Text + embeddings for this corpus. HNSW vector index on cosine distance. FTS via tsvector GIN. Filter by metadata->>''doc_type'' for document-class subsets.';

COMMENT ON COLUMN chunks.embedding_model IS
  'Embedding model name as written by the embedder. Current: text-embedding-3-large (1024d after Matryoshka truncate). Mixing models in one column requires per-row filtering.';
```

**Agent retrieval query:**

```sql
SELECT
    n.nspname AS schema,
    c.relname AS table,
    a.attname AS column,
    pg_catalog.format_type(a.atttypid, a.atttypmod) AS type,
    pg_catalog.obj_description(c.oid, 'pg_class') AS table_comment,
    pg_catalog.col_description(c.oid, a.attnum) AS column_comment
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
  AND a.attnum > 0 AND NOT a.attisdropped
ORDER BY n.nspname, c.relname, a.attnum;
```

Cache this output once per session; it's the agent's map of the database. **(A; canonical pg_description + information_schema join.)**

---

## 7. Multi-Tenancy / RLS

### Recommendation: skip RLS entirely

**Why:**

- Single application (Valor firm), single primary user (Levi), single connection role. The "tenants" are corpora (schemas), not users (A: "RLS adds unnecessary overhead when the application already controls access").
- RLS evaluates policy expression on every row before user predicates. For vector search over millions of rows, that's millions of extra plpgsql function calls.
- Postgres docs (A) explicitly call out application-layer enforcement as the right call for trusted single-app systems.

### When RLS would become useful

- If Levi sells/licenses the firm to other investigators -> each gets their own role + RLS to enforce corpus isolation.
- If specific corpora need to be hidden from specific worker types (e.g., the McSherry corpus is sealed from the news-writer head). Today that's enforced at the application layer; if a worker bypasses it, RLS would be a defense-in-depth backstop.
- If the database role used by the agents differs from the admin role -- then `FORCE ROW LEVEL SECURITY` on sensitive tables ensures admins are also subject to policies.

Today: enforce at application layer (Filing Director / records officer). Document the decision in `__schema_meta`.

---

## 8. Append-Only / Audit Log Patterns

### Recommendation: trigger-based per-schema `audit_log` table, NOT pgaudit

**Why not pgaudit:**

- pgaudit writes to the Postgres log file as CSV (A). Logs are flat text; querying them requires file parsing or external pipeline (Loki, Datadog, etc.). Levi has neither.
- pgaudit captures statement text -- which is useful but is NOT a row-level diff. For evidence (e.g., "the chunk content was X on 2026-04-01 and is now Y"), you need before/after row JSON, not the SQL string.
- Supabase confirms (B): pgaudit on Supabase is "role-level configuration only" and logs land in a separate dashboard. Not queryable from SQL.

### Why trigger-based:

- Captures `OLD.*` and `NEW.*` as JSONB -- complete row-level evidence.
- Stays in the database (queryable via the same agents).
- Per-schema `audit_log` (already in the canonical DDL above) keeps audit data co-located with the data it audits.

### The trigger:

```sql
CREATE OR REPLACE FUNCTION audit_row_change()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    actor_val text := COALESCE(current_setting('valor.actor', true), session_user);
BEGIN
    INSERT INTO audit_log(actor, action, target_table, target_pk, before, after, metadata)
    VALUES (
        actor_val,
        lower(TG_OP),
        TG_TABLE_NAME,
        CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END,
        jsonb_build_object('txid', txid_current())
    );
    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Attach to the canonical tables
CREATE TRIGGER chunks_audit AFTER INSERT OR UPDATE OR DELETE ON chunks
    FOR EACH ROW EXECUTE FUNCTION audit_row_change();
CREATE TRIGGER source_files_audit AFTER INSERT OR UPDATE OR DELETE ON source_files
    FOR EACH ROW EXECUTE FUNCTION audit_row_change();
CREATE TRIGGER entities_audit AFTER INSERT OR UPDATE OR DELETE ON entities
    FOR EACH ROW EXECUTE FUNCTION audit_row_change();
```

**The agent sets `actor` via:** `SET LOCAL valor.actor = 'agent:filing_director';` at the start of its transaction. This makes the audit log per-agent attributable.

### Temporal tables alternative

The `arkhipov/temporal_tables` extension (B) gives you full system-versioned tables with history kept in a parallel table -- richer than `audit_log`. But:
- Extra extension to install + maintain on every Postgres upgrade.
- Storage doubles (every row keeps every version in the history table).
- For evidence purposes, `audit_log` JSONB diffs are sufficient; history tables are overkill until a specific litigation need (e.g., "show me how this chunk evolved over the past year") arises.

### Litigation-grade hardening

The Postgres wiki audit-trigger pattern (A) flags one weakness: "Changes by the table owner and superusers are tracked, but can be trivially tampered with." Mitigations:
1. **Application-layer hash chaining.** Each `audit_log` row carries `hash(previous_row_hash || this_row_canonical_json)` in metadata. Tampering breaks the chain.
2. **WAL archiving to immutable storage** (S3 Object Lock, GCS Bucket Lock). Restores any tampered audit state.
3. **Periodic export to append-only filesystem** (e.g., daily `pg_dump --schema=*audit_log* | gpg --sign > /immutable/audit-YYYY-MM-DD.sql.gpg`).

For Bingaman/McSherry/EOCCO litigation: #2 + #3 are the load-bearing pieces. Hash chaining is nice-to-have. **(B/D)**

---

## Appendix A: Migration plan for existing 37 schemas

1. **Audit existing schemas.** Run a script that compares each schema's `chunks` / `source_files` DDL to the canonical template. Output drift report.
2. **Bring drift inside the canonical envelope.** Most common drifts will be missing `metadata jsonb` defaults, missing `content_tsv` generated column, missing GINs, missing comments.
3. **Add `__schema_meta` table to every schema.** Backfill from `migration` schema where possible.
4. **Add `corpus_registry` table + DDL trigger** (Section 5).
5. **Add `audit_log` table + triggers** (Section 8).
6. **Add `COMMENT ON` to every existing schema/table/column.** This is grindwork; dispatch to a worker.
7. **Document the standard in `/home/levi/Valor_Evidence_OS/00_standards/postgres_corpus_template.md`** so dept heads can apply it during new ingests without re-reading this report.

## Appendix B: What this DOESN'T address

- **Cross-corpus entity resolution.** Entities are per-schema today; a global `entities` registry (`ops_entities` with cross-schema FK) is a separate design decision -- worth doing, but out of scope here.
- **Embedding model versioning across corpora.** When you upgrade from `text-embedding-3-large` to `nomic-embed-text-v2.5`, you need a re-embed strategy. Mentioned in Section 2 but not solved.
- **Partition automation.** When you do start partitioning, you need a cron to pre-create next month's partition. `pg_partman` extension is the canonical solution -- worth installing before the first time you need it.
- **Backup strategy.** WAL archiving / point-in-time-recovery for `valor_consolidated` is a separate operational doc.

## Appendix C: Citations

- Postgres docs: ddl-partitioning, ddl-rowsecurity, sql-comment, sql-refreshmaterializedview, datatype-json, rules-materializedviews, infoschema-columns, ddl-schemas (all A).
- pgvector README / HNSW section, GitHub issues #259 / #891 / #980 (A/C).
- Supabase blog "pgvector performance" (B).
- Supabase docs "pgvector," "pgaudit" (B).
- Crunchy Data "Scaling Vector Data with Postgres" (B).
- Postgres Wiki "Audit trigger 91plus" (A).
- arkhipov/temporal_tables GitHub README (B).
- pgaudit GitHub README (A).

---

*End of report. File: /mnt/linux-storage/research/waves/postgres_ai_schema_design.md*
