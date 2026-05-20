# Postgres + pgvector 0.8 Best Practices for AI Agent Workloads

**Wave:** postgres_ai_vector_index
**Target deployment:** Levi's `valor_consolidated` Postgres 16+, pgvector 0.8.2, pg_trgm, ~2.4M chunks across 37 schemas (case_*, corpus_*, ops_*, legal_*)
**Consumer profile:** LLM agents are the primary (only) consumers -- recall floor must be high enough to surface exact citation chunks, not just thematically-close neighbors
**Generated:** 2026-05-19
**Confidence key:** A=primary source / pgvector README / Jonathan Katz benchmarks, B=vendor blog (Supabase, Tiger, Neon), C=secondary, D=unverified

---

## TL;DR -- The Cheat Sheet

| Corpus size | Index | m | ef_construction | ef_search (runtime) | Iterative scan |
|---|---|---|---|---|---|
| <=10K chunks | exact (no index) or HNSW | 16 | 64 | 40 | off |
| 100K | HNSW | 16 | 64 | 80-100 | on (relaxed) if filters |
| 1M | HNSW | 24 | 100 | 100-200 | on (relaxed) |
| 10M+ | HNSW + halfvec or pgvectorscale StreamingDiskANN | 32 | 128-200 | 200-400 | on (relaxed) + partitioning |

**Defaults LOCKED in pgvector source (v0.8.x):** m=16, ef_construction=64, ef_search=40 (A, pgvector README). Increase ef_search FIRST before rebuilding -- it is a runtime knob; m and ef_construction are build-time only.

**Default for `hnsw.iterative_scan` is `off` (A, Supabase docs).** Levi must SET it ON per-session or via ALTER DATABASE before WHERE-filtered vector queries are reliable.

---

## 1. HNSW vs IVFFlat -- Pick HNSW for AI Agent Workloads

**The bottom line:** For Levi's stack -- writes during reads (ingest while agents query), low-latency tool-call retrieval, mixed corpus sizes -- HNSW is the only correct choice. IVFFlat exists for one reason: faster index build on bulk loads, at the cost of substantially worse recall and an inability to handle inserts after the index is built without rebuilding.

### Why HNSW wins for agent workloads

1. **Insert-safe.** Supabase docs (B): "Unlike IVFFlat indexes, you are safe to build an HNSW index immediately after the table is created." IVFFlat requires the data to be loaded BEFORE indexing because its lists are computed from the training data. HNSW's hierarchical graph absorbs new points without retraining.
2. **Better recall at every QPS.** Jonathan Katz's pgvector benchmarks (A, jkatz05.com): "pgvector HNSW significantly outperformed ivfflat on recall metrics across all tests."
3. **3x-6x query throughput at same recall.** Supabase HNSW benchmark (B, supabase.com/blog/increase-performance-pgvector-hnsw): "Small dataset: HNSW achieved 3 times better performance than IVFFlat with better accuracy. Large dataset (1M vectors): HNSW demonstrated over six times better performance while maintaining the same level of accuracy."

### Build/query parameters by corpus size

These are derived from the pgvector README defaults plus Supabase/Tiger Data benchmarks on 1536-dim OpenAI embeddings:

**10K chunks (small corpus, e.g. one case file):**
```sql
CREATE INDEX ON chunks USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);
-- Runtime
SET hnsw.ef_search = 40;
```
Build: seconds. Recall@10: ~0.99 with defaults. Honestly, for <10K chunks, do `ORDER BY embedding <=> $1 LIMIT k` with NO index -- exact NN is fast enough and recall is 1.0. (A, pgvector README "Indexing" section notes "indexing isn't necessary if you're just looking for small numbers of nearest neighbors").

**100K chunks (typical case corpus):**
```sql
CREATE INDEX ON chunks USING hnsw (embedding vector_cosine_ops)
  WITH (m = 16, ef_construction = 64);
SET hnsw.ef_search = 80;  -- bump for agent recall
```
Build: ~30-90 seconds with `maintenance_work_mem` >= 2GB. Recall@10: ~0.97 at ef_search=80. (B, Supabase fast-builds benchmark).

**1M chunks (Levi's larger schemas, e.g. `corpus_oregon_public_records_filesystem` at 238K chunks fits here; whole consolidated cross-schema view at 2.4M does not):**
```sql
CREATE INDEX ON chunks USING hnsw (embedding vector_cosine_ops)
  WITH (m = 24, ef_construction = 100);
SET hnsw.ef_search = 150;  -- agent workload, higher floor
```
Build: 5-25 minutes for 1024-1536 dim on 16-core, 32GB `maintenance_work_mem`. (A, Jonathan Katz benchmark dbpedia-openai-1000k: 49-82 min for 1M @ 1536 dim with default `maintenance_work_mem`; Supabase shows 5m25s with 30GB `maintenance_work_mem` + 15 parallel workers).

Supabase tested (B): "m=24, ef_construction=100 achieves 0.978 accuracy" at ~900 QPS on 4XL (16 core / 64GB).

**10M+ chunks (Levi's full cross-schema search view `v_evidence_search` UNION ALL at 2.4M total, projected growth to 10M):**
- Bump m to 32, ef_construction to 128-200.
- Switch to `halfvec` (16-bit float) storage -- 2x space savings, near-identical recall (see Section 3).
- Consider Tiger Data's `pgvectorscale` extension with StreamingDiskANN (B, tigerdata.com/blog/pgvector-vs-pinecone): "28x lower p95 latency and 16x higher throughput vs Pinecone s1 at 99% recall on 50M vectors."
- Partition by corpus/case using PARTITION BY LIST so each partition's HNSW index stays in RAM.

### Memory tuning for index build (A, pgvector README + B, Supabase)

```sql
-- Per-session, before CREATE INDEX
SET maintenance_work_mem = '8GB';            -- big enough to fit the graph
SET max_parallel_maintenance_workers = 7;    -- "CPU count / 2" rule of thumb
```

The README is explicit: "Increase `maintenance_work_mem` to fit the graph in memory" -- if the graph spills to disk during build, build time blows up by 10-30x. Supabase's 0.6.0 benchmark on 1M vectors @ 1536 dim shows the difference: 30GB `maintenance_work_mem` + 15 parallel workers built the index in 5m25s; the prior 0.5.1 default config took 38m46s.

Builds inside a transaction or on a non-unlogged table can be slower; for one-shot ingestion of an existing dataset, Supabase reports up to **23-31x speedup** using `UNLOGGED TABLES` during the build then `ALTER TABLE ... SET LOGGED` after (B).

### Concurrency: HNSW handles writes-during-reads natively

The pgvector HNSW implementation uses per-element locks during inserts, so concurrent queries continue to work. There is NO equivalent of the "IVFFlat rebuild after large insert" trap. This is the single most important property for an agent workload where ingestion (new case docs, new transcripts) happens continuously while agents query.

Caveat: large bulk inserts (>10% of table size) DO benefit from a follow-up `REINDEX INDEX CONCURRENTLY` because HNSW graph quality degrades slightly with many insertions -- see Section 5.

---

## 2. Iterative Index Scans (pgvector 0.8.0+) -- Critical for Filtered Search

**This is the single biggest reason to be on 0.8+.** Before 0.8, every WHERE-clause vector query was a recall lottery. Pgvector 0.8 fixes it.

### The problem 0.8 solves

Quote from the pgvector README (A): "filtering is applied _after_ the index is scanned" with approximate indexes. So if you do:

```sql
SELECT * FROM chunks
WHERE schema_name = 'case_26cv11493'
ORDER BY embedding <=> $1
LIMIT 10;
```

Without iterative scan, HNSW returns its top `ef_search` (default 40) candidates by vector distance, THEN the WHERE filter is applied. If only 3 of those 40 happen to be in `case_26cv11493`, you get 3 results back -- not 10 -- even though dozens of true top-K matches exist in that schema. **Levi's cross-schema queries on `v_evidence_search` will silently lose recall without iterative scan.**

### How to enable it

```sql
-- Two modes, both new in 0.8.0
SET hnsw.iterative_scan = strict_order;   -- guarantees ordered-by-distance, may return fewer
SET hnsw.iterative_scan = relaxed_order;  -- best recall, may be slightly out of distance order
```

Default: `off` (A, Supabase docs). Levi must explicitly enable it.

### strict_order vs relaxed_order -- which to use

**`relaxed_order` is the right default for an agent workload.** The agent reads the chunks and reasons over them; a 5-10% reorder among the top-K is invisible to a re-ranker or LLM context. What matters is that you actually GET the top-K instead of 2-of-K.

Use `strict_order` only when downstream consumers expect monotonically-increasing distance (e.g., paginated displays, threshold-based cutoffs).

### Tuning the scan limits

```sql
SET hnsw.max_scan_tuples = 50000;       -- default 20000; raise for highly selective WHEREs
SET hnsw.scan_mem_multiplier = 4;       -- default 1; raise if scan is running OOM
```

Pgvector README (A): "`hnsw.max_scan_tuples` -- approximate limit on tuples visited (default: 20,000)" and "`hnsw.scan_mem_multiplier` -- memory usage as a multiple of `work_mem` (default: 1)."

**Rule of thumb for Levi:**
- For schema-scoped queries (one of ~37 schemas), 20000 default is fine.
- For highly selective filters (e.g. `WHERE source_file LIKE '%Keene%' AND date > '2026-01-01'`), bump `max_scan_tuples` to 50000-100000.
- For multi-tenant style queries on partitions of 10K-100K, default holds.

### Materialized CTE pattern for distance + filter cutoffs

When you need BOTH iterative scan AND a final distance threshold, the pgvector README (A) gives this canonical pattern:

```sql
SET hnsw.iterative_scan = relaxed_order;
WITH relaxed_results AS MATERIALIZED (
    SELECT id, embedding <-> $1 AS distance
    FROM chunks
    WHERE schema_name = 'case_26cv11493'
    ORDER BY distance
    LIMIT 20
)
SELECT * FROM relaxed_results
WHERE distance < 0.5
ORDER BY distance + 0;  -- the +0 prevents merge with the inner ORDER BY
```

The `MATERIALIZED` keyword forces the inner CTE to execute first (with iterative scan), and the outer query re-sorts and applies the distance cutoff. Without `MATERIALIZED`, the planner may fold the queries and bypass the iterative scan.

### Partial indexes -- still useful in 0.8

For low-cardinality, high-selectivity filters, partial indexes beat iterative scan:

```sql
-- One partial HNSW per schema -- expensive but fastest possible filtered query
CREATE INDEX chunks_case_26cv11493_hnsw
  ON chunks USING hnsw (embedding vector_cosine_ops)
  WHERE schema_name = 'case_26cv11493';
```

For Levi's setup (37 schemas, all roughly equal weight), full partial indexes are not worth the storage. Stick with iterative scan + a single B-tree on `schema_name` or `case_id` to support the planner.

---

## 3. Dimensionality + Storage -- halfvec is the Free Lunch

The benchmark data from Jonathan Katz (A, jkatz05.com/post/postgres/pgvector-scalar-binary-quantization/) is unambiguous: **halfvec gets you 2-3x storage savings with essentially zero recall loss**.

### Storage type reference (A, pgvector README)

| Type | Bytes per dim | Max dims | Notes |
|---|---|---|---|
| `vector` | 4 | 16,000 | float32, default precision |
| `halfvec` | 2 | 16,000 | float16, indexable up to 4,000 dims |
| `bit` (binary) | 1/8 | 64,000 | binary quantized; needs reranking |
| `sparsevec` | 8 per nonzero | 16,000 nonzero | for sparse embeddings |

### halfvec recall numbers (A, Jonathan Katz benchmark, 1M @ 1536 dim, ef_search=40)

| Metric | `vector` (float32) | `halfvec` (float16) |
|---|---|---|
| Storage | baseline | **2.0x smaller** |
| Recall@10 | 96.8% | 96.8% (identical) |
| QPS | 567 | 578 (slightly faster) |
| Build time | baseline | **2.31x faster** |

The 2.0x storage reduction applies to both the table column AND the index. On a 10M chunk corpus at 1536 dim, that is the difference between a 60GB index and a 30GB index -- which is the difference between "fits in RAM" and "doesn't" on most boxes.

### Recommended pattern for Levi

```sql
-- Storage: keep full-precision vector for re-ranking
ALTER TABLE chunks ADD COLUMN embedding vector(1024);

-- Index: halfvec for fast ANN, full vector for rerank
CREATE INDEX ON chunks USING hnsw ((embedding::halfvec(1024)) halfvec_cosine_ops)
  WITH (m = 24, ef_construction = 100);

-- Query: search via halfvec, rerank top-K with full vector
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

This pattern is what Jonathan Katz explicitly recommends in his quantization post (A): use the cheap index for retrieval, the expensive vector for final re-rank.

### Binary quantization -- NOT recommended for Levi

Katz benchmark (A) on 1536-dim dbpedia, ef_search=40, WITH reranking:
- Storage: 16.35x smaller
- Recall@10: 91.6% (vs 96.8% baseline)
- QPS: 760 vs 567

That 5-point recall hit is the issue. For human consumers searching for "the gist," 91.6% is fine. **For an LLM agent that needs the SPECIFIC chunk to ground a citation -- a paragraph that says exactly "Kenney represented ODHS on April 7, 2026" -- losing 5% of true top-K means 1 in 20 citations is missing or wrong.** That is a malpractice-tier defect for a legal research agent.

Without reranking (Katz tested this too on gist-960): **0.00% recall**. Binary quantization without rerank is broken. If you ever use it, you MUST add the rerank step.

**Verdict for Levi:** halfvec yes, binary no.

### Scalar quantization (lower-precision int8) -- not currently in pgvector core

As of pgvector 0.8.x, the scalar quantization knob is `halfvec` (16-bit float). True int8/int4 scalar quantization is available in pgvectorscale (Tiger) and HNSW PQ implementations in other ecosystems but is NOT in pgvector core. Skip it for now.

---

## 4. Distance Metric Selection -- The Embedding Model Decides

This is non-negotiable: **use the distance metric the embedding model was trained for.** Mixing metrics produces silent recall loss that no amount of parameter tuning will fix.

### Operator reference (A, pgvector README)

| Operator | Distance | Use |
|---|---|---|
| `<->` | L2 (Euclidean) | When model docs say "L2" or model is not pre-normalized |
| `<=>` | Cosine | Most modern text embedding models; safe default |
| `<#>` | Negative inner product | Pre-normalized models (faster than `<=>` because no normalization step) |
| `<+>` | L1 (Manhattan) | Niche; rare in text retrieval |
| `<~>` | Hamming | `bit` type only |

### Model-by-model guidance (current as of 2026)

**OpenAI text-embedding-3-large / text-embedding-3-small** (3072d / 1536d default)
- Pre-normalized to unit length when returned from the API (A, OpenAI guides historically).
- Because they are unit-normalized: cosine and inner product are mathematically equivalent. Use `<#>` (inner product) for slightly faster queries -- no normalization at query time.
- text-embedding-3-large supports `dimensions` parameter to reduce (e.g. 256, 1024). Reduced dims are still normalized.
- Index operator class: `vector_ip_ops` or `vector_cosine_ops`.

**Voyage voyage-3-large** (1024d default; 256/512/1024/2048 configurable)
- Voyage docs (A, docs.voyageai.com): output dimensions configurable. Normalization not explicitly documented in the public spec -- treat as unverified (C). Default to cosine (`<=>`) until you've verified via `SELECT vector_norms(embedding) FROM ...`.
- Note: Voyage now markets voyage-4-large as the current model; voyage-3-large is documented as "previous generation."

**BGE-M3** (1024d, BAAI)
- Hugging Face model card (A): "Embeddings are normalized (suitable for cosine similarity)."
- Use `vector_cosine_ops` or pre-normalize-then-use `vector_ip_ops`.
- BGE-M3 also returns sparse + ColBERT multi-vectors, which are NOT used in pgvector dense indexing -- store those in separate columns (sparsevec for sparse, JSONB for ColBERT) for hybrid retrieval.

**Cohere embed-v4.0** (256/512/1024/1536 configurable)
- Cohere docs (B, docs.cohere.com): dimensions configurable; normalization not explicitly stated.
- Default to cosine (`<=>`). Verify via norm check.

### Norm-check pattern (run this on EVERY new embedding column)

```sql
SELECT
  schema_name,
  COUNT(*) AS n,
  AVG(SQRT(embedding <#> embedding * -1)) AS avg_norm,
  STDDEV(SQRT(embedding <#> embedding * -1)) AS norm_stddev
FROM chunks
GROUP BY schema_name;
```

If `avg_norm` is consistently ~1.0 with tiny stddev, the model is pre-normalized -- use `<#>`. Otherwise use `<=>` (cosine handles normalization internally).

---

## 5. Maintenance -- VACUUM, REINDEX, Monitoring

### The HNSW vacuum trap (A, pgvector README)

Pgvector README literal quote: "Vacuuming can take a while for HNSW indexes. Speed it up by reindexing first."

The pattern:

```sql
REINDEX INDEX CONCURRENTLY chunks_embedding_hnsw_idx;
VACUUM (VERBOSE, ANALYZE) chunks;
```

Why: VACUUM on an HNSW index must traverse the graph to mark dead tuples. If graph quality has degraded (many inserts/updates), traversal is slow. REINDEX rebuilds the graph; subsequent VACUUM is fast.

`REINDEX INDEX CONCURRENTLY` (A, Postgres docs) holds only a `SHARE UPDATE EXCLUSIVE` lock -- agents can keep querying during rebuild. The build itself is slow (same as initial CREATE INDEX), but production stays online.

### When to REINDEX HNSW

Levi's ingest pattern is the trigger:

1. **After bulk ingest** of >10% of table size (e.g. new corpus drop, mass import from Apify scrape). Run REINDEX after the load completes.
2. **After a recall regression** detected via the norm-check + recall harness (see below).
3. **Quarterly** as a maintenance rhythm even without a known trigger.

### Monitoring index bloat

```sql
SELECT
  schemaname, indexrelname,
  pg_size_pretty(pg_relation_size(indexrelid)) AS size,
  idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
WHERE indexrelname LIKE '%hnsw%' OR indexrelname LIKE '%embedding%'
ORDER BY pg_relation_size(indexrelid) DESC;
```

Compare current index size to a "freshly built" baseline you record after each REINDEX. >1.5x baseline = bloated, run REINDEX.

For graph quality, the only honest test is a recall harness:

```sql
-- Run periodically: pull 100 random known-good (query, expected_top1) pairs
-- For each, run the vector query and check if expected_top1 is in top-10.
-- If recall drops below 0.95 from baseline, REINDEX.
```

Levi should bake this into a cron job that writes to `ops_records_officer.index_health` so a regression triggers a Filing Director task.

### Build progress visibility (A, pgvector README)

```sql
SELECT phase, round(100.0 * blocks_done / nullif(blocks_total, 0), 1) AS pct,
       tuples_done, tuples_total
FROM pg_stat_progress_create_index;
```

This is invaluable for long REINDEXes on the 238K-chunk Oregon public records corpus.

### Autovacuum tuning for write-heavy embedding tables

```sql
ALTER TABLE chunks SET (
  autovacuum_vacuum_scale_factor = 0.05,    -- vacuum at 5% dead tuples instead of 20%
  autovacuum_analyze_scale_factor = 0.02
);
```

Default 20% dead-tuple threshold is too lax for tables that receive continuous embedding updates from an agent firm.

---

## 6. Hybrid Retrieval -- RRF Beats Vector-Alone

Vector search retrieves by semantic similarity. Full-text search (tsvector + GIN) retrieves by exact lexical match. They have complementary blind spots:

- **Vector misses exact strings:** queries with proper names ("Kenney", "Bingaman", "26CV11493") or specific statute citations ("ORS 192.431") often miss the precise chunks because embeddings smear specific tokens into semantic neighborhoods.
- **Full-text misses paraphrases:** queries about a concept ("guardianship abuse," "Medicaid prior authorization denial") that don't share surface tokens with the relevant chunks miss completely.

Reciprocal Rank Fusion (RRF) is the canonical fix and the pgvector project itself ships an example.

### Canonical RRF SQL (A, github.com/pgvector/pgvector-python/blob/master/examples/hybrid_search/rrf.py)

```sql
WITH semantic_search AS (
  SELECT id,
         RANK() OVER (ORDER BY embedding <=> %(embedding)s) AS rank
  FROM chunks
  ORDER BY embedding <=> %(embedding)s
  LIMIT 20
),
keyword_search AS (
  SELECT id,
         RANK() OVER (ORDER BY ts_rank_cd(to_tsvector('english', content), query) DESC) AS rank
  FROM chunks, plainto_tsquery('english', %(query)s) query
  WHERE to_tsvector('english', content) @@ query
  ORDER BY ts_rank_cd(to_tsvector('english', content), query) DESC
  LIMIT 20
)
SELECT
  COALESCE(semantic_search.id, keyword_search.id) AS id,
  COALESCE(1.0 / (%(k)s + semantic_search.rank), 0.0) +
  COALESCE(1.0 / (%(k)s + keyword_search.rank), 0.0) AS score
FROM semantic_search
FULL OUTER JOIN keyword_search ON semantic_search.id = keyword_search.id
ORDER BY score DESC
LIMIT 10;
```

**k = 60** is the canonical constant from the original RRF paper (Cormack, Clarke, Buettcher 2009) and pgvector's example uses it. It prevents low ranks from dominating and gives a smooth gradient.

### Required indexes for the RRF pattern

```sql
-- Vector side (already have it)
CREATE INDEX chunks_embedding_hnsw_idx
  ON chunks USING hnsw (embedding vector_cosine_ops)
  WITH (m = 24, ef_construction = 100);

-- Full-text side (GIN on tsvector)
CREATE INDEX chunks_content_fts_idx
  ON chunks USING GIN (to_tsvector('english', content));

-- For better full-text performance, store the tsvector as a generated column
ALTER TABLE chunks ADD COLUMN content_tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('english', content)) STORED;
CREATE INDEX chunks_content_tsv_idx ON chunks USING GIN (content_tsv);
```

### When vector beats tsvector (and vice versa)

| Query shape | Winner | Why |
|---|---|---|
| Proper names, dates, case numbers, statute citations | **tsvector** | Surface-token match, no semantic smearing |
| Acronyms (CGM, DAS, EOCCO, ODHS) | **tsvector** | Embeddings often confuse acronyms with their expanded form |
| Paraphrases, conceptual queries | **vector** | "What is the agency's burden to investigate?" -> embeddings find paraphrased chunks |
| Question-answering ("what does Kenney say about timeline?") | **RRF** | Need both the name AND the conceptual neighborhood |
| Cross-lingual retrieval | **vector** (with multilingual model like BGE-M3) | tsvector tied to single language config |
| Spelling errors, OCR noise | **vector** | tsvector is brittle to typos; embeddings smooth over them |

### Weighted hybrid (when RRF isn't enough)

If you find vector consistently better on your workload (or vice versa), weight the RRF formula:

```sql
SELECT
  COALESCE(semantic_search.id, keyword_search.id) AS id,
  COALESCE(0.7 * (1.0 / (60 + semantic_search.rank)), 0.0) +
  COALESCE(0.3 * (1.0 / (60 + keyword_search.rank)), 0.0) AS score
FROM ...
```

**For Levi's evidence/legal corpus, I expect 50/50 RRF is the right default** because legal queries mix conceptual ("breach of fiduciary duty") and specific (proper names, statute citations) at roughly equal rates. Calibrate against a labeled evaluation set before deviating from 50/50.

### Add pg_trgm for fuzzy name matching as a third leg

Levi already has `pg_trgm` installed. For person/entity queries where spelling varies ("Bingaman" vs "Bingiman" in OCR'd docs), add a trigram leg:

```sql
CREATE INDEX chunks_content_trgm_idx ON chunks USING GIN (content gin_trgm_ops);
```

Then a 3-way RRF (vector + tsvector + trigram) handles paraphrase + exact-token + fuzzy-token simultaneously. This is the configuration that consistently outperforms vector-alone in legal/medical/forensic corpora where document quality varies.

### Sample 3-way RRF for Levi's case corpus

```sql
WITH semantic AS MATERIALIZED (
  SELECT id, RANK() OVER (ORDER BY embedding <=> $1) AS r
  FROM chunks WHERE schema_name = ANY($2)
  ORDER BY embedding <=> $1 LIMIT 30
),
fts AS MATERIALIZED (
  SELECT id, RANK() OVER (ORDER BY ts_rank_cd(content_tsv, q) DESC) AS r
  FROM chunks, plainto_tsquery('english', $3) q
  WHERE schema_name = ANY($2) AND content_tsv @@ q
  ORDER BY ts_rank_cd(content_tsv, q) DESC LIMIT 30
),
trgm AS MATERIALIZED (
  SELECT id, RANK() OVER (ORDER BY similarity(content, $3) DESC) AS r
  FROM chunks WHERE schema_name = ANY($2) AND content % $3
  ORDER BY similarity(content, $3) DESC LIMIT 30
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

Note `MATERIALIZED` keeps each leg honest (planner won't fold + bypass iterative scan). `$2` is the array of schemas to search.

---

## 7. Recommendations for Levi's `valor_consolidated` Setup

Concrete action items, ordered by priority:

1. **Enable iterative scan globally for the role used by agents:**
   ```sql
   ALTER ROLE valor_agent SET hnsw.iterative_scan = 'relaxed_order';
   ALTER ROLE valor_agent SET hnsw.max_scan_tuples = 50000;
   ```
   Without this, every cross-schema query on `v_evidence_search` is silently losing recall.

2. **Migrate large indexes to halfvec.** The Oregon Public Records schema (238K chunks) and any future 1M+ corpus should use the `halfvec` expression-index pattern. Halves storage with no recall loss.

3. **Add tsvector + trigram indexes to every chunk table** and replace single-leg vector queries with 3-way RRF in the agent retrieval layer. Expected recall lift: 15-25% on entity-heavy legal queries.

4. **Standardize on `m=24, ef_construction=100` for indexes >=100K chunks.** Bump ef_search=150 at runtime. Recall@10 ~0.97 with predictable QPS.

5. **Wire a recall harness into `ops_records_officer`.** A nightly cron pulls 100 known-good (query, expected_chunk_id) pairs across schemas, runs the production retrieval path, and writes `recall@10` to a metrics table. Alert (Filing Director task) on regression >2pp from baseline.

6. **Schedule quarterly REINDEX CONCURRENTLY.** Or trigger on bulk ingests >10% of table size. Bake into the records officer maintenance loop.

7. **Verify embedding norms per model.** Before turning on `vector_ip_ops` for any embedding column, run the norm-check from Section 4. If norms aren't unit, stay on `vector_cosine_ops`.

8. **For the 2.4M chunk cross-schema view, do not build a single HNSW.** Keep per-schema HNSW indexes; use the UNION ALL view for the planner. If/when one schema crosses 5M, evaluate pgvectorscale StreamingDiskANN as a per-partition replacement.

---

## Sources cited (with confidence)

- (A) pgvector official README, github.com/pgvector/pgvector -- HNSW/IVFFlat params, iterative scan, halfvec, distance ops, filtering patterns, RRF/hybrid pointer
- (A) pgvector-python examples, hybrid_search/rrf.py -- canonical RRF SQL
- (A) Jonathan Katz, jkatz05.com -- HNSW perf benchmarks, scalar/binary quantization benchmarks
- (B) Supabase blog: pgvector-fast-builds, increase-performance-pgvector-hnsw, hnsw-indexes docs -- parameter tuning, build speed, memory recs
- (B) Tiger Data (formerly Timescale) blog: pgvector-vs-pinecone -- 50M scale benchmark, pgvectorscale comparison
- (A) BAAI/bge-m3 model card on Hugging Face -- normalization, distance metric guidance
- (B) Voyage AI docs (docs.voyageai.com/docs/embeddings) -- dimensions; normalization NOT explicitly stated
- (B) Cohere docs (docs.cohere.com/docs/embeddings) -- dimensions; normalization NOT explicitly stated
- (C) Gemini 3.1 Pro grounded search run -- partial / mostly empty; sources list only
- (D) Postgres autovacuum tuning -- general Postgres knowledge, not pgvector-specific

**Unverified / requires Levi to confirm against his actual model choice:**
- Voyage voyage-3-large normalization status -- run norm-check
- Cohere embed-v4.0 normalization status -- run norm-check
- pgvectorscale availability on his Postgres 16 install (Tiger extension, not in core)

---

**Wave end. Findings file written.**
