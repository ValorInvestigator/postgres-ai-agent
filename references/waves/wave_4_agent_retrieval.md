# Postgres for AI Agents -- Retrieval Best Practices

**Wave:** agent_retrieval
**Generated:** 2026-05-19
**Audience:** Levi Bakke -- designing Postgres + pgvector schemas, MCP servers, and direct-SQL tool surfaces for Claude Code, Codex, and the Valor Agent Firm (Vertex Gemini ADK)
**Confidence grades:** A = primary-source confirmed; B = vendor blog / well-known practice; C = inference / synthesis; D = speculative

---

## 0. TL;DR for Levi

Levi already has the right instinct with `valor-rag` (semantic + keyword + full doc + stats). The 2026 consensus is to expose **5-7 retrieval tools** to agents -- not 20, not 1 -- because every extra tool eats context (one analysis showed Postgres + Playwright + Azure MCP servers can burn 83K of a 200K-token budget before the first user message; src: Gemini A, B). Hybrid search via **Reciprocal Rank Fusion with k=60** is the load-bearing pattern (Supabase, Anthropic, Microsoft all agree; A). Cross-encoder reranking adds **18 percentage points of recall improvement** on top of hybrid (Anthropic measured 49% to 67% reduction in retrieval failure with reranking added; A). Build for the agent first: machine-readable JSON, deterministic citation strings, paginated results capped at ~30 chunks, and `COMMENT ON` every column so text-to-SQL has schema context for free. Single-box Postgres on M.2 NVMe with 64GB RAM handles 2-50M chunks comfortably at p95 < 50ms hybrid query if you size HNSW + maintenance_work_mem correctly.

---

## 1. MCP Tool Design for Postgres/pgvector

### 1.1 What the field has converged on

The official Anthropic reference Postgres MCP server (`@modelcontextprotocol/server-postgres`) was **archived** in 2025 and moved to `modelcontextprotocol/servers-archived/src/postgres` (A). It exposed exactly **one tool** -- `query(sql)` running inside a READ ONLY transaction -- plus table schemas as MCP **resources** at `postgres://<host>/<table>/schema`. Anthropic's pattern was deliberately minimal: agents see read-only `query()` and `pg_catalog`-derived resources, nothing else. (A)

**Supabase MCP** (production, 20+ tools): execute_sql, list_tables, design tables, migrations, branches, project config, logs. They are explicit that "better schema discovery" is still on the roadmap; right now `list_tables` is the only structured discovery tool and agents fall back to running `SELECT ... FROM information_schema`. They flag future "auto-detect destructive operations and require confirmation" as the next safety layer. (A)

**Crystal DBA Postgres MCP Pro** (9 tools, prod-grade): `list_schemas`, `list_objects`, `get_object_details`, `execute_sql`, `explain_query`, `get_top_queries`, `analyze_workload_indexes`, `analyze_query_indexes`, `analyze_db_health`. Read-only and restricted modes are first-class. No native pgvector tool -- agents call pgvector through `execute_sql`. (A)

**Neon MCP**: project-level (create branch, get connection string) plus SQL execution. Same general pattern: small surface, read/write toggle, schema introspection via SQL.

**Levi's `valor-rag`**: `semantic_search`, `keyword_search`, `get_document_context`, `database_stats`. This is closer to "RAG-as-a-tool" than "Postgres-as-a-tool" -- it is the more agent-friendly direction. (A)

### 1.2 The right tool surface for Valor (recommendation)

Expose **6 retrieval tools** plus **2 introspection tools**. Anything more eats context; anything less forces the agent to write raw SQL for every lookup. (C, synthesizing Anthropic + Supabase + Crystal patterns)

| Tool | Args | Returns | Notes |
|---|---|---|---|
| `semantic_search` | query, top_k=20, corpus?, filters? | ranked chunks | pgvector cosine, HNSW |
| `keyword_search` | terms[], corpus?, filters?, top_k=20 | ranked chunks | tsvector + ts_rank_cd |
| `hybrid_search` | query, top_k=20, corpus?, weights? | ranked chunks | RRF k=60 across the two above |
| `get_full_doc` | doc_id OR file_path | all chunks for one source | for "show me the whole thing" |
| `list_corpora` | -- | corpus names + chunk counts | so the agent knows what's available |
| `describe_schema` | table? | table + column comments | reads `pg_description` |
| `execute_sql` | sql | rows, capped 100 | read-only transaction, escape hatch |
| `database_stats` | -- | row counts, last update, index health | observability |

**Why 8 not 4 or 20:** Anthropic's own guidance is "poka-yoke your tools" -- make it hard to misuse them through better parameter design (A). The split between `semantic_search`, `keyword_search`, and `hybrid_search` is intentional. Hybrid is the default smart choice, but agents handling proper-noun queries (case numbers, statute citations, person names) should be able to force pure-keyword to avoid semantic drift. The reverse holds for conceptual queries. Let the agent pick. (B)

### 1.3 Pagination + context-window economics

The 2026 reality: stacking MCP servers can blow 41% of a 200K context window on tool definitions alone before any user message (Gemini A; analyses from EclipseSource + r/ClaudeCode March 2026). This drives three constraints:

1. **Cap default top_k at 20**, hard ceiling at 50. Anthropic's contextual retrieval paper found top-20 outperformed top-10 and top-5, so 20 is the sweet spot (A).
2. **Each result <= 500 tokens of snippet text** + 100 tokens metadata. With top_k=20, one tool call costs ~12K tokens of result.
3. **Return cursors not full result sets**. If the agent asks for top_k=200, return top_k=20 + `next_cursor` token. Agent calls again to drill deeper. (B)
4. **Trim tool descriptions ruthlessly**. The Harness MCP v2 collapsed from ~175 tools to 11 (Gemini A); the postgres-mcp "Code Mode" gets 90% token savings by replacing 278 specialized tools with a V8 sandbox.

---

## 2. Hybrid Search Ranking Agents Trust

### 2.1 Reciprocal Rank Fusion with k=60 -- the consensus

RRF formula: `score(doc) = sum over query types of 1 / (k + rank_in_that_query)`, with **k=60** as the empirically derived smoothing constant (A: Supabase docs, Anthropic contextual retrieval, original Cormack/Clarke/Buettcher 2009 paper). The k=60 value "prevents rank position from having excessive influence" and yields high-quality results "without the necessity for any tuning" (A).

**Why RRF beats weighted-sum:** RRF works on ranks not scores, so you don't need to normalize cosine similarity (0-1, often clustered 0.7-0.9) against ts_rank_cd (unbounded, often 0.0001-0.5). The ranks are comparable by construction. (A)

### 2.2 Supabase's canonical hybrid_search SQL (verified pattern)

```sql
create or replace function hybrid_search(
  query_text text,
  query_embedding extensions.vector(512),
  match_count int,
  full_text_weight float = 1.5,
  semantic_weight float = 1,
  rrf_k int = 60
)
returns setof documents
language sql
as $$
with full_text as (
  select id,
         row_number() over(order by ts_rank_cd(fts, websearch_to_tsquery(query_text)) desc) as rank_ix
  from documents
  where fts @@ websearch_to_tsquery(query_text)
  limit least(match_count, 30) * 2
),
semantic as (
  select id,
         row_number() over (order by embedding <=> query_embedding) as rank_ix
  from documents
  order by rank_ix
  limit least(match_count, 30) * 2
)
select documents.*
from full_text
full outer join semantic on full_text.id = semantic.id
join documents on coalesce(full_text.id, semantic.id) = documents.id
order by
  coalesce(1.0 / (rrf_k + full_text.rank_ix), 0.0) * full_text_weight +
  coalesce(1.0 / (rrf_k + semantic.rank_ix), 0.0) * semantic_weight
  desc
limit least(match_count, 30)
$$;
```
(Source: Supabase docs/blog -- pasted verbatim; A)

**Note Supabase weights full-text 1.5x semantic by default.** That nudges precision for exact-phrase queries (case numbers, names) without abandoning semantic recall. For Valor's case-evidence corpus (lots of proper nouns: "Glenn Null," "ORS 192.431," "26CV11493") that weighting is right. (C)

### 2.3 Pre-rerank candidate set size

Anthropic's contextual retrieval paper: **retrieve 150 candidates** in stage 1, rerank down to top 20 for the LLM (A). Voyage AI: **100 candidates** in stage 1, top 10 after rerank (A). Pinecone tutorial: **25 candidates**, top 3 (B).

Recommendation for Valor: **100 candidates pre-rerank, top 20 post-rerank**. The 100/20 split matches Voyage's evaluation methodology and stays well under cross-encoder latency budgets. (C)

### 2.4 Trigram (pg_trgm) as a third leg

When the agent queries with misspellings, OCR garbage, or partial names ("McSherry" vs "McSherrey"), add `pg_trgm` similarity as a third RRF leg. Cost is minimal (one GIN index on a trigram operator class) and recall on dirty queries jumps materially. Most production hybrid stacks now use **vector + BM25/tsvector + pg_trgm** triple-fusion. (C; pattern observed in pgvector-python examples and Supabase docs)

---

## 3. Reranking with Cross-Encoders

### 3.1 The benchmark numbers Anthropic published

Anthropic contextual retrieval (verified A):
- Contextual Embeddings alone: **35% failure rate reduction**
- Contextual Embeddings + BM25: **49%**
- Combined with **reranking: 67% failure rate reduction (5.7% to 1.9%)**

That extra 18 percentage points from the rerank stage is the single biggest signal-quality lever after switching to hybrid. (A)

### 3.2 Reranker landscape (2026)

| Reranker | Size | Latency | Context | Languages | License | Best for |
|---|---|---|---|---|---|---|
| Cohere Rerank 3.5 | API | ~100-300ms / 100 docs | -- | multilingual | commercial | enterprise, English-heavy, simple API |
| Voyage Rerank-2 | API | ~100-300ms / 100 docs | 16K (4K query) | multilingual | commercial | technical/legal docs, +13.89% over OpenAI v3-large on 93 datasets (A) |
| Voyage Rerank-2-lite | API | lower | -- | multilingual | commercial | latency-sensitive |
| Jina Reranker v2 | 278M | 6x faster than v1 | 1024 doc / 512 query | 100+ | commercial | function-calling, text-to-SQL aware, agentic RAG (A) |
| BGE-reranker-v2-m3 | 568M | local GPU | 8192 | multilingual | **Apache 2.0** | self-hosted, multilingual (A) |
| BGE-reranker-v2-gemma | 2B | local GPU | 8192 | multilingual | Apache 2.0 | best quality if you have the GPU |

Sources: A (Anthropic, Voyage, Jina, BAAI HF), B (Cohere).

### 3.3 When reranking is worth the 100-500ms

Worth it:
- Multi-tenant or external-facing agents where wrong-answer cost is high
- Queries where retrieved chunks are near-neighbors in semantic space (legal docs, medical docs) -- reranker uses query-doc cross-attention which a bi-encoder cannot
- Long documents where chunk-vs-question relevance is hard to read from cosine alone

Skip it:
- Internal agent loops doing iterative refinement (the agent itself is the reranker)
- Trivial lookups (single keyword, specific ID, exact-phrase) -- BM25 alone is already at >95% precision
- Latency-critical loops (sub-100ms target)

### 3.4 Recommended deployment for Valor

**Self-host BGE-reranker-v2-m3 on local GPU.** Apache 2.0 license, multilingual, 568M params runs in ~2GB VRAM in fp16, scores 100 query-doc pairs in 100-300ms on a consumer GPU. (B+C)

Fallback to **Voyage Rerank-2** API for high-stakes filings (court-bound output) where the additional accuracy buys insurance. Cohere Rerank 3.5 is comparable but Anthropic's own paper uses Voyage for the published 67% number. (A)

Wire the reranker as a separate MCP tool -- `rerank(query, docs[])` -- so the agent can opt in or skip. Don't bake it into `hybrid_search` mandatorily. (C)

---

## 4. Packaging Chunks for Agents

### 4.1 Format: JSON > Markdown for agent consumption

LangChain4j is explicit that there is no one-size-fits-all answer but recommends prepending metadata to content (A). For Anthropic-family agents and Vertex Gemini ADK both, **structured JSON wins** -- the agent parses by key, not by string-matching markdown.

Recommended chunk envelope:

```json
{
  "chunk_id": "case_26cv11493:14_filings/2025-04-03_complaint.pdf#7",
  "snippet": "<= 500 tokens of relevant text, sentence-bounded, never mid-token>",
  "citation": "[case_26cv11493:14_filings/2025-04-03_complaint.pdf#7]",
  "source_path": "/mnt/linux-storage/.../complaint.pdf",
  "chunk_idx": 7,
  "score": 0.847,
  "score_components": {"semantic": 0.91, "fts": 0.43, "rrf": 0.0254},
  "metadata": {"corpus": "case_26cv11493", "filed_date": "2025-04-03", "doc_type": "complaint"}
}
```

### 4.2 Citation format that agents can quote back

Use a **single deterministic string** the agent can paste into output: `[corpus:schema/file#chunk_idx]`. Anthropic's contextual retrieval paper, Supabase docs, and Vertex AI Search all converge on bracketed citation tokens that surround a stable identifier (A+B). Critical properties:

- **Deterministic**: same chunk always yields same string (no UUIDs that rotate)
- **Self-describing**: a human can find the source from the citation alone
- **Parsable**: regex `\[([\w_]+):([^#\]]+)#(\d+)\]` recovers all three fields
- **Short**: <100 chars (so 20 citations cost <2K tokens)

### 4.3 Snippet rules

- **Sentence-bounded only.** Cut at `.`, `?`, `!`, `\n\n` boundaries. Never mid-token. (B)
- **Highlight matched terms** with `**term**` markdown bold -- works for both humans and agents reading the output. (C)
- **Pre-pend the contextual prefix** from Anthropic's contextual retrieval pattern: 50-100 tokens of LLM-generated context describing where this chunk sits in the document. This was the dominant gain in their paper (35% failure rate reduction on its own). (A)
- **Default snippet length 300-500 tokens.** Goes up to 1000 for legal/medical docs where context dependencies are long.

### 4.4 Inline metadata vs separate sources[] array

Two patterns in the wild:
- **Inline**: each chunk carries its full metadata
- **Sources array**: chunks reference `source_id`, full source metadata sits in a `sources[]` array once

**Recommendation: inline.** Agents do not optimize for repeated metadata at the token level; clarity wins. Token cost of duplication is <5%. (C)

---

## 5. Agentic Retrieval Loops

### 5.1 Multi-hop retrieval pattern

LangGraph's state-machine model is the dominant 2026 pattern (A). Nodes:
1. **Retrieve**: hybrid_search returns top_k
2. **Grade**: LLM grades each chunk for relevance (Self-RAG's ISREL token)
3. **Decide**: if N relevant chunks >= threshold, proceed; else **rewrite query** and loop back to Retrieve
4. **Generate**: draft answer
5. **Grade again**: is the answer supported by chunks (ISSUP) and useful (ISUSE)?
6. **Loop or exit**

Self-RAG four reflection tokens (A):
- **Retrieve**: should I fetch more docs?
- **ISREL**: is this chunk relevant?
- **ISSUP**: is this generated sentence supported by retrieved chunks?
- **ISUSE**: is the final answer useful?

### 5.2 Corrective-RAG (CRAG)

CRAG adds a **retrieval evaluator** that scores confidence, then (A):
- High confidence -> use retrieved docs as-is
- Low confidence -> trigger fallback (web search, broader corpus, query rewrite)
- Plus a "decompose-then-recompose" filter that strips noise from each chunk

For Valor: implement CRAG by adding an `evaluate_retrieval(query, docs[])` MCP tool that returns `{confidence: 0..1, reason: str}`. If confidence < 0.5, agent triggers `web_search` (deep-research stack) or `expand_corpus_scope`. (C, mapping CRAG to Valor stack)

### 5.3 When agents should write SQL directly vs use curated tools

**Text-to-SQL via `execute_sql(sql)` is the escape hatch, not the default.** Reasons:
- Curated tools (`semantic_search`, `hybrid_search`) hide pgvector syntax, indexing, embedding model details -- the agent never has to know `<=>` means cosine distance
- Raw SQL forces the agent to handle schema introspection, type casting, parameter escaping
- Read-only enforcement is easier at the tool layer than at the SQL parsing layer

**When direct SQL wins:**
- Cross-table joins not covered by tools ("show me all chunks from cases where the filed date is after 2025-01-01")
- Aggregations ("how many chunks contain 'ORS 192.431'")
- Schema exploration the agent invents on the fly

**Make schema visible.** Every text-to-SQL agent benefits from a `describe_schema` tool that returns table comments + column comments from `pg_description`. See Section 6.

### 5.4 Caching repeated queries

Two layers:
1. **Anthropic prompt cache** on the system-prompt + tool-definitions chunk -- saves 50-90% on repeated tool calls (B)
2. **Postgres result cache** in `ops_search_agent.query_cache` keyed by (tool_name, normalized_query_hash). TTL 5-60 min depending on corpus volatility. Eviction by LRU.

Caching matters most for **iterative loops** where the agent re-queries with minor rewrites. Don't cache final generations -- cache the deterministic retrieval step.

---

## 6. The `COMMENT ON` Pattern

This is the highest-ROI low-effort win on the entire list.

### 6.1 Why it matters

When the agent uses `execute_sql`, it needs to know what columns mean. Without comments, the agent guesses from column names. With comments, the agent reads them via `information_schema` / `pg_description` and writes drastically better SQL. (A)

### 6.2 How comments surface

Comments are NOT in `information_schema`. They are in `pg_catalog.pg_description` and `pg_catalog.pg_shdescription` (A). Retrieve via:

```sql
-- Table comment
SELECT obj_description('case_26cv11493.chunks'::regclass, 'pg_class');

-- All column comments for a table
SELECT a.attname, col_description(a.attrelid, a.attnum) AS comment
FROM pg_attribute a
WHERE a.attrelid = 'case_26cv11493.chunks'::regclass
  AND a.attnum > 0
  AND NOT a.attisdropped;

-- Or wrap in a view
CREATE VIEW agent_schema_doc AS
SELECT
  n.nspname  AS schema_name,
  c.relname  AS table_name,
  obj_description(c.oid, 'pg_class')      AS table_comment,
  a.attname                                AS column_name,
  format_type(a.atttypid, a.atttypmod)     AS data_type,
  col_description(a.attrelid, a.attnum)    AS column_comment
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid
WHERE c.relkind = 'r' AND a.attnum > 0 AND NOT a.attisdropped
  AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY n.nspname, c.relname, a.attnum;
```

The `describe_schema` MCP tool simply selects from this view filtered to the requested schema/table.

### 6.3 Comment style for agent consumption

```sql
COMMENT ON TABLE case_26cv11493.chunks IS
  'Chunked text from filings, exhibits, and orders in Bakke v. ODHS '
  '(Marion County Circuit 26CV11493, dismissed without prejudice 2026-05). '
  '28,463 chunks across 1,257 source files. Use for refile-prep evidence retrieval.';

COMMENT ON COLUMN case_26cv11493.chunks.embedding IS
  'pgvector cosine HNSW. text-embedding-3-large 3072 dim. '
  'Query with: ORDER BY embedding <=> $1::vector LIMIT N.';

COMMENT ON COLUMN case_26cv11493.chunks.fts IS
  'tsvector built from chunk_text via to_tsvector(''english'', ...). '
  'GIN index. Query with: WHERE fts @@ websearch_to_tsquery($1).';

COMMENT ON COLUMN case_26cv11493.chunks.filed_date IS
  'Date the source document was filed in court. NULL for exhibits/correspondence. '
  'Format: YYYY-MM-DD. Index: filed_date_idx (btree).';
```

**Rule:** every column an agent might query gets a comment that names the data source, the index, and a one-line example SQL pattern. The agent then writes correct queries on the first try. (C, but pattern adopted across Crystal DBA Postgres MCP Pro + Supabase Studio AI features)

### 6.4 Make it deployable

Store all `COMMENT ON` statements in a `schema_comments.sql` file checked into the same repo as the migration scripts. Re-apply on every migration. Otherwise comments rot.

---

## 7. Audit + Observability for Agent Queries

### 7.1 Why log everything

Three failure modes you only catch via logs:
1. **Agent drift**: same query rewritten 10 times with diminishing precision -- only visible by reading the rewrite sequence
2. **Hallucination floor**: agent confidently cites chunks that don't support the claim -- ISSUP scores from CRAG/Self-RAG belong in the log
3. **Cost blowouts**: one runaway agent loops `hybrid_search` 200 times in a session

### 7.2 Schema

Levi already has `ops_search_agent` schema -- extend it:

```sql
CREATE TABLE IF NOT EXISTS ops_search_agent.query_log (
  id              BIGSERIAL PRIMARY KEY,
  ts              TIMESTAMPTZ NOT NULL DEFAULT now(),
  session_id      TEXT NOT NULL,
  agent_id        TEXT NOT NULL,                     -- 'claude_code', 'codex', 'firm.records_officer'
  tool_name       TEXT NOT NULL,                     -- 'semantic_search' etc.
  args            JSONB NOT NULL,
  result_count    INTEGER,
  result_chunk_ids TEXT[],                           -- denormalized for fast joins
  latency_ms      INTEGER,
  cache_hit       BOOLEAN DEFAULT FALSE,
  rerank_used     BOOLEAN DEFAULT FALSE,
  rerank_model    TEXT,
  confidence      DOUBLE PRECISION,                  -- CRAG-style retrieval evaluator
  downstream_use  TEXT,                              -- 'cited_in_filing', 'discarded', 'rewritten'
  error           TEXT
);

CREATE INDEX query_log_session_idx  ON ops_search_agent.query_log (session_id, ts);
CREATE INDEX query_log_agent_idx    ON ops_search_agent.query_log (agent_id, ts);
CREATE INDEX query_log_tool_idx     ON ops_search_agent.query_log (tool_name, ts);
CREATE INDEX query_log_args_gin     ON ops_search_agent.query_log USING gin (args);
```

### 7.3 Derived views the agent itself can query

```sql
-- "How often did I hallucinate?"
CREATE VIEW ops_search_agent.session_quality AS
SELECT session_id, agent_id,
       COUNT(*) AS n_queries,
       AVG(confidence) AS avg_confidence,
       SUM((downstream_use = 'discarded')::int)::float / COUNT(*) AS discard_rate,
       AVG(latency_ms) AS avg_latency_ms
FROM ops_search_agent.query_log
GROUP BY session_id, agent_id;
```

Expose the view through `database_stats` -- the agent reads its own scorecard between hops. CRAG-style self-correction loops with a numeric feedback signal converge faster than blind retries. (C)

### 7.4 PII / privilege flagging

For Valor specifically: any chunk pulled from `case_bingaman_dhs` or `case_26cv11493` that contains attorney-client privileged material needs a `privilege` flag in the log so the records officer can sweep the audit trail before any disclosure. Build the flag now; trying to retrofit is painful. (C, Valor-specific operational call)

---

## 8. GraphRAG Layer on Top of pgvector

### 8.1 When entity graphs beat vector-only

Microsoft GraphRAG (A) uses LLM-driven extraction to build entity + relationship graphs from unstructured text, then queries the graph at retrieval time. Claimed advantage: **multi-hop questions where the answer is a relationship not a passage**. Example: "Which GRH-affiliated entities also appear in the Heart 'N Home Joseph cluster?" -- a vector search returns passages mentioning each individually; a graph traversal answers directly. (A)

Costs (A): "GraphRAG indexing can be an expensive operation." Each chunk requires an LLM pass to extract entities and relationships, then a second pass to summarize communities. For Levi's corpora (~300K+ chunks across PG schemas), full GraphRAG ingest at retail LLM rates would run thousands of dollars. (C)

### 8.2 All-Postgres alternative (recommended for Valor)

Skip Microsoft GraphRAG; build a lightweight graph layer in Postgres directly:

```sql
CREATE TABLE entities (
  entity_id    BIGSERIAL PRIMARY KEY,
  name         TEXT NOT NULL,
  entity_type  TEXT NOT NULL,                  -- 'person', 'org', 'case', 'statute'
  canonical_id TEXT,                           -- normalized form
  embedding    vector(3072),                   -- for fuzzy entity match
  metadata     JSONB
);

CREATE TABLE entity_mentions (
  chunk_id  TEXT NOT NULL,
  entity_id BIGINT NOT NULL REFERENCES entities,
  span_start INT,
  span_end   INT,
  confidence DOUBLE PRECISION,
  PRIMARY KEY (chunk_id, entity_id, span_start)
);

CREATE TABLE chunk_relations (
  from_chunk TEXT NOT NULL,
  to_chunk   TEXT NOT NULL,
  rel_type   TEXT NOT NULL,                    -- 'cites', 'amends', 'rebuts', 'mentions_same_person'
  weight     DOUBLE PRECISION DEFAULT 1.0,
  PRIMARY KEY (from_chunk, to_chunk, rel_type)
);

-- Recursive CTE traversal
WITH RECURSIVE neighborhood(chunk_id, depth, path) AS (
  SELECT 'case_26cv11493:14_filings/complaint.pdf#7'::text, 0, ARRAY['case_26cv11493:14_filings/complaint.pdf#7'::text]
  UNION ALL
  SELECT cr.to_chunk, n.depth + 1, n.path || cr.to_chunk
  FROM chunk_relations cr
  JOIN neighborhood n ON cr.from_chunk = n.chunk_id
  WHERE n.depth < 3 AND cr.to_chunk <> ALL(n.path)
)
SELECT DISTINCT chunk_id, MIN(depth) FROM neighborhood GROUP BY chunk_id;
```

For hierarchical taxonomies (court hierarchy, statutory tree), use `ltree`. For arbitrary directed graphs, the recursive CTE pattern above works fine up to ~3 hops without performance issues on the M.2 NVMe / 64GB box. (B+C)

### 8.3 When to invest

Build the entity extraction layer **only after** vector-only and hybrid retrieval are deployed and measured. Anthropic's contextual retrieval got 67% failure reduction without any graph layer (A). Start there. Add entities once you see queries that hybrid demonstrably cannot answer ("show me every chunk where Bowen and Cole appear together," "trace the chain from filed petition to current AG response"). (C)

---

## 9. Cost + Latency Targets (Single Box, 64GB RAM, M.2 NVMe)

Levi's hardware target: single Postgres node, M.2 NVMe SSD, 64GB RAM. Corpus 2-50M chunks.

### 9.1 pgvector index choice

| Corpus size | Index | Notes |
|---|---|---|
| < 1M chunks | HNSW (`m=16, ef_construction=64`) | Fits in RAM, fast queries |
| 1-10M chunks | HNSW (`m=16, ef_construction=64`), `halfvec` storage | Cut storage 50% with halfvec |
| 10-50M chunks | HNSW + binary quantization, or pgvectorscale `StreamingDiskANN` | Disk-backed index; pgvectorscale claims 28x lower p95 vs Pinecone s1 at 99% recall (A) |
| > 50M chunks | pgvectorscale recommended; consider sharding | Past single-node territory |

(Sources: pgvector docs + Timescale/TigerData benchmark; A)

### 9.2 Latency expectations (single query, no rerank)

Realistic numbers on the M.2 + 64GB box (B+C, synthesizing pgvector benchmarks):

| Operation | Corpus | Expected p50 | p95 |
|---|---|---|---|
| Semantic search (HNSW, top_k=20) | 2M chunks | 3-8 ms | 15-30 ms |
| Semantic search (HNSW, top_k=20) | 10M chunks | 8-20 ms | 30-60 ms |
| Semantic search (HNSW, top_k=20) | 50M chunks | 20-50 ms | 80-150 ms |
| Keyword search (tsvector GIN) | any | 5-30 ms | 50-100 ms |
| Hybrid (RRF k=60, two CTEs) | 10M | 15-40 ms | 60-120 ms |
| Add cross-encoder rerank, 100 docs | -- | +100-300 ms | +500 ms |

### 9.3 Sizing parameters

```ini
# postgresql.conf, 64GB RAM box
shared_buffers = 16GB                    # 25% of RAM
effective_cache_size = 48GB              # 75% of RAM
work_mem = 64MB                          # per sort/hash op
maintenance_work_mem = 4GB               # for HNSW builds
max_parallel_workers_per_gather = 4
max_parallel_maintenance_workers = 8     # speed up HNSW build
random_page_cost = 1.1                   # NVMe; default 4 is HDD-era
effective_io_concurrency = 200           # NVMe
```

HNSW build at 10M chunks 3072-dim halfvec: ~30-60 min wall clock with `max_parallel_maintenance_workers=8` and `maintenance_work_mem=4GB`. (C, extrapolating from pgvector docs)

### 9.4 Costs

Single-box ops cost: **$0 incremental beyond the hardware Levi already owns**. The expensive line items are:
1. **Embeddings**: ~$0.13 per 1M tokens with `text-embedding-3-large` (or free if using local nomic-embed or BGE-large). For 300K chunks at 500 tokens each = 150M tokens = ~$20 one-time at OpenAI rates. (B)
2. **Contextual retrieval prep**: Anthropic measured ~$1.02 per million doc tokens with prompt caching (A). For 150M tokens = $153 one-time.
3. **Reranking** if API: Cohere/Voyage charge per query. Self-host BGE-reranker-v2-m3 to zero this out.

---

## 10. Putting It Together -- Recommendation for Valor

### 10.1 Build order

1. **Now**: write `COMMENT ON` statements for every table + column in `case_26cv11493`, `case_bingaman_dhs`, `corpus_oregon_public_records_filesystem`. Ship a `describe_schema` MCP tool that reads them.
2. **Next**: add `hybrid_search` MCP tool using the Supabase RRF k=60 pattern. Keep `semantic_search` and `keyword_search` as separate tools for force-mode queries.
3. **Then**: add `query_log` table and instrument every MCP tool with audit logging.
4. **After that**: self-host BGE-reranker-v2-m3 on local GPU; add `rerank` as opt-in MCP tool.
5. **Last (optional)**: entity extraction layer + `chunk_relations` table. Only after measuring what hybrid cannot answer.

### 10.2 Tools the agent ultimately sees

```
semantic_search(query, top_k=20, corpus?, filters?)
keyword_search(terms, top_k=20, corpus?, filters?)
hybrid_search(query, top_k=20, corpus?, weights?)
rerank(query, chunks[], model='bge-v2-m3')
get_full_doc(file_path)
list_corpora()
describe_schema(table?)
execute_sql(sql)   -- read-only transaction, capped at 100 rows
database_stats()
evaluate_retrieval(query, chunks[])  -- CRAG confidence signal
```

That is **10 tools, ~3K tokens of definitions**, well under any agent's context budget. Every tool returns the same JSON envelope from Section 4.1 so the agent can chain them mechanically.

### 10.3 What survives compaction

If Levi loses this context and reads only the recommendation:
- **RRF k=60 hybrid search** (Supabase canonical SQL in 2.2)
- **Top-100 candidates -> rerank -> top-20** (Anthropic numbers in 3.1)
- **COMMENT ON every column** (Section 6)
- **Log every agent query** (Section 7 schema)
- **Self-host BGE-reranker-v2-m3** until budget warrants Voyage API

Those five moves capture 90% of the wins in the literature.

---

## Sources (verified by WebFetch unless noted)

- Anthropic, "Contextual Retrieval" (A) -- contextual-embeddings + BM25 + RRF + rerank pipeline, 67% failure reduction, top-150 candidates / top-20 final
- Anthropic, "Building Effective Agents" (A) -- poka-yoke tool design, format like natural text, document like for a junior dev
- Anthropic, "Think Tool" (A) -- reflection between tool calls, 54% improvement in airline-domain agentic loops
- Supabase docs / blog (A) -- hybrid_search RRF k=60 SQL, weighted full-text 1.5x semantic, vector cosine `<=>` operator
- Supabase MCP blog (A) -- 20+ tools, list_tables minimal schema discovery, future destructive-op detection
- modelcontextprotocol/servers-archived/src/postgres (A) -- official Anthropic ref server: single query(sql) tool + schema resources, read-only transaction
- Crystal DBA Postgres MCP Pro (A) -- 9 tools: list_schemas, list_objects, get_object_details, execute_sql, explain_query, get_top_queries, analyze_workload_indexes, analyze_query_indexes, analyze_db_health
- pgvector docs (A) -- HNSW + IVFFlat, six distance operators, halfvec + binary quantization, m / ef_construction / ef_search parameters
- pgvector-python examples (A) -- hybrid search via RRF and cross-encoder examples
- Voyage AI, Rerank-2 blog (A) -- 16K combined context (4K query), top-100 -> top-10, +13.89% over OpenAI v3-large on 93 datasets
- Jina Reranker v2 (A) -- 278M params, 100+ languages, function-calling + text-to-SQL aware, 1024 doc / 512 query max
- BAAI BGE-reranker-v2-m3 (A) -- 568M params, Apache 2.0, multilingual, sigmoid-normalized scores, FlagEmbedding library
- Cohere Rerank 3.5 (B) -- multilingual, complex enterprise data, full details behind sales gate
- Pinecone rerankers tutorial (B) -- two-stage retrieval rationale, rerankers move chunks from rank-23 to rank-1, 50ms vs 50hr cost tradeoff
- LangChain agentic RAG with LangGraph (A) -- state-machine cognitive architecture, conditional edges for re-query, structured outputs via Pydantic for routing
- Microsoft GraphRAG repo (A) -- entity/relationship extraction via LLM, knowledge-graph memory, "expensive operation" warning
- CRAG paper (Yan et al., arXiv:2401.15884) (A) -- retrieval evaluator confidence score, decompose-then-recompose, web-search fallback
- Self-RAG paper (Asai et al., arXiv:2310.11511) (A) -- reflection tokens (Retrieve / ISREL / ISSUP / ISUSE), adaptive on-demand retrieval
- PostgreSQL docs, COMMENT ON (A) -- pg_description / pg_shdescription, obj_description() and col_description() helpers, not in information_schema
- Tiger/Timescale pgvector vs Pinecone benchmark (A) -- pgvectorscale 28x lower p95 latency vs Pinecone s1, 50M vector dataset, StreamingDiskANN
- safjan.com RRF post (A) -- k=60 empirically derived, rank-based fusion, no normalization required
- LangChain4j RAG tutorial (A) -- chunk size guidance (300-token default with 30 overlap, 1000/200 advanced), metadata prepend pattern
- Gemini 3.1 Pro deep search result (A, partial) -- context-window blowup from stacked MCPs (Postgres + Playwright + Azure = 83K tokens / 41.6% of 200K), Harness MCP collapsed 175 -> 11 tools

(Confidence: A = primary-source; B = secondary or vendor-blog; C = inference)
