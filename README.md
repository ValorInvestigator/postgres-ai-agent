# postgres-ai-agent

**Postgres patterns for AI-agent-only consumption.**

This repository packages a four-wave deep-research synthesis on running Postgres as the canonical retrieval substrate for AI agents (Claude Code, Codex, Vertex Gemini ADK, MCP tools). It is distributed as a Claude Code skill: drop the folder into `~/.claude/skills/postgres-ai-agent/` and every Claude Code session auto-loads the patterns.

## What this gives you

- Hybrid RRF retrieval (vector + tsvector + pg_trgm at k=60) replacing single-leg vector or ILIKE-style search
- HNSW iterative scan configuration to recover recall lost on WHERE-filtered queries
- halfvec deployment patterns for 2x storage savings at identical recall
- Schema-per-corpus canonical template with `__schema_meta` self-documentation
- `COMMENT ON` metadata pattern so agents read `pg_description` before writing SQL
- `ops_search_agent.query_log` observability layer
- Trigger-based JSONB audit log per schema (litigation-grade)
- Postgres-native graph layer (no Microsoft GraphRAG; no thousand-dollar LLM ingest cost)
- Docling primary / Marker fallback / Surya OCR PDF pipeline
- Faster-whisper + pyannote audio pipeline
- Qwen3-Embedding-8B and voyage-context-3 embedding model selection guidance
- BGE-reranker-v2-m3 cross-encoder reranking deployment
- MCP tool surface (`describe_schema`, `list_corpora`, `rerank`, `execute_sql`)
- Six-phase migration plan ordered by leverage

## How it is generated

Four parallel deep-research waves were run against vendor docs (pgvector, Anthropic, Voyage, Tiger Data, Supabase, Neon, Crunchy Data), the pgvector source, and Postgres 16 docs. The wave reports are preserved in `references/waves/` as authoritative citations; the consolidated playbook at `references/PLAYBOOK.md` is the synthesis.

## Confidence grades

Every claim in the playbook is graded:
- **A**: pgvector / Postgres docs or peer-reviewed paper
- **B**: vendor blog
- **C**: synthesis or community pattern

## Repository layout

See `SKILL.md` for the full layout. Quick orientation:

- `SKILL.md` — Claude Code skill metadata + the five most-important moves
- `references/PLAYBOOK.md` — 15-section consolidated playbook (~30KB)
- `references/waves/` — the four authoritative wave reports + Gemini Pro supplements
- `scripts/` — Phase 1 SQL ready to run against an existing PG cluster
- `snippets/` — Python boilerplate (BigQuery auth, query logging wrapper)
- `tests/` — regression harness (recall + latency benchmarks)

## Installation

### As a Claude Code skill (recommended)

```bash
git clone https://github.com/ValorInvestigator/postgres-ai-agent.git ~/.claude/skills/postgres-ai-agent
```

Claude Code auto-loads the skill on startup. Future sessions in any project automatically know the patterns.

### As a reference repo

```bash
git clone https://github.com/ValorInvestigator/postgres-ai-agent.git
```

Read `references/PLAYBOOK.md` directly. Use scripts/ against your PG cluster.

## Phase 1 quick start

Against an existing PG cluster (Postgres 16+, pgvector 0.8.2+):

```bash
psql -d your_database -f scripts/01_enable_iterative_scan.sql
psql -d your_database -f scripts/02_create_corpus_registry.sql
psql -d your_database -f scripts/03_create_query_log.sql
psql -d your_database -f scripts/04_comment_on_workhorses.sql
psql -d your_database -f scripts/05_hybrid_rrf_search.sql
```

See `SKILL.md` "Quick-start" section for verification queries.

## Tested against

- Postgres 16 + pgvector 0.8.2 + pg_trgm + uuid-ossp
- 37 schemas, ~2.4M chunks total
- Single-box deployment (M.2 NVMe, 64GB RAM)
- Schema sizes from ~5K rows to ~238K rows
- Single-application trust boundary (no RLS)

## What this skill does NOT cover

- BigQuery / Vertex AI native workflows (use Vertex Discovery Engine for that)
- Multi-tenant data isolation (this skill assumes single-app trust boundary)
- OLTP-heavy workloads (this is retrieval-optimized)
- Federated search across multiple PG clusters
- Replication / HA topology

## License

MIT. See `LICENSE`.

## Contributing

PRs welcome. Style rules:
- No em dashes. Double hyphens.
- Anchor every architectural claim on a wave-report citation.
- Confidence-grade every assertion.

## Acknowledgments

- Anthropic for the 49%-recall-lift measurement on hybrid retrieval that motivated the RRF design
- Supabase / Tiger Data for the halfvec + partial-index patterns
- Crunchy Data for the schema-per-corpus operational guidance
- Voyage AI for the voyage-context-3 model + context recommendations
- Qwen team for Qwen3-Embedding-8B under Apache 2.0
- Open-source community: pgvector (Andrew Kane), tsvector / pg_trgm (Oleg Bartunov + Teodor Sigaev), Docling (IBM), Marker (Vik Paruchuri), faster-whisper (Guillaume Klein), BGE-reranker-v2-m3 (BAAI)
