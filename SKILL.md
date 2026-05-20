---
name: postgres-ai-agent
description: Postgres patterns for AI-agent-only consumption. Hybrid retrieval (vector + tsvector + pg_trgm + RRF), HNSW iterative scan, halfvec, schema-per-corpus with __schema_meta + COMMENT ON metadata, trigger-based JSONB audit logs, ops_search_agent.query_log observability, Postgres-native graph layer (no Microsoft GraphRAG), Docling/Marker/WhisperX ingest pipelines, BGE-reranker-v2-m3 cross-encoder reranking. Synthesizes four deep-research waves into a phased migration plan. Use when designing, querying, or upgrading any AI-agent-facing Postgres corpus.
license: MIT
---

# postgres-ai-agent

Canonical playbook for Postgres servers consumed by AI agents (Claude Code, Codex, Vertex Gemini ADK, MCP retrieval tools). Replaces ILIKE / grep-style retrieval with hybrid RRF + cross-encoder reranking; replaces ad-hoc schema with a frozen canonical template; replaces silent retrieval failure with observable query logging.

## When to use this skill

- Designing a new PG corpus for AI-agent retrieval
- Auditing an existing PG corpus against AI-agent best practices
- Diagnosing low retrieval recall (vector queries returning irrelevant results)
- Adding a new schema to a `schema-per-corpus` deployment
- Wiring an MCP retrieval tool against a PG-backed RAG store
- Migrating from BigQuery + Vertex Discovery Engine to local PG
- Evaluating reranking lift (BGE-reranker-v2-m3, Cohere Rerank, etc.)

## When NOT to use this skill

- Pure OLTP workloads (this skill is retrieval-optimized, not transaction-optimized)
- Sub-100K row corpora (the patterns add complexity that doesn't pay off below scale)
- Multi-tenant data isolation requirements (this skill assumes single-app trust boundary; explicitly does NOT cover RLS)
- BigQuery-native workflows (this skill is PG-native; for cross-source patterns, query both)

## The five moves that capture 90% of the wins

1. **Enable iterative HNSW scan** on the agent role.
   ```sql
   ALTER ROLE valor_agent SET hnsw.iterative_scan = 'relaxed_order';
   ```
   Without this, every WHERE-filtered vector query silently loses recall.

2. **Three-way RRF retrieval** (vector + tsvector + pg_trgm at k=60). Anthropic-measured 49% retrieval-failure drop from hybrid; 67% with reranker. See `scripts/05_hybrid_rrf_search.sql`.

3. **`COMMENT ON` every schema, table, and column.** Agents read `pg_description` and write drastically better queries on first try. See `scripts/04_comment_on_workhorses.sql` for the pattern.

4. **Log every agent query** into `ops_search_agent.query_log`. Drift, hallucination, and cost blowouts are invisible without it. See `scripts/03_create_query_log.sql`.

5. **Self-host BGE-reranker-v2-m3** (Apache 2.0, 568M params, ~2GB VRAM fp16) as an opt-in MCP `rerank` tool. See `references/waves/wave_4_agent_retrieval.md` Section 5.

## Architecture decisions (locked)

- **Schema-per-corpus**, not single mega-table. pgvector HNSW comfort zone is 5-10M vectors per index.
- **No RLS** (single-app trust boundary; pure overhead).
- **No mega-matview** for cross-schema search until 50M+ chunks.
- **Trigger-based audit log** with JSONB diffs, not pgaudit flat files.
- **Postgres-native graph layer** (entities + entity_mentions + chunk_relations), not Microsoft GraphRAG.
- **Defer partitioning** until any corpus crosses ~5M rows.
- **halfvec by default** (2x storage savings, identical recall per Katz benchmarks).
- **Docling primary / Marker fallback / Surya OCR** for PDFs; reject LlamaParse (sealed-records risk).
- **Qwen3-Embedding-8B** (Apache 2.0, MTEB 70.58) for sealed corpora; voyage-context-3 for public.

## Repository structure

```
postgres-ai-agent/
├── SKILL.md                  ← this file (auto-loaded by Claude Code)
├── README.md                 ← human-facing overview
├── references/
│   ├── PLAYBOOK.md           ← full canonical playbook (15 sections, ~30KB)
│   └── waves/
│       ├── wave_1_vector_index.md          (~28KB)
│       ├── wave_2_ingest_pipeline.md       (~40KB)
│       ├── wave_3_schema_design.md         (~35KB)
│       ├── wave_4_agent_retrieval.md       (~33KB)
│       └── gemini_supplements/             (Gemini Pro deep-dives per topic)
├── scripts/
│   ├── 01_enable_iterative_scan.sql
│   ├── 02_create_corpus_registry.sql
│   ├── 03_create_query_log.sql
│   ├── 04_comment_on_workhorses.sql
│   └── 05_hybrid_rrf_search.sql
├── snippets/
│   ├── bigquery_auth.py                    ← service-account auth boilerplate
│   └── pg_query_logger.py                  ← Python wrapper that logs every query
└── tests/                                  ← regression harness (recall + latency)
```

## Quick-start (Phase 1 — same-day low-risk wins)

Run these in order against an existing PG cluster:

```bash
psql -d valor_consolidated -f scripts/01_enable_iterative_scan.sql
psql -d valor_consolidated -f scripts/02_create_corpus_registry.sql
psql -d valor_consolidated -f scripts/03_create_query_log.sql
psql -d valor_consolidated -f scripts/04_comment_on_workhorses.sql
psql -d valor_consolidated -f scripts/05_hybrid_rrf_search.sql
```

Then test:
```sql
-- Verify iterative scan is on
SHOW hnsw.iterative_scan;

-- List corpora
SELECT * FROM corpus_registry;

-- Run hybrid RRF (after embedding the query externally and passing as a vector literal)
SELECT * FROM hybrid_rrf_search(
  query_text => 'Carol Frederick attorney probate Bingaman',
  query_vec  => :query_embedding::vector(384),
  k          => 60,
  per_leg    => 60,
  rrf_k      => 60
) LIMIT 20;
```

## Phased migration plan

See `references/PLAYBOOK.md` Section 13. Six phases ordered by leverage:

| Phase | Theme | Effort | When |
|-------|-------|--------|------|
| 1 | Low-risk same-day wins (this skill's scripts/) | hours | today |
| 2 | Drift removal across existing schemas | days | next week |
| 3 | Index modernization (halfvec, partial indexes, 3-way RRF) | week | after Phase 2 |
| 4 | Parser + chunker upgrade (Docling, Marker, WhisperX) | week | after Phase 3 |
| 5 | Embedding + chunking upgrade (Qwen3 / voyage) | week | after Phase 4 |
| 6 | Advanced (RAPTOR, graph layer, partitioning, rerank) | as justified | after measured gaps |

## Authoritative references

- `references/PLAYBOOK.md` — full 15-section consolidated playbook (use as the canonical citation)
- `references/waves/wave_1_vector_index.md` — HNSW, iterative-scan, halfvec, RRF mechanics
- `references/waves/wave_2_ingest_pipeline.md` — Docling, Marker, Whisper, embedding models, provenance, DLQ
- `references/waves/wave_3_schema_design.md` — schema-per-corpus, canonical DDL, partitioning, audit
- `references/waves/wave_4_agent_retrieval.md` — MCP tool surface, reranking, COMMENT ON, query log
- `references/waves/gemini_supplements/` — Gemini Pro deep-dives on specific subtopics

## Confidence grades (per playbook)

- **A**: pgvector / Postgres docs or peer-reviewed paper
- **B**: vendor blog (Supabase / Anthropic / Voyage / Tiger / Crunchy / Neon)
- **C**: synthesis or community pattern

## Style rules

- No em dashes. Use double hyphens.
- Hedged where unverified.
- Anchor every architectural claim on a wave-report citation.
- Postgres 16, pgvector 0.8.2, pg_trgm, uuid-ossp baseline assumed.

## License

MIT.
