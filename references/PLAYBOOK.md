# Postgres for AI-Agent-Only Consumption -- Canonical Playbook

**Generated:** 2026-05-19
**Audience:** Claude Code, Codex, Valor Agent Firm (Vertex Gemini ADK), and Levi (who configures the box but never queries it)
**Scope:** valor_consolidated Postgres 16, pgvector 0.8.2, pg_trgm, uuid-ossp; 37 schemas; ~2.4M chunks today; growing
**Style:** No em dashes. No emojis. Hedged where unverified.

This document is the synthesis of four parallel deep-research waves (vector indexing, ingestion pipeline, schema design, agent retrieval). The full per-wave findings remain as authoritative references at:

- `/mnt/linux-storage/research/waves/postgres_ai_vector_index.md`
- `/mnt/linux-storage/research/waves/postgres_ai_ingest_pipeline.md`
- `/mnt/linux-storage/research/waves/postgres_ai_schema_design.md`
- `/mnt/linux-storage/research/waves/postgres_ai_agent_retrieval.md`

Confidence grades: **A** = pgvector/Postgres docs or peer-reviewed paper, **B** = vendor blog (Supabase / Anthropic / Voyage / Tiger / Crunchy / Neon), **C** = synthesis or community pattern.

---

## 0. The Five Moves That Capture 90% of the Wins

If Levi reads only this section, these five changes deliver almost all of the measurable lift. Order matters.

1. **Enable iterative HNSW scan on the agent role.** Without this, every WHERE-filtered vector query against `v_evidence_search` silently loses recall. One ALTER ROLE; impact is enormous. (A)
2. **Replace single-leg vector retrieval with three-way RRF (vector + tsvector + pg_trgm) at k=60.** Anthropic measured a 49% retrieval-failure drop from hybrid; adding a reranker on top pushes it to 67%. (A)
3. **`COMMENT ON` every schema, table, and column.** Agents using `execute_sql` write drastically better queries when they can read `pg_description`. Highest ROI / lowest effort line item in this entire report. (A)
4. **Log every agent query into `ops_search_agent.query_log`.** Drift, hallucination, and cost blowouts are invisible without it. Add it before the first head goes live on the new stack. (C)
5. **Self-host BGE-reranker-v2-m3 (Apache 2.0, 568M params, ~2GB VRAM fp16) as an opt-in MCP `rerank` tool.** Reranking on top of hybrid is where the recall lift compounds; cross-encoder reranking is the single biggest signal-quality lever after switching to hybrid. (A/B)

Everything else in this document is the structure that makes those five reliable at scale.

---

## 1. Architectural Decisions (Locked)

### 1.1 Schema-per-corpus, not single mega-table

Levi already does this; the right call is to keep it.

- pgvector HNSW comfort zone is **5-10M vectors per index**; mega-table forces a single global HNSW that hits the wall fast (B/C).
- `DROP SCHEMA case_foo CASCADE` is atomic; `DELETE FROM mega.chunks WHERE corpus_id='foo'` is slow, vacuum-heavy, breaks HNSW.
- Per-corpus index tuning becomes possible (halfvec on the big ones, full-vector on the small ones).
- The cost of schema-per-corpus is **drift between schemas**, not schema count. Section 2 fixes drift by freezing the DDL template.

### 1.2 No RLS

Single-application, single-user trust boundary. RLS evaluates policy expression on every row -- millions of extra plpgsql calls for zero security gain. Enforce at application layer (Filing Director / records officer). Document the decision in `__schema_meta`. (A)

Revisit only if the firm gets licensed to other investigators.

### 1.3 No mega-matview

Cross-schema search stays a regular `UNION ALL` view, not a matview, until the planner clearly bottlenecks (50M+ chunks). `REFRESH ... CONCURRENTLY` over 2.4M rows takes minutes; the regular view lets Postgres push predicates into each branch. (A)

### 1.4 Trigger-based audit log, not pgaudit

pgaudit dumps SQL strings to a flat log file. Evidence-grade litigation needs queryable before/after JSONB diffs. Trigger pattern keeps audit data co-located with the audited data, queryable from the same agents. (A)

### 1.5 Postgres-native graph layer, not Microsoft GraphRAG

Microsoft GraphRAG full-ingest at retail LLM rates costs thousands of dollars for Levi's corpus size. Build a lightweight `entities` + `entity_mentions` + `chunk_relations` layer in Postgres directly. Recursive CTEs handle 3-hop traversal at acceptable latency on the M.2/64GB box. Invest only after measuring queries that hybrid retrieval demonstrably cannot answer. (A/C)

---

## 2. Canonical Schema Template

Every new `case_*`, `corpus_*`, or `legal_*` schema is created from this template. Drift across schemas is what eats agent productivity; uniformity is the goal.

```sql
-- valor_corpus_template.sql -- run as: psql -f template.sql -v schema=case_foo
CREATE SCHEMA IF NOT EXISTS :"schema";
SET search_path TO :"schema", public;

-- Self-documentation. Required.
CREATE TABLE __schema_meta (
    key text PRIMARY KEY,
    value text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE __schema_meta IS
  'One row per metadata key. Required keys: ddl_template_version, corpus_type, owner_matter, embedding_model, embedding_dim, parser_version, created_at.';

INSERT INTO __schema_meta(key, value) VALUES
    ('ddl_template_version', '1'),
    ('created_at', now()::text);

-- One row per ingested file. SHA-256 is the dedupe key.
CREATE TABLE source_files (
    id              bigserial PRIMARY KEY,
    path            text NOT NULL,
    sha256          char(64) NOT NULL,
    size_bytes      bigint NOT NULL,
    mtime           timestamptz NOT NULL,
    mime            text,
    parser          text NOT NULL,         -- 'docling', 'marker', 'pymupdf', 'faster-whisper', ...
    parser_version  text NOT NULL,
    case_tag        text,
    corpus          text NOT NULL,
    discovered_at   timestamptz NOT NULL DEFAULT now(),
    last_ingested_at timestamptz,
    last_ingest_status text,                -- 'ok' | 'failed' | 'quarantined' | 'superseded'
    error_message   text,
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
    deleted_at      timestamptz,
    CONSTRAINT source_files_sha256_unique UNIQUE (sha256)
);
CREATE INDEX source_files_ingested_at_idx ON source_files (last_ingested_at);
CREATE INDEX source_files_status_idx ON source_files (last_ingest_status) WHERE last_ingest_status <> 'ok';
CREATE INDEX source_files_metadata_gin  ON source_files USING gin (metadata jsonb_path_ops);
COMMENT ON TABLE source_files IS
  'One row per ingested file. sha256 is the dedupe key. status=ok means chunks were successfully written; failed files stay so re-ingestion is a no-op.';

-- The vector + FTS + trigram retrieval table.
CREATE TABLE chunks (
    id                  bigserial PRIMARY KEY,
    source_file_id      bigint NOT NULL REFERENCES source_files(id) ON DELETE CASCADE,
    chunk_idx           int NOT NULL,
    chunk_sha256        char(64) NOT NULL,
    content             text NOT NULL,
    content_tsv         tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
    embedding           halfvec(1024),                 -- halfvec by default; full vector only when justified
    embedding_model     text NOT NULL,
    embedding_model_version text NOT NULL,
    embedding_dims      int NOT NULL,
    chunk_method        text NOT NULL,                 -- 'docling_hybrid', 'voyage_context_3', 'anthropic_contextual', 'fixed_512'
    chunk_method_params jsonb,
    context_prefix      text,                          -- Anthropic-style prepended context, if used
    context_model       text,
    parent_chunk_ids    bigint[],                       -- RAPTOR / hierarchical
    page_number         int,
    bbox                jsonb,                          -- {x0,y0,x1,y1} for PDFs
    byte_range_start    bigint,
    byte_range_end      bigint,
    char_range_start    int,
    char_range_end      int,
    metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
    ingested_at         timestamptz NOT NULL DEFAULT now(),
    ingest_run_id       uuid NOT NULL,
    ingested_by_version text NOT NULL,
    deleted_at          timestamptz,
    CONSTRAINT chunks_unique UNIQUE (source_file_id, chunk_sha256)
);

-- Partial indexes so soft-deleted rows never enter the working set.
CREATE INDEX chunks_content_tsv_gin  ON chunks USING gin (content_tsv) WHERE deleted_at IS NULL;
CREATE INDEX chunks_content_trgm_gin ON chunks USING gin (content gin_trgm_ops) WHERE deleted_at IS NULL;
CREATE INDEX chunks_metadata_gin     ON chunks USING gin (metadata jsonb_path_ops) WHERE deleted_at IS NULL;
CREATE INDEX chunks_source_file_idx  ON chunks (source_file_id) WHERE deleted_at IS NULL;
-- HNSW created AFTER bulk load (see Section 4.4):
-- CREATE INDEX chunks_embedding_hnsw ON chunks USING hnsw (embedding halfvec_cosine_ops)
--   WITH (m = 24, ef_construction = 100) WHERE deleted_at IS NULL;

COMMENT ON TABLE chunks IS
  'Embeddings + FTS + trigram. content_tsv is a stored generated column. halfvec by default for 2x storage savings with identical recall. HNSW built post-load. Soft-delete only.';
COMMENT ON COLUMN chunks.embedding IS
  'halfvec(1024). Cosine HNSW. Query: ORDER BY embedding <=> $1::halfvec(1024). Soft-deleted rows excluded via partial index.';
COMMENT ON COLUMN chunks.embedding_model IS
  'Model name as written by the embedder. Mixing models in one column requires per-row filtering on this column at query time.';
COMMENT ON COLUMN chunks.metadata IS
  'JSONB. Holds parser-specific fields (page, section, doc_type, exhibit_ref, etc.). Promote to flat columns when filtered >5x/week. GIN with jsonb_path_ops.';

-- Named-entity registry (deduped via canonical_id self-FK).
CREATE TABLE entities (
    id           bigserial PRIMARY KEY,
    name         text NOT NULL,
    type         text NOT NULL,                 -- person | org | location | date | case | docket | statute | other
    canonical_id bigint REFERENCES entities(id),
    embedding    halfvec(1024),                 -- for fuzzy entity match
    metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT entities_name_type_unique UNIQUE (name, type)
);
CREATE INDEX entities_canonical_idx ON entities (canonical_id) WHERE canonical_id IS NOT NULL;
CREATE INDEX entities_type_idx      ON entities (type);
CREATE INDEX entities_name_trgm     ON entities USING gin (name gin_trgm_ops);

-- Chunk -> entity edges (preserves provenance; do not dedupe across extractors).
CREATE TABLE entity_mentions (
    id         bigserial PRIMARY KEY,
    chunk_id   bigint NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
    entity_id  bigint NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
    span_start int,
    span_end   int,
    confidence real,
    extractor  text NOT NULL,                   -- 'spacy_en_core_web_lg' | 'llm_gpt5_pro' | etc
    metadata   jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX entity_mentions_chunk_idx  ON entity_mentions (chunk_id);
CREATE INDEX entity_mentions_entity_idx ON entity_mentions (entity_id);

-- Directed graph edges between chunks (cites, replies_to, attaches, references, supersedes).
CREATE TABLE chunk_relations (
    id           bigserial PRIMARY KEY,
    src_chunk_id bigint NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
    dst_chunk_id bigint NOT NULL REFERENCES chunks(id) ON DELETE CASCADE,
    relation     text NOT NULL,
    confidence   real,
    weight       double precision DEFAULT 1.0,
    metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT chunk_relations_unique UNIQUE (src_chunk_id, dst_chunk_id, relation)
);
CREATE INDEX chunk_relations_src_idx ON chunk_relations (src_chunk_id);
CREATE INDEX chunk_relations_dst_idx ON chunk_relations (dst_chunk_id);
CREATE INDEX chunk_relations_rel_idx ON chunk_relations (relation);

-- Dead-letter queue. Agents query this to know what's broken.
CREATE TABLE ingest_errors (
    id              bigserial PRIMARY KEY,
    abs_path        text NOT NULL,
    file_sha256     bytea,
    stage           text NOT NULL,             -- 'fingerprint' | 'parse' | 'chunk' | 'embed' | 'insert'
    parser          text,
    parser_version  text,
    error_class     text NOT NULL,             -- 'EncryptedPDF' | 'CorruptZip' | 'OCRTimeout' | 'OOM' | ...
    error_message   text NOT NULL,
    stack_trace     text,
    retry_count     int NOT NULL DEFAULT 0,
    next_retry_at   timestamptz,
    first_seen_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now(),
    resolved_at     timestamptz,
    resolution_note text
);
CREATE INDEX ingest_errors_unresolved ON ingest_errors (next_retry_at) WHERE resolved_at IS NULL;
CREATE INDEX ingest_errors_class      ON ingest_errors (error_class)    WHERE resolved_at IS NULL;

-- Append-only audit log (one per schema). See Section 7.
CREATE TABLE audit_log (
    id           bigserial PRIMARY KEY,
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    actor        text NOT NULL,
    action       text NOT NULL,
    target_table text NOT NULL,
    target_pk    bigint,
    before       jsonb,
    after        jsonb,
    metadata     jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX audit_log_occurred_at_idx ON audit_log (occurred_at);
CREATE INDEX audit_log_target_idx      ON audit_log (target_table, target_pk);
CREATE INDEX audit_log_actor_idx       ON audit_log (actor);
```

**Conventions baked in**:

- `bigserial` PK everywhere.
- `metadata jsonb NOT NULL DEFAULT '{}'::jsonb` on every table.
- Timestamps end in `_at` and are `timestamptz`.
- All search-relevant indexes are partial on `deleted_at IS NULL` so tombstoned rows never enter the working set.
- `halfvec(1024)` is the default embedding type; bump to `vector(...)` only when a specific model demands it.
- HNSW is created post-load, not in the template.

---

## 3. Ingestion Pipeline

### 3.1 Parser cascade by file type

```
PDF -> PyMuPDF speed-check
  |-- native text, no images, no tables -> PyMuPDF text + simple chunk
  |-- tables / images / layout -> Docling -> DoclingDocument -> HybridChunker
  |-- Docling fails OR scanned -> Marker --use_llm --force_ocr (Surya OCR underneath)
  |-- Marker fails -> Surya direct + manual chunk
  |-- still fails -> ingest_errors DLQ row + alert

.eml -> email stdlib + email.policy.default + quoted-printable decode
        -> headers to source_files.metadata
        -> body chunked normally
        -> participants extracted into entities

.docx -> Docling (NOT python-docx unless editing)

.mp3/.wav/.m4a -> WhisperX (faster-whisper + pyannote diarization)
        -> chunk by speaker-turn boundaries, not fixed-token

HTML -> trafilatura (primary), readability-lxml fallback
```

**Reject from the stack**: LlamaParse (cloud-only; data retention risk on sealed records), unstructured.io OSS (vendor admits significantly decreased quality vs paid tier), pdfplumber (subsumed by Docling), Nougat (unmaintained).

Confidence: A on Docling/Marker/Surya/faster-whisper/pyannote numbers; B on relative rankings.

### 3.2 Chunking

The 2026 hierarchy, worst to best:

1. Fixed-character chunks
2. Fixed-token + overlap
3. Recursive character chunking (LangChain `RecursiveCharacterTextSplitter`)
4. Layout-aware (Docling HybridChunker, Marker chunk output)
5. Semantic chunking
6. **Late chunking** (Jina v3) -- pass full doc through long-context embedder, then mean-pool token embeddings into chunks. BEIR NFCorpus 23.46 -> 29.98 nDCG@10 vs naive
7. **Anthropic Contextual Retrieval** -- prepend 50-100 token LLM-generated context to each chunk before embedding. 5.7% -> 1.9% failure rate combined with BM25 + rerank
8. **voyage-context-3** -- single neural pass produces contextualized chunks. Beats Anthropic CR by +6.76%, OpenAI v3-large by +14.24%

**Pick one of 7 or 8. Not both.** They solve the same problem.

For Valor's mix (sealed records: case_bingaman_dhs, case_26cv11493, McSherry; non-sealed: VRE / OSINT):

- **Sealed corpora**: self-host. Use Docling HybridChunker (512 tokens, boundary-aligned) + Qwen3-Embedding-8B (Apache 2.0, MTEB multilingual 70.58). Anthropic contextual retrieval with local Claude Haiku via API only if the corpus is genuinely sealed-but-non-privileged.
- **Public corpora**: voyage-context-3 via API ($0.18/M tokens). Single-pass contextualization beats the prompt-cache trick.

Chunk size: 512 tokens with 10% overlap on heading boundaries by default. With a reranker in the pipeline, 1024 tokens is fine (reranker handles precision). With late chunking or contextual retrieval, overlap is unnecessary.

Confidence: A on numbers; B on the per-corpus self-host vs API decision (depends on Levi's appetite for self-host ops).

### 3.3 Embedding model selection (2026 short list)

| Model | MTEB Avg | Dims | Context | License | Cost | When |
|---|---|---|---|---|---|---|
| voyage-context-3 | not on MTEB v2 | 2048/1024/512/256 Matryoshka | 32K | API | $0.18/M | Public corpora, contextualized single pass |
| voyage-3-large | 70.32 | 1024/2048 Matryoshka | 32K | API | $0.18/M | Public, no context prep |
| **Qwen3-Embedding-8B** | 70.58 multilingual | 4096 (Matryoshka -> 1024) | 32K | Apache 2.0 | self-host | **Sealed corpora primary** |
| Cohere embed-v4 | 65.2 | 1536 | 128K | API | $0.10/M | Cheapest API |
| OpenAI text-embedding-3-large | 64.6 | 3072 (Matryoshka -> 256) | 8K | API | $0.13/M | Baseline; current state |
| BGE-M3 | 63.0 | 1024 | 8K | MIT | self-host | Hybrid dense+sparse+multi-vector |
| Nomic Embed v2 | ~62 | 768 (Matryoshka 64-768) | 8K | Apache 2.0 | self-host | CPU / edge |

**FinMTEB caveat**: 2025 study of 15 models across 64 financial datasets found statistically insignificant correlation between MTEB rankings and domain-specific retrieval. For legal/medical work, run a 50-query gold set on Levi's corpus before committing.

**Matryoshka pattern in Postgres**: store `embedding_full halfvec(2048)` AND `embedding_search vector(512)` (truncated + L2-normalized). HNSW indexes `embedding_search`; final rerank uses `embedding_full`. Halves hot index size.

### 3.4 Provenance columns (mandatory)

Every chunk row carries: `parser`, `parser_version`, `chunk_method`, `chunk_method_params`, `embedding_model`, `embedding_model_version`, `embedding_dims`, `context_prefix`, `context_model`, `chunk_sha256`, `ingested_at`, `ingest_run_id`, `ingested_by_version`, `deleted_at`. The canonical DDL in Section 2 enforces this.

Why each one matters from the agent's POV: full table in `postgres_ai_ingest_pipeline.md` section 4.2.

### 3.5 Idempotency

```text
For each candidate file under the corpus root:
  1. Look up source_files row by abs_path.
  2. If row exists AND (size, mtime) match the stored values: SKIP. Record nothing.
  3. Else: compute sha256.
     a. If sha256 matches stored: UPDATE mtime only. SKIP chunking.
     b. If sha256 differs:
        i.  UPDATE chunks SET deleted_at=now() WHERE source_file_id=X.
        ii. Run parser -> chunks -> embeddings.
        iii. INSERT new chunks (ON CONFLICT (source_file_id, chunk_sha256) DO UPDATE).
  4. If file no longer present on disk: UPDATE source_files SET deleted_at=now(); cascade.
```

Chunk-level dedupe via `UNIQUE (source_file_id, chunk_sha256)` means re-running the ingester after small text edits only re-embeds the changed chunks.

### 3.6 Soft-delete + HNSW reality check

**Critical (A, percona.com via Gemini)**: HNSW does not support incremental background updates. Soft-deleted vectors remain in the graph until REINDEX. Mitigations:

- Partial HNSW: `... WHERE deleted_at IS NULL` (template enforces this).
- Track churn ratio. If `count(deleted_at IS NOT NULL) / count(*) > 0.20`, force `REINDEX INDEX CONCURRENTLY chunks_embedding_hnsw`.
- Schedule a weekly REINDEX during low-traffic.

### 3.7 Failure modes -> `ingest_errors` DLQ

Tracked in-schema. Common classes Levi will hit: `EncryptedPDF`, `CorruptPDF`, `OCRTimeout`, `LayoutTooComplex`, `EmbeddingAPIError`, `OOMKill`, `ContextWindowExceeded`, `EmlMalformed`, `AudioCorrupt`. Full handling table in `postgres_ai_ingest_pipeline.md` section 6.2.

The agent can answer "do I have full coverage of the Bingaman corpus?" by joining `source_files` (case_tag) against `ingest_errors` (unresolved).

---

## 4. Vector Indexing (pgvector 0.8.2)

### 4.1 HNSW is the only correct choice

- Insert-safe (no rebuild after large insert)
- Better recall at every QPS than IVFFlat (Jonathan Katz benchmarks)
- 3-6x query throughput at the same recall (Supabase benchmark)

IVFFlat exists only for faster bulk-build at the cost of recall and dynamic inserts. Skip it.

### 4.2 Parameter cheat sheet

| Corpus size | Index | m | ef_construction | ef_search (runtime) | Iterative scan |
|---|---|---|---|---|---|
| <=10K chunks | exact (no index) or HNSW | 16 | 64 | 40 | off |
| 100K | HNSW | 16 | 64 | 80-100 | on (relaxed) |
| 1M | HNSW | 24 | 100 | 100-200 | on (relaxed) |
| 10M+ | HNSW + halfvec, or pgvectorscale StreamingDiskANN | 32 | 128-200 | 200-400 | on (relaxed) + partitioning |

`m` and `ef_construction` are build-time. `ef_search` is a per-session runtime knob -- always bump that first before rebuilding.

Build memory: `SET maintenance_work_mem = '8GB'; SET max_parallel_maintenance_workers = 7;`. If the graph spills to disk during build, build time blows up 10-30x.

### 4.3 Iterative index scan (THE 0.8 feature)

**Before 0.8**, every WHERE-filtered vector query was a recall lottery: HNSW returned top `ef_search` candidates by vector distance, THEN filtered. If only 3 of 40 happened to match the WHERE, you got 3 results back -- not the actual top-10 in that subset.

**Levi's cross-schema queries on `v_evidence_search` are silently broken without iterative scan.**

Fix:

```sql
ALTER ROLE valor_agent SET hnsw.iterative_scan = 'relaxed_order';
ALTER ROLE valor_agent SET hnsw.max_scan_tuples = 50000;
```

`relaxed_order` is the right default for an LLM agent workload -- a 5-10% reorder among top-K is invisible to a downstream reranker or LLM. `strict_order` only when pagination/threshold cutoffs need monotonic distance.

For very selective WHERE clauses (`schema_name = X AND date > Y`), bump `max_scan_tuples` to 50000-100000. Default 20000 is fine for schema-only filters.

### 4.4 halfvec is the free lunch

Jonathan Katz benchmark (1M @ 1536 dim, ef_search=40, A):

| Metric | `vector` (float32) | `halfvec` (float16) |
|---|---|---|
| Storage | baseline | 2.0x smaller |
| Recall@10 | 96.8% | 96.8% (identical) |
| QPS | 567 | 578 |
| Build time | baseline | 2.31x faster |

**Pattern: halfvec for the index, full vector available for rerank.**

```sql
ALTER TABLE chunks ADD COLUMN embedding vector(1024);
CREATE INDEX ON chunks
  USING hnsw ((embedding::halfvec(1024)) halfvec_cosine_ops)
  WITH (m = 24, ef_construction = 100)
  WHERE deleted_at IS NULL;

-- Search via halfvec, rerank top-K with full vector
WITH ann AS MATERIALIZED (
  SELECT id, content, embedding,
         embedding::halfvec(1024) <=> $1::halfvec(1024) AS approx_dist
  FROM chunks
  ORDER BY approx_dist
  LIMIT 100
)
SELECT id, content, embedding <=> $1 AS exact_dist
FROM ann
ORDER BY exact_dist
LIMIT 10;
```

### 4.5 Binary quantization -- NOT for Levi

Katz at 1536-dim dbpedia with reranking: 16.35x storage savings BUT recall@10 drops to 91.6%. Without reranking, recall is 0%. For an LLM agent that needs the SPECIFIC chunk for a citation, 5 missing recall points is malpractice-tier. Skip binary.

### 4.6 Distance metric is decided by the embedding model, not by preference

| Operator | Distance | Use |
|---|---|---|
| `<->` | L2 | Model docs say "L2" |
| `<=>` | Cosine | Safe default for any text embedding |
| `<#>` | Negative inner product | Pre-normalized models (slight perf win) |
| `<+>` | L1 | Niche |
| `<~>` | Hamming | `bit` only |

Norm-check before turning on inner product:

```sql
SELECT schema_name, COUNT(*), AVG(SQRT(embedding <#> embedding * -1)) AS avg_norm
FROM chunks GROUP BY schema_name;
```

If `avg_norm ~ 1.0` with tiny stddev, use `<#>`. Otherwise `<=>`. OpenAI text-embedding-3-* is pre-normalized (use `<#>`); Voyage and Cohere don't state explicitly -- verify per column.

### 4.7 Maintenance loop

- `REINDEX INDEX CONCURRENTLY chunks_embedding_hnsw` THEN `VACUUM (VERBOSE, ANALYZE) chunks`. (Reverse order: vacuum-on-degraded-HNSW is slow.)
- Trigger REINDEX on: (a) >10% bulk insert, (b) churn ratio >20%, (c) recall regression >2pp, (d) quarterly.
- Monitor build via `pg_stat_progress_create_index`.
- Recall harness: nightly cron pulls 100 known-good (query, expected_chunk_id) pairs across schemas; writes recall@10 to `ops_records_officer.index_health`; alert (Filing Director task) on regression.

Autovacuum tuning for embedding-heavy tables:

```sql
ALTER TABLE chunks SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.02
);
```

---

## 5. Retrieval (Hybrid + RRF + Rerank)

### 5.1 Three-way RRF (vector + tsvector + pg_trgm)

Vector misses proper nouns, dates, statute citations. tsvector misses paraphrases. Trigram catches OCR noise and misspellings. RRF at k=60 (Cormack/Clarke/Buettcher 2009; pgvector-python canonical) fuses them without normalization.

```sql
SET hnsw.iterative_scan = 'relaxed_order';

WITH semantic AS MATERIALIZED (
  SELECT id, RANK() OVER (ORDER BY embedding <=> $1) AS r
  FROM chunks
  WHERE deleted_at IS NULL AND schema_name = ANY($2)
  ORDER BY embedding <=> $1
  LIMIT 30
),
fts AS MATERIALIZED (
  SELECT id, RANK() OVER (ORDER BY ts_rank_cd(content_tsv, q) DESC) AS r
  FROM chunks, plainto_tsquery('english', $3) q
  WHERE deleted_at IS NULL AND schema_name = ANY($2) AND content_tsv @@ q
  ORDER BY ts_rank_cd(content_tsv, q) DESC
  LIMIT 30
),
trgm AS MATERIALIZED (
  SELECT id, RANK() OVER (ORDER BY similarity(content, $3) DESC) AS r
  FROM chunks
  WHERE deleted_at IS NULL AND schema_name = ANY($2) AND content % $3
  ORDER BY similarity(content, $3) DESC
  LIMIT 30
)
SELECT
  COALESCE(s.id, f.id, t.id) AS id,
  COALESCE(1.0/(60+s.r), 0) + COALESCE(1.0/(60+f.r), 0) + COALESCE(1.0/(60+t.r), 0) AS score
FROM semantic s
  FULL OUTER JOIN fts f USING (id)
  FULL OUTER JOIN trgm t USING (id)
ORDER BY score DESC
LIMIT 10;
```

`MATERIALIZED` keeps each leg honest (planner won't fold the iterative scan).

For Valor's evidence corpus, default to equal weighting (1.0 / 1.0 / 1.0). Supabase weights full-text 1.5x for proper-noun-heavy data -- worth A/B testing against an eval set. Don't tune blind.

### 5.2 Candidate set sizing

Anthropic: retrieve 150 -> rerank to top-20.
Voyage: 100 -> top-10.
Pinecone: 25 -> top-3.

**Valor recommendation: 100 candidates pre-rerank, top-20 post-rerank.** Matches Voyage methodology, stays under cross-encoder latency budgets, fits comfortably under context-window limits.

### 5.3 Reranking

Recommended: **self-host BGE-reranker-v2-m3** (Apache 2.0, 568M params, ~2GB VRAM fp16). Scores 100 query-doc pairs in 100-300ms on a consumer GPU.

Fallback for court-bound output: **Voyage Rerank-2 API** (+13.89% over OpenAI v3-large on 93 datasets, Anthropic uses it for their published 67% number).

Expose as a separate MCP tool -- `rerank(query, docs[], model='bge-v2-m3')`. Don't bake into `hybrid_search` mandatorily; let the agent opt in.

Skip reranking for: trivial lookups, internal agent loops where the agent is the reranker, sub-100ms latency targets.

---

## 6. MCP Tool Surface (the agent's view of the DB)

Expose **6 retrieval tools** + **2 introspection tools** + **2 system tools** = 10 tools, ~3K tokens of definitions. Anything more eats context (one analysis: stacked MCPs can burn 41% of a 200K window before first user message).

| Tool | Args | Returns | Notes |
|---|---|---|---|
| `semantic_search` | query, top_k=20, corpus?, filters? | ranked chunks | pgvector cosine, HNSW |
| `keyword_search` | terms[], corpus?, filters?, top_k=20 | ranked chunks | tsvector + ts_rank_cd |
| `hybrid_search` | query, top_k=20, corpus?, weights? | ranked chunks | three-way RRF k=60 |
| `rerank` | query, chunks[], model='bge-v2-m3' | reordered chunks | opt-in |
| `get_full_doc` | doc_id OR file_path | all chunks for one source | for "show me the whole thing" |
| `evaluate_retrieval` | query, chunks[] | {confidence, reason} | CRAG-style signal |
| `list_corpora` | -- | corpus names + chunk counts + last_ingested_at | what's available |
| `describe_schema` | table? | table + column comments | reads pg_description |
| `execute_sql` | sql | rows, capped 100 | read-only transaction; escape hatch |
| `database_stats` | -- | row counts, last update, index health, session scorecard | observability |

### 6.1 Why split semantic / keyword / hybrid

Hybrid is the right default, but the agent should be able to force a leg. Proper-noun queries (case numbers, names, statute citations) often beat hybrid with pure keyword. Conceptual queries the reverse. Let the agent decide.

### 6.2 Result envelope (every tool returns this shape)

```json
{
  "chunk_id": "case_26cv11493:14_filings/2025-04-03_complaint.pdf#7",
  "citation": "[case_26cv11493:14_filings/2025-04-03_complaint.pdf#7]",
  "snippet": "<= 500 tokens, sentence-bounded, **bolded** matches",
  "source_path": "/mnt/linux-storage/.../complaint.pdf",
  "chunk_idx": 7,
  "page_number": 12,
  "score": 0.847,
  "score_components": {"semantic": 0.91, "fts": 0.43, "trgm": 0.62, "rrf": 0.0254},
  "metadata": {"corpus": "case_26cv11493", "filed_date": "2025-04-03", "doc_type": "complaint"}
}
```

Citation format `[corpus:schema/file#chunk_idx]` is deterministic, self-describing, parsable via `\[([\w_]+):([^#\]]+)#(\d+)\]`, and short (<100 chars).

### 6.3 Pagination and context economics

- Default `top_k=20`, hard ceiling 50.
- Each result ~500 tokens snippet + 100 tokens metadata -> top_k=20 = ~12K tokens per tool call.
- If agent requests top_k=200, return top_k=20 + `next_cursor` token; agent drills deeper on follow-up.

### 6.4 `execute_sql` is the escape hatch, not the default

Curated tools hide pgvector syntax. Raw SQL forces the agent to handle schema introspection, type casting, parameter escaping. Cap row count at 100. Run in a read-only transaction. Use only for cross-table joins, aggregations, or schema exploration the curated tools don't cover.

The agent writes drastically better `execute_sql` when `describe_schema` returns the column comments from Section 7.

---

## 7. The `COMMENT ON` Pattern

Highest-ROI / lowest-effort change in the entire playbook. Agents read comments via `pg_description` and write correct SQL on first try.

### 7.1 Comment style for agent consumption

```sql
COMMENT ON SCHEMA case_bingaman_dhs IS
  'Russell Bingaman / Patricia Bingaman v. DHS records. Linked matters: 23PR02271 (guardianship), 26CV11493 (Bakke v ODHS dismissed without prejudice). Owner: levi. DDL template v1.';

COMMENT ON TABLE case_26cv11493.chunks IS
  'Chunked text from filings, exhibits, and orders in Bakke v. ODHS '
  '(Marion County 26CV11493, dismissed without prejudice 2026-05). '
  '28,463 chunks across 1,257 source files. Use for refile-prep evidence retrieval. '
  'Hybrid retrieval: semantic (HNSW cosine), FTS (tsvector GIN), trigram (pg_trgm GIN).';

COMMENT ON COLUMN case_26cv11493.chunks.embedding IS
  'halfvec(1024) cosine HNSW. Model: voyage-context-3 (or text-embedding-3-large for legacy rows). '
  'Query: ORDER BY embedding <=> $1::halfvec(1024). Filter via partial index on deleted_at IS NULL.';

COMMENT ON COLUMN case_26cv11493.chunks.content_tsv IS
  'Generated tsvector from content via to_tsvector(''english'', ...). GIN-indexed. '
  'Query: WHERE content_tsv @@ websearch_to_tsquery($1).';

COMMENT ON COLUMN case_26cv11493.chunks.metadata IS
  'JSONB with parser-specific keys: page, section, doc_type, exhibit_ref, deponent, filed_date, page_range. '
  'GIN with jsonb_path_ops. Promote to flat column when filtered >5x/week.';
```

**Rule**: every column an agent might query gets a comment that names the data source, the index, and a one-line SQL example.

### 7.2 The introspection view

```sql
CREATE VIEW agent_schema_doc AS
SELECT
  n.nspname AS schema_name,
  c.relname AS table_name,
  obj_description(c.oid, 'pg_class')      AS table_comment,
  a.attname                                AS column_name,
  format_type(a.atttypid, a.atttypmod)     AS data_type,
  col_description(a.attrelid, a.attnum)    AS column_comment
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid
WHERE c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
  AND n.nspname NOT IN ('pg_catalog','information_schema');
```

`describe_schema` MCP tool selects from this view. The agent caches the result once per session -- it's the map of the database.

### 7.3 Make it deployable

Store all `COMMENT ON` in `schema_comments.sql` checked into the same repo as migrations. Re-apply on every migration. Otherwise comments rot.

---

## 8. Observability (agent query log)

Agent drift, hallucination, and cost blowouts are invisible without logging. Add this before the first head goes live on the new stack.

```sql
CREATE TABLE IF NOT EXISTS ops_search_agent.query_log (
  id              BIGSERIAL PRIMARY KEY,
  ts              TIMESTAMPTZ NOT NULL DEFAULT now(),
  session_id      TEXT NOT NULL,
  agent_id        TEXT NOT NULL,                  -- 'claude_code' | 'codex' | 'firm.records_officer'
  tool_name       TEXT NOT NULL,
  args            JSONB NOT NULL,
  result_count    INTEGER,
  result_chunk_ids TEXT[],
  latency_ms      INTEGER,
  cache_hit       BOOLEAN DEFAULT FALSE,
  rerank_used     BOOLEAN DEFAULT FALSE,
  rerank_model    TEXT,
  confidence      DOUBLE PRECISION,               -- CRAG-style retrieval evaluator
  downstream_use  TEXT,                            -- 'cited_in_filing' | 'discarded' | 'rewritten'
  privilege_flag  BOOLEAN DEFAULT FALSE,           -- privileged material in result set
  error           TEXT
);

CREATE INDEX query_log_session_idx ON ops_search_agent.query_log (session_id, ts);
CREATE INDEX query_log_agent_idx   ON ops_search_agent.query_log (agent_id, ts);
CREATE INDEX query_log_tool_idx    ON ops_search_agent.query_log (tool_name, ts);
CREATE INDEX query_log_args_gin    ON ops_search_agent.query_log USING gin (args);
```

Derived view the agent reads about its own performance:

```sql
CREATE VIEW ops_search_agent.session_quality AS
SELECT session_id, agent_id,
       COUNT(*) AS n_queries,
       AVG(confidence) AS avg_confidence,
       SUM((downstream_use = 'discarded')::int)::float / COUNT(*) AS discard_rate,
       AVG(latency_ms) AS avg_latency_ms
FROM ops_search_agent.query_log
GROUP BY session_id, agent_id;
```

Expose via `database_stats`. CRAG-style self-correction loops converge faster with a numeric feedback signal.

`privilege_flag` is Valor-specific: any chunk from `case_bingaman_dhs` or `case_26cv11493` containing attorney-client privileged material gets flagged so the records officer can sweep before disclosure.

---

## 9. Append-Only Audit (per schema)

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
    CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) ELSE NULL END,
    CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) ELSE NULL END,
    jsonb_build_object('txid', txid_current())
  );
  RETURN COALESCE(NEW, OLD);
END;
$$;

CREATE TRIGGER chunks_audit       AFTER INSERT OR UPDATE OR DELETE ON chunks       FOR EACH ROW EXECUTE FUNCTION audit_row_change();
CREATE TRIGGER source_files_audit AFTER INSERT OR UPDATE OR DELETE ON source_files FOR EACH ROW EXECUTE FUNCTION audit_row_change();
CREATE TRIGGER entities_audit     AFTER INSERT OR UPDATE OR DELETE ON entities     FOR EACH ROW EXECUTE FUNCTION audit_row_change();
```

Agent transactions set the actor:

```sql
SET LOCAL valor.actor = 'agent:filing_director';
```

Litigation-grade hardening (for evidence corpora):

1. **WAL archiving to immutable storage** (GCS Bucket Lock or S3 Object Lock). Restores tampered audit state.
2. **Periodic export to append-only filesystem**: `pg_dump --schema=*audit_log* | gpg --sign > /immutable/audit-YYYY-MM-DD.sql.gpg` daily.
3. Optional: application-layer hash chaining (each row carries `hash(prev_hash || canonical_json)`). Nice-to-have, not load-bearing.

---

## 10. Cross-Schema Search View (auto-rebuilding)

Replace the hand-maintained `v_evidence_search` with a registry + event trigger that auto-rebuilds when a new corpus schema is created.

```sql
CREATE TABLE ops_records_officer.corpus_registry (
  schema_name        text PRIMARY KEY,
  corpus_type        text NOT NULL,           -- 'case' | 'corpus' | 'legal' | 'ops'
  owner_matter       text,
  embedding_model    text,
  embedding_dim      int,
  included_in_search boolean NOT NULL DEFAULT true,
  registered_at      timestamptz NOT NULL DEFAULT now(),
  metadata           jsonb NOT NULL DEFAULT '{}'::jsonb
);

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
      'SELECT %L::text AS schema_name, c.id, c.source_file_id, c.chunk_idx, '
      'c.content, c.content_tsv, c.embedding, c.embedding_model, '
      'c.metadata, c.ingested_at FROM %I.chunks c WHERE c.deleted_at IS NULL',
      rec.schema_name, rec.schema_name
    ));
  END LOOP;
  EXECUTE 'DROP VIEW IF EXISTS ops_records_officer.v_evidence_search';
  EXECUTE 'CREATE VIEW ops_records_officer.v_evidence_search AS '
       || array_to_string(sql_parts, ' UNION ALL ');
END;
$$;

CREATE OR REPLACE FUNCTION ops_records_officer.on_corpus_schema_created()
RETURNS event_trigger LANGUAGE plpgsql AS $$
DECLARE obj record;
BEGIN
  FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    WHERE command_tag = 'CREATE SCHEMA'
  LOOP
    IF obj.object_identity ~ '^(case_|corpus_|legal_)' THEN
      INSERT INTO ops_records_officer.corpus_registry(schema_name, corpus_type)
      VALUES (obj.object_identity, split_part(obj.object_identity, '_', 1))
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

`CREATE SCHEMA case_eckstein` now auto-registers and auto-rebuilds the view. Remove a corpus from search: `UPDATE corpus_registry SET included_in_search = false WHERE schema_name = '...'; SELECT rebuild_v_evidence_search();`

Upgrade to a matview only if `EXPLAIN ANALYZE` shows view-parse time dominating index time -- at 2.4M rows that's not happening; revisit at 50M+.

---

## 11. Partitioning (defer until ~5M rows per corpus)

Don't partition until one corpus's `chunks` table crosses ~5M rows AND HNSW build memory is the bottleneck.

When the threshold trips:

| Workload | Partition strategy | Why |
|---|---|---|
| Time-series ingest (FOIA, news scrapes) | `RANGE (ingested_at)` monthly | Postgres 16+ partition pruning is O(1); old months detachable; HNSW-per-partition keeps build memory bounded |
| Many small sub-tenants | `HASH (source_file_id)` w/ 16-32 partitions | Even distribution; no skew |
| Few large fixed categories | `LIST (corpus_id)` | Only if categories stable |

HNSW + partitioning specifics:

- `CREATE INDEX ... ON parent_table` propagates to all current and future partitions.
- `CONCURRENTLY` is NOT supported on partitioned indexes directly. To rebuild: `CREATE INDEX ... ON ONLY parent` (marks invalid) -> `CREATE INDEX CONCURRENTLY ... ON each_partition` -> `ALTER INDEX parent ATTACH PARTITION partition_index`.
- Cross-partition vector query: each partition contributes K candidates, merger picks global top-K. Fine for top-K. Not fine for global-rank queries without a pruning predicate.

Practical partition count cap: 100-500. Monthly RANGE = 8-40 years. Plenty.

Install `pg_partman` extension before the first time you need partitioning.

---

## 12. Cost + Latency Targets (single box, 64GB, M.2 NVMe)

```ini
# postgresql.conf
shared_buffers = 16GB
effective_cache_size = 48GB
work_mem = 64MB
maintenance_work_mem = 4GB
max_parallel_workers_per_gather = 4
max_parallel_maintenance_workers = 8
random_page_cost = 1.1
effective_io_concurrency = 200
```

Expected single-query latency:

| Operation | Corpus | p50 | p95 |
|---|---|---|---|
| Semantic (HNSW, top_k=20) | 2M | 3-8 ms | 15-30 ms |
| Semantic (HNSW, top_k=20) | 10M | 8-20 ms | 30-60 ms |
| Semantic (HNSW, top_k=20) | 50M | 20-50 ms | 80-150 ms |
| Keyword (tsvector GIN) | any | 5-30 ms | 50-100 ms |
| Hybrid (3-way RRF, MATERIALIZED CTEs) | 10M | 15-40 ms | 60-120 ms |
| Add BGE-reranker-v2-m3, 100 docs | -- | +100-300 ms | +500 ms |

HNSW build at 10M chunks halfvec(1024): ~30-60 min wall clock with parallel maintenance.

One-time costs at current scale (300K chunks, ~150M tokens):

- Embeddings via OpenAI text-embedding-3-large: ~$20
- Anthropic contextual retrieval prep with prompt cache: ~$153
- Self-host Qwen3-Embedding-8B + BGE-reranker-v2-m3: $0 incremental

At 50M+ chunks: evaluate Tiger pgvectorscale StreamingDiskANN (28x lower p95 vs Pinecone s1 at 99% recall, 50M dataset, A).

---

## 13. Migration Plan for the Existing 37 Schemas

Ordered by leverage:

**Phase 1 (today, low-risk, agent-visible wins)**

1. Enable iterative HNSW scan on the agent role: `ALTER ROLE valor_agent SET hnsw.iterative_scan = 'relaxed_order';`
2. Add `corpus_registry` + `rebuild_v_evidence_search()` + event trigger. Backfill registry from existing schemas.
3. Add `ops_search_agent.query_log` + indexes.
4. Write `COMMENT ON` for `case_26cv11493`, `case_bingaman_dhs`, `corpus_oregon_public_records_filesystem` (the three workhorses). Dispatch to a worker to do the rest.
5. Create the `agent_schema_doc` view.
6. Ship the `describe_schema` and `list_corpora` MCP tools.

**Phase 2 (drift removal)**

1. Audit each schema's `chunks` / `source_files` DDL against the canonical template. Output drift report.
2. Bring schemas inside the canonical envelope: missing `metadata jsonb DEFAULT`, missing `content_tsv` generated column, missing `deleted_at`, missing partial indexes.
3. Add `__schema_meta` to every schema. Backfill from `migration` schema where possible.
4. Add `audit_log` + triggers to every schema (Phase 2b if churn is high during Phase 2a).

**Phase 3 (index modernization)**

1. Migrate `corpus_oregon_public_records_filesystem` (238K chunks) and any 100K+ schema to halfvec partial HNSW.
2. Add tsvector + trigram partial indexes to every `chunks` table.
3. Replace single-leg vector searches with 3-way RRF in `valor-rag` MCP server.
4. Bake nightly recall harness into `ops_records_officer`.

**Phase 4 (parser + chunker upgrade)**

1. Install Docling. Wire into the PDF path. PyMuPDF stays as speed gate.
2. Add Marker as Tier 2 PDF fallback (`--use_llm`).
3. Add WhisperX (faster-whisper + pyannote) for audio.
4. Add trafilatura for HTML.
5. Add `ingest_errors` DLQ to every schema. Wire into the ingester.

**Phase 5 (embedding + chunking upgrade)**

1. Pilot voyage-context-3 on a non-sealed corpus (VRE public docs).
2. Self-host Qwen3-Embedding-8B for sealed corpora. Migrate `case_26cv11493`, `case_bingaman_dhs`, McSherry first.
3. Add `embedding_v2` column alongside `embedding`; backfill in batch; swap index; drop old column.
4. Switch `chunks.embedding` to `halfvec` across the board.

**Phase 6 (advanced, when justified by measured gaps)**

1. RAPTOR summary trees per case.
2. Entity extraction layer + `chunk_relations` graph.
3. Partition any `chunks` table that crosses 5M rows.
4. Self-host BGE-reranker-v2-m3 + add `rerank` MCP tool.

---

## 14. What This Document Does NOT Cover

- **Cross-corpus entity resolution**. Today entities are per-schema. A global `ops_entities` registry with cross-schema FK is worth doing but is a separate design.
- **Backup / PITR strategy**. WAL archiving + point-in-time recovery for `valor_consolidated` is an ops doc, not this one.
- **Embedding model rotation**. The Phase 5 step covers the mechanic; the policy (when to rotate, how to validate) belongs in a separate doc.
- **Cross-database federation** (BigQuery `valor_investigations` <-> Postgres `valor_consolidated`). 27 BigQuery tables remain unmigrated as of 2026-05-19. For evidence-grade work, query both.
- **Specific embedding model benchmark on Valor's corpus**. MTEB ranks don't predict legal/medical retrieval quality; run a 50-query gold set before locking in a model.

---

## 15. Authoritative References (per-wave reports)

- `/mnt/linux-storage/research/waves/postgres_ai_vector_index.md` -- HNSW/IVFFlat parameters, iterative scan deep dive, halfvec benchmark numbers, RRF SQL, maintenance loop
- `/mnt/linux-storage/research/waves/postgres_ai_ingest_pipeline.md` -- parser cascade, chunking strategies (late chunking, contextual retrieval, voyage-context-3), embedding model decision tree, provenance columns, DLQ
- `/mnt/linux-storage/research/waves/postgres_ai_schema_design.md` -- schema-per-corpus rationale, canonical DDL, JSONB patterns, partitioning thresholds, cross-schema view, naming conventions, audit triggers
- `/mnt/linux-storage/research/waves/postgres_ai_agent_retrieval.md` -- MCP tool surface, hybrid + rerank pipeline, packaging chunks for agents, agentic loops, `COMMENT ON` pattern, query log, GraphRAG-in-Postgres
- `/mnt/linux-storage/research/waves/postgres_ai_*_gemini*.md` -- raw Gemini grounded-search outputs for citation traceback

---

**End of playbook.**
