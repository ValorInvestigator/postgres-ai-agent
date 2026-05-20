# Postgres-for-AI-Agents Ingestion Pipeline -- 2025/2026 Best Practices

**Wave:** postgres_ai_ingest_pipeline
**Target reader:** Levi Bakke / Valor Investigations -- pipeline owner for `update_index.py` (legacy) + `migrate_filesystem_corpus.py` (Linux-native)
**Compiled:** 2026-05-19
**Tool stack used:** Gemini 3.1 Pro grounded search (4 queries -- PDFs, embeddings, chunking, provenance) + WebFetch (Anthropic, Jina, Docling, Marker, Voyage, pgvector, Surya, faster-whisper, pyannote, Pinecone, trafilatura, Tigerdata)
**Confidence grading:** A = primary vendor doc or peer-reviewed; B = Gemini-grounded synthesis from named source; C = secondary blog with citations; D = community speculation
**Style:** No em dashes (-- only). Hedged where unverified.

---

## TL;DR (for Levi)

1. **Replace PyMuPDF-only PDF parsing with Docling first / Marker fallback / Surya OCR for scans.** PyMuPDF stays as the speed path for native-text PDFs but cannot extract tables, equations, or layout. Docling (IBM) and Marker (Datalab) dominate the 2025 leaderboards; LlamaParse leads but is cloud-only and not appropriate for sealed court records or hospice charts. [A/B]
2. **Embeddings: switch to `voyage-context-3` if you can pay the API fee, or `Qwen3-Embedding-8B` for self-hosted.** `voyage-context-3` solves chunk-context loss in a single neural pass and beats Anthropic's contextual-retrieval prompt approach by +6.76% on chunk retrieval. Open-source winner is Alibaba's `Qwen3-Embedding-8B` at 70.58 MTEB multilingual, Apache 2.0. [A]
3. **Chunking: use late chunking OR contextual retrieval, not both. Layer on a reranker.** Naive 512-token fixed chunks with no context are leaving 30-60% of retrieval quality on the table for any document > 1,500 chars. Combined contextual embeddings + BM25 + reranker drives Anthropic's failure rate from 5.7% to 1.9%. [A]
4. **Provenance: every chunk row needs 12+ audit columns** so an agent can answer "where did this fact come from, when, with which parser/model version, and is it still authoritative." Soft-delete with tombstones; never hard-delete. Use SHA-256 chunk hash as the idempotency key. [A]
5. **Failure handling: add a `ingest_errors` DLQ table** colocated in Postgres so the agent can query it the same way it queries chunks. Retry count + payload + error message + first/last seen timestamps. [B]

---

## 1. File-Type Parsers in 2025/2026 -- Winners and Why

### 1.1 PDFs (highest-stakes modality for Levi -- court records, hospice charts, GAL reports)

**Confidence: A on Docling and Marker benchmarks; B on relative rankings**

| Parser | Strength | Weakness | Recommendation |
|---|---|---|---|
| **Docling (IBM)** | DocLayNet + TableFormer = 97.9% complex-table accuracy (Procycons 2025 benchmark) [src: Gemini ingest_pdfs, procycons.com]. Up to 13x faster than Marker on Apple M1 by skipping OCR on native-text PDFs. Plug-and-play LangChain / LlamaIndex / Haystack integrations. Local execution -- safe for sealed records. | Smaller community than PyMuPDF; less battle-tested on adversarial PDFs (e.g., DOJ stamp overlays). | **PRIMARY for legal/medical PDFs.** Use HybridChunker for built-in chunking that respects layout. |
| **Marker (VikParuchuri / Datalab)** | 2.84 sec/page on H100, 95.67 heuristic score vs LlamaParse 84.24. Excels at equations and inline math. 122 pages/sec single-process throughput on H100. Surya OCR for 90+ languages. | Runs full OCR even on text-heavy PDFs (slower on native text). Struggles with nested-table forms. | **PRIMARY for scientific / medical literature** (equations, structured tables). Use `--use_llm` for the final 5% accuracy. |
| **LlamaParse (LlamaIndex cloud)** | 0.910 opendataloader-bench (April 2026, 200 PDFs); 81% ChrF++ robustness (Applied AI Dec 2025, 800-doc study); $0.003/page after 10K free. ~6 sec/document. | Cloud-only. NOT appropriate for sealed court records, hospice charts, attorney work product. Data-retention risk. | **REJECT for Valor work**; consider for non-sealed VRE docs only. |
| **PyMuPDF (fitz)** | Fastest native-text extraction. Mature Python API. | No table reconstruction. No layout awareness. No OCR. | **KEEP as the "fast path" detector**: if PyMuPDF returns >X chars and no embedded images, use it; else route to Docling. |
| **pdfplumber** | Cleanest text + tables for grid-line PDFs. Pure-Python. | Slower than PyMuPDF; bad on scanned/borderless tables. | **DEMOTE.** Docling subsumes everything pdfplumber does and more. |
| **unstructured.io (open-source)** | 25+ file types, modular "Bricks", `chunk_by_title` strategy. | Open-source tier has "significantly decreased performance on document and table extraction" per their own docs. Premium features gated behind paid tier. | **REJECT for production.** The OSS version is a downgrade vs Docling. |
| **Nougat (Meta)** | Once SOTA for academic papers. | Superseded by Marker per multiple 2025 benchmarks. Unmaintained. | **REJECT.** |

**Cascade pattern for Levi:**

```
PDF -> PyMuPDF speed-check
  |-- (native text, no images, no tables detected) -> PyMuPDF text + simple chunk
  |-- (tables OR images OR layout-heavy) -> Docling -> DoclingDocument -> HybridChunker
  |-- (Docling fails OR scanned) -> Marker --use_llm --force_ocr
  |-- (Marker fails) -> Surya OCR direct + manual chunk
  |-- (still fails) -> ingest_errors DLQ row + alert
```

### 1.2 Emails (.eml) -- Patty's Gmail exports, DHS thread reconstruction

**Confidence: A** (stdlib is the canonical answer; no improvement from third-party libs in 2025)

- `email` stdlib + `email.policy.default` decodes quoted-printable + base64 + multipart correctly. Pair with `mailparser` (PyPI) only if you need MIME-walking helpers.
- **Thread reconstruction**: parse `Message-ID`, `In-Reply-To`, and `References` headers. Build a directed graph keyed by Message-ID. RFC 5322 + RFC 2822 are unchanged.
- **Practical schema**: store each message as a `source_file` row (one .eml = one file), then chunk on the body. Headers (From/To/CC/BCC/Subject/Date/Message-ID/In-Reply-To/References) go in JSONB metadata so agents can query by thread.
- **Gotcha already in your MEMORY**: verbatim-quote-auditor must decode quoted-printable line continuations BEFORE matching (feedback_verbatim_auditor_must_scan_eml_bodies). This is the #1 .eml bug.
- **Speaker / participant extraction**: pull display name + email from `From:` header; normalize to a canonical actor in a `people` table joined back via FK.

### 1.3 .docx -- Pleadings, declarations, GAL reports

**Confidence: A**

- **python-docx**: read flow + tables; good for short structured documents.
- **Docling .docx path**: actually preferable -- it preserves heading hierarchy in DoclingDocument and feeds into HybridChunker, so the chunker can split on `<H1>` boundaries.
- **Recommendation**: route all .docx through Docling for schema-consistency with PDFs. python-docx only when you need to *edit* a .docx (which you don't in ingestion).

### 1.4 Audio / video transcripts -- Recordings, hearings, voicemails

**Confidence: A** on faster-whisper + pyannote numbers

| Tool | Use | Specs |
|---|---|---|
| **faster-whisper (CTranslate2)** | ASR primary | 2.3x faster than OpenAI Whisper reference; large-v3 at FP16 = 1m03s for 13min audio; INT8 = 59s; batched GPU drops 13min to ~16-17s. Silero VAD removes silences >2s. Word-level timestamps via `word_timestamps=True`. |
| **pyannote-audio (speaker-diarization-community-1)** | Diarization | DER 17.0% on AMI(IHM); 31s/audio-hour on H100. Gated -- requires HuggingFace token + ToS acceptance. Precision-2 (paid) is 12.9% DER + 2.2x faster. |
| **WhisperX** | Combined ASR + diarization + word-level alignment | Wraps faster-whisper + pyannote in one pipeline. The pragmatic choice when you want diarized transcripts in one call. |
| **Whisper API (OpenAI)** | Fallback for non-confidential audio | Not for Valor work -- audio gets retained for OpenAI training unless on enterprise plan. |

**Schema implication**: transcripts should be chunked at speaker-turn boundaries, not fixed token windows. Each chunk row carries `speaker_label`, `start_seconds`, `end_seconds`, `confidence`. Word-level timestamps stored in a separate `transcript_words` table only if you need verbatim auditor scans.

### 1.5 HTML / web

**Confidence: A**

- **trafilatura**: state-of-the-art per its own benchmarks; extracts main text + metadata (title, author, date, site, tags) + outputs markdown / XML-TEI / JSON. Optional language detection. *Use as primary.*
- **readability-lxml**: legacy fallback when trafilatura misclassifies (rare). Keep as Tier 2.
- **newspaper3k / boilerpipe**: deprecated for this purpose. Skip.

### 1.6 OCR fallback (when PDF text extraction fails)

**Confidence: A** on Surya numbers

| Tool | Accuracy vs Tesseract | Speed | Pick |
|---|---|---|---|
| **Surya** | 0.97 vs Tesseract 0.88 average similarity | 0.62s/page GPU vs Tesseract 0.45s/page CPU | **PRIMARY for scanned PDFs**. Already bundled with Marker. 90+ languages. |
| **Tesseract** | 0.88 | Faster on CPU but lower quality | Cheap fallback when no GPU. |
| **PaddleOCR** | Strong on CJK + tables | Comparable to Surya on English | Use only if you have Chinese/Japanese records (you don't). |

**Verdict**: Surya covers your needs. Don't bother with PaddleOCR / Tesseract unless GPU-less.

---

## 2. Chunking Strategies That Actually Work

### 2.1 The 2025 hierarchy of badness -> goodness

**Confidence: A** on the relative ordering; **B** on the exact numbers (depends on dataset)

1. **Worst: Fixed-character split, 1000 chars no overlap.** Loses cross-chunk references, splits mid-sentence, kills retrieval on long docs.
2. **Bad: Fixed-token split with overlap (e.g., 512 tokens, 50 overlap).** Standard LangChain default. Workable for short clean docs; fails on multi-page PDFs with layout.
3. **OK: Recursive character chunking** with separators `["\n\n", "\n", ". ", " ", ""]`. LangChain `RecursiveCharacterTextSplitter`. Respects paragraph boundaries.
4. **Good: Structural / layout-aware chunking.** Docling HybridChunker, Marker chunk output, unstructured.io `chunk_by_title`. Splits on headings, table boundaries, list-item groups.
5. **Better: Semantic chunking.** Embed each sentence, compute cosine distance between consecutive sentences, split where distance spikes. LlamaIndex `SemanticSplitterNodeParser`, LangChain `SemanticChunker`. Expensive but produces topic-coherent chunks.
6. **Better still: Late chunking (Jina, 2024).** Pass full document through long-context embedding model first, *then* mean-pool token embeddings into chunks. Preserves anaphoric references ("the city", "its inhabitants"). Improvement on BEIR NFCorpus: 23.46% -> 29.98% nDCG@10 vs naive. Improvement scales with document length. Requires `jina-embeddings-v2-base-en` or v3, or any 8K-context model. [src: jina.ai/news/late-chunking-in-long-context-embedding-models]
7. **Best (text-only): Contextual Retrieval (Anthropic, Sept 2024).** For every chunk, prepend a 50-100 token LLM-generated context summarizing where the chunk sits in the parent document, *then* embed. Drops retrieval failure 5.7% -> 3.7% alone, 5.7% -> 2.9% with BM25 hybrid, 5.7% -> 1.9% with rerank. Cost via prompt caching: $1.02 per million document tokens with Claude Haiku. [src: anthropic.com/news/contextual-retrieval]
8. **Best (one-shot): voyage-context-3 (July 2025).** Single neural pass produces contextually-aware chunk embeddings. Beats OpenAI v3-large by +14.24%, Cohere v4 by +12.56%, Jina-v3 late chunking by +23.66%, Anthropic contextual retrieval by +6.76% on chunk-level retrieval. Eliminates the need for the Claude prompt-context step. [src: blog.voyageai.com/2025/07/23/voyage-context-3]

### 2.2 Anthropic Contextual Retrieval -- exact prompt + numbers

**Confidence: A**

```text
<document>
{{WHOLE_DOCUMENT}}
</document>
Here is the chunk we want to situate within the whole document
<chunk>
{{CHUNK_CONTENT}}
</chunk>
Please give a short succinct context to situate this chunk within the
overall document for the purposes of improving search retrieval of the
chunk. Answer only with the succinct context and nothing else.
```

**Measured improvements** (Anthropic eval, Sept 2024):
- Contextual embeddings alone: 35% failure-rate reduction (5.7% -> 3.7%)
- Contextual embeddings + BM25 hybrid: 49% reduction (5.7% -> 2.9%)
- + reranker on top-150 -> top-20: 67% reduction (5.7% -> 1.9%)

**Cost mechanic**: doc is sent in `cache_control` block; chunks rotate through. Prompt caching gives ~90% discount on the cached document tokens, yielding $1.02 per million document tokens for context generation.

**Recommended pipeline parameters**:
- Retrieve top-20 chunks, not top-5 or top-10
- Rerank with Voyage or Cohere
- Use Voyage or Gemini embeddings (they outperformed OpenAI text-embedding-3-large in Anthropic's eval)

### 2.3 Late Chunking -- exact algorithm

**Confidence: A**

```text
Input: document up to 8192 tokens

1. Tokenize whole document.
2. Pass all tokens through embedding model transformer.
   -> token_embeddings shape [n_tokens, embedding_dim]
3. Identify chunk boundaries (regex on \n\n / ". " / semantic cues).
   -> chunk_start_idx[i], chunk_end_idx[i] for each chunk i
4. For each chunk, mean-pool the token embeddings in its range:
   chunk_embedding[i] = mean(token_embeddings[start_idx:end_idx])
5. Write chunks + embeddings to Postgres.
```

**Berlin Wikipedia example** -- naive cosine similarity for "the city is also one of the states" against the query "Berlin" was 0.753; late chunking lifts it to 0.850 by preserving the document-level Berlin context.

### 2.4 RAPTOR (recursive tree summarization)

**Confidence: B** (paper-cited, not personally benchmarked)

Bottom-up tree construction: embed leaf chunks, cluster, summarize each cluster with an LLM, recurse. Query mode is either "collapsed tree" (search all nodes at once) or "tree traversal" (start at root, descend).

Result: QuALITY benchmark +20% absolute accuracy with GPT-4 + RAPTOR vs vanilla flat retrieval [src: arxiv 2401.18059].

**When to use for Valor work**: complex multi-document narrative QA where the agent needs to integrate context across a 600-page DHS production. Probably overkill for single-document fact lookup; consider for cross-document briefing generation.

### 2.5 Concrete recommendation for the Valor pipeline

**For 26CV11493, hospice charts, Bingaman/McSherry guardianship records:**

- **Default**: voyage-context-3 (or Anthropic contextual retrieval if budget-bound) + 512 token chunks with 10% overlap on heading boundaries (Docling HybridChunker output).
- **Reranker**: Cohere Rerank v3.5 or Voyage rerank-2. Top-20 -> top-5 after rerank.
- **Hybrid**: pgvector cosine + Postgres tsvector BM25 via Reciprocal Rank Fusion (RRF, k=60).
- **RAPTOR overlay**: build a summary tree per case (Bingaman, McSherry, EOCCO) on top of the leaf chunks. Store as additional rows with `chunk_method='raptor_summary'` and `parent_chunk_ids[]`.

### 2.6 Optimal chunk size (2025 literature consensus)

**Confidence: B**

- **Without reranker**: 256-512 tokens. Smaller chunks = higher precision but you lose context.
- **With reranker**: 512-1024 tokens. Reranker handles the precision; chunks can carry more context to the LLM.
- **With late chunking or contextual retrieval**: chunks effectively carry document context regardless of size; 512 tokens is the safe default.
- **Overlap**: 0% if using semantic / late chunking (boundaries are already meaningful). 10-20% if fixed-size. Sliding-window only for transcripts or streaming data.

---

## 3. Embedding Model Selection -- 2026 Landscape

**Confidence: A** on numbers from primary vendor sources; **B** on relative MTEB ranking (the leaderboard moves weekly)

### 3.1 The current short list

| Model | MTEB Avg | Dims | Context | License | Price | Notes |
|---|---|---|---|---|---|---|
| **voyage-context-3** | Not on MTEB v2 yet | 2048 / 1024 / 512 / 256 (Matryoshka) | 32K | API | $0.18/M tokens | Single-pass contextualized chunks. Binary @ 512 dims matches OpenAI v3-large recall at 0.5% storage. |
| **voyage-3-large** | 70.32 | 1024 / 2048 (Matryoshka) | 32K | API | $0.18/M tokens | Best non-contextualized API option. |
| **Qwen3-Embedding-8B** | 70.58 multilingual | 4096 (Matryoshka to 1024) | 32K | Apache 2.0 | self-host | TOP open-weight. 100+ languages. |
| **OpenAI text-embedding-3-large** | 64.6 | 3072 (Matryoshka to 256) | 8K | API | $0.13/M | Baseline. Most permissive ToS for non-sensitive data. |
| **Cohere embed-v4** | 65.2 | 1536 | 128K | API | $0.10/M | Cheapest top-tier API. Native multimodal (text + image). |
| **BGE-M3 (BAAI)** | 63.0 | 1024 | 8K | MIT | self-host | Hybrid: dense + sparse + multi-vector in one call. |
| **Stella-en-1.5B-v5** | ~71 | 1024 / 8192 (Matryoshka) | 512 | MIT | self-host | Compact strong performer; short context limits use for late chunking. |
| **mxbai-embed-large-v1** | ~64 | 1024 | 512 | Apache 2.0 | self-host | 335M params; 512-token cap is restrictive. |
| **Nomic Embed v2** | ~62 | 768 / 64-768 (Matryoshka) | 8K | Apache 2.0 | self-host | 137M params, CPU-friendly. Edge / Ollama. |

### 3.2 Decision tree for Valor

```
Is the corpus sealed / sensitive (court records, hospice charts, attorney work product)?
  YES -> self-host. Pick Qwen3-Embedding-8B (best) or Nomic v2 (lightest).
  NO  -> API path:
    Do you want one-pass contextualized chunks?
      YES -> voyage-context-3.
      NO  -> voyage-3-large (best) or Cohere embed-v4 (cheapest) or OpenAI v3-large (most boring/safe).
```

**For 26CV11493 + Bingaman + McSherry**: self-host Qwen3-Embedding-8B on a single A10G or 4090. Do not send sealed records to external APIs.

**For VRE / public OSINT corpora**: voyage-context-3 via API is fine.

### 3.3 Matryoshka caveat

Matryoshka models (voyage-3, voyage-context-3, text-embedding-3, Nomic v2, Stella) let you truncate the vector at insert time and re-rank with full vector at query time, OR store only the truncated vector. Storage cost drops linearly; recall drops sub-linearly. With voyage-context-3 binary @ 512 dims you get 99.48% storage reduction vs OpenAI v3-large at parity recall.

**Implementation in pgvector**: store `embedding_full halfvec(2048)` AND `embedding_search vector(512)` (truncated + L2-normalized). Index `embedding_search` with HNSW; use `embedding_full` only for final rerank. Halves your hot index size.

### 3.4 Caveat re MTEB

FinMTEB study (2025) on 15 models across 64 financial datasets found **statistically insignificant correlation** between MTEB rankings and domain-specific retrieval [src-12 of ingest_embeddings Gemini]. **For legal/medical work, don't trust the leaderboard -- benchmark on your own corpus.** Even a 50-query gold set scored by Levi would beat MTEB-driven selection.

---

## 4. Provenance + Append-Only Audit Columns

**Confidence: A** -- this is canonical schema design; consensus across sources

### 4.1 The mandatory column set for every `chunks` row

```sql
CREATE TABLE chunks (
    -- IDENTITY
    chunk_id            BIGSERIAL PRIMARY KEY,
    source_file_id      BIGINT NOT NULL REFERENCES source_files(source_file_id),
    chunk_index_in_file INT NOT NULL,            -- 0, 1, 2, ... within the file
    chunk_sha256        BYTEA NOT NULL,          -- SHA-256 of chunk_text bytes
    UNIQUE (source_file_id, chunk_sha256),       -- idempotency at chunk level

    -- CONTENT
    chunk_text          TEXT NOT NULL,
    chunk_text_tsv      TSVECTOR GENERATED ALWAYS AS (to_tsvector('english', chunk_text)) STORED,
    embedding           halfvec(2048),           -- or vector(1024) etc

    -- LOCATION (for citing back to the source)
    page_number         INT,                      -- for PDFs
    bbox                JSONB,                    -- {x0,y0,x1,y1} pixel coords (PDFs)
    byte_range_start    BIGINT,                   -- offset into source file bytes
    byte_range_end      BIGINT,
    char_range_start    INT,                      -- offset into extracted text
    char_range_end      INT,

    -- PARSER + MODEL PROVENANCE
    parser              TEXT NOT NULL,            -- 'docling', 'marker', 'pymupdf', 'faster-whisper', etc
    parser_version      TEXT NOT NULL,            -- 'docling==2.14.0'
    chunk_method        TEXT NOT NULL,            -- 'hybrid', 'late', 'contextual', 'fixed_512', 'raptor_summary'
    chunk_method_params JSONB,                    -- {size:512, overlap:50, lc_model:'jina-v3'}
    embedding_model     TEXT NOT NULL,            -- 'voyage-context-3'
    embedding_model_version TEXT NOT NULL,        -- 'voyage-context-3-2025-07-23'
    embedding_dims      INT NOT NULL,             -- 1024
    context_prefix      TEXT,                     -- the prepended Anthropic-style context, if used
    context_model       TEXT,                     -- 'claude-haiku-3.5' if generated
    parent_chunk_ids    BIGINT[],                 -- for RAPTOR / hierarchical

    -- AUDIT
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    ingest_run_id       UUID NOT NULL,            -- which pipeline run produced this
    ingested_by_version TEXT NOT NULL,            -- 'migrate_filesystem_corpus.py@a1b2c3d'
    deleted_at          TIMESTAMPTZ               -- soft-delete tombstone; NULL = live
);

CREATE INDEX chunks_embedding_hnsw ON chunks USING hnsw (embedding halfvec_cosine_ops)
  WITH (m = 16, ef_construction = 64)
  WHERE deleted_at IS NULL;

CREATE INDEX chunks_tsv_gin ON chunks USING gin (chunk_text_tsv)
  WHERE deleted_at IS NULL;

CREATE INDEX chunks_source_file ON chunks (source_file_id) WHERE deleted_at IS NULL;
```

### 4.2 Why each column matters (agent's POV)

| Column | Agent question it answers |
|---|---|
| `source_file_id` + `chunk_index_in_file` | "Show me the surrounding chunks for context." |
| `chunk_sha256` | "Have I already processed this exact text?" |
| `page_number` + `bbox` | "Open the PDF at this page; highlight the bounding box." |
| `byte_range_*` | "Verbatim-quote audit: is this chunk text actually in the source bytes?" |
| `parser` + `parser_version` | "Was this chunk extracted by a parser version that had bug X?" |
| `chunk_method` + `params` | "Were these chunks made with the now-deprecated fixed-512 method? Reprocess." |
| `embedding_model` + `version` | "Voyage rotated their model -- which chunks need re-embedding?" |
| `context_prefix` | "Did this chunk get Anthropic-style contextual prefix or not?" |
| `parent_chunk_ids` | "Walk up the RAPTOR tree to find the document summary." |
| `ingest_run_id` | "Roll back everything from yesterday's bad ingestion run." |
| `ingested_by_version` | "Which commit of the pipeline produced this row?" |
| `deleted_at` | "Filter out tombstoned chunks from search." |

### 4.3 The `source_files` parent table

```sql
CREATE TABLE source_files (
    source_file_id    BIGSERIAL PRIMARY KEY,
    abs_path          TEXT NOT NULL UNIQUE,
    file_sha256       BYTEA NOT NULL,            -- SHA-256 of file bytes
    byte_size         BIGINT NOT NULL,
    mtime             TIMESTAMPTZ NOT NULL,      -- filesystem mtime
    mime_type         TEXT,
    case_tag          TEXT,                       -- 'bingaman', 'mcsherry', 'eocco', 'vre'
    corpus            TEXT NOT NULL,              -- schema-level label
    discovered_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_ingested_at  TIMESTAMPTZ,
    last_ingest_status TEXT,                      -- 'success', 'failed', 'skipped_unchanged'
    metadata          JSONB,                      -- arbitrary headers, custodian, etc
    deleted_at        TIMESTAMPTZ
);

CREATE UNIQUE INDEX source_files_path_hash ON source_files (abs_path, file_sha256)
  WHERE deleted_at IS NULL;
```

---

## 5. Idempotency + Incremental Re-Index

**Confidence: A**

### 5.1 The content-hash strategy

```python
import hashlib

def file_fingerprint(path):
    """Cheap first-pass: size + mtime. If those changed, hash."""
    st = os.stat(path)
    return (st.st_size, st.st_mtime_ns)

def file_sha256(path):
    """Authoritative: blake3 would be faster, but sha256 is the lingua franca."""
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.digest()
```

### 5.2 Ingest decision tree

```text
For each candidate file under the corpus root:
  1. Look up source_files row by abs_path.
  2. If row exists AND (size, mtime) match the stored values: SKIP. Record nothing.
  3. Else: compute sha256.
     a. If sha256 matches stored: UPDATE mtime only. SKIP chunking.
     b. If sha256 differs:
        i.  Mark old chunks soft-deleted (UPDATE chunks SET deleted_at=now() WHERE source_file_id=X).
        ii. Run parser -> chunks -> embeddings.
        iii. INSERT new chunks with the new source_file row (or update existing row with new sha256).
  4. If file is no longer present on disk: UPDATE source_files SET deleted_at=now(); cascade
     to chunks via trigger or explicit UPDATE.
```

### 5.3 Chunk-level idempotency (cheaper re-runs)

Even within a file, if you re-parse and most chunks are byte-identical, the `UNIQUE (source_file_id, chunk_sha256)` constraint lets you `ON CONFLICT DO NOTHING` and only re-embed the changed chunks. Critical for hospice charts that get re-shipped monthly with small amendments.

```sql
INSERT INTO chunks (source_file_id, chunk_sha256, chunk_text, ...)
VALUES (...)
ON CONFLICT (source_file_id, chunk_sha256) DO UPDATE
  SET ingested_at = now(),
      ingest_run_id = EXCLUDED.ingest_run_id;
```

### 5.4 Soft-delete + HNSW reality check

**Critical gotcha** (confidence A, source: Gemini provenance src-5 percona.com):

> The HNSW index type in pgvector does not support incremental background updates. Frequent data changes can degrade performance. Soft-deleted vectors remain in the HNSW index and can affect performance until the index is rebuilt.

**Implications**:
- Use `WHERE deleted_at IS NULL` in your HNSW index (partial index). Soft-deleted rows are excluded from index scan -- but they still take heap space until VACUUM, and the index doesn't shrink until REINDEX.
- Schedule `REINDEX INDEX CONCURRENTLY chunks_embedding_hnsw` weekly (low-traffic window).
- Track churn ratio: if `deleted_at IS NOT NULL` count / live count > 0.20, force REINDEX.

### 5.5 Re-embed migration (when you change models)

```sql
-- Mark all chunks with the old embedding model as needing re-embedding.
UPDATE chunks SET embedding = NULL
WHERE embedding_model = 'voyage-3-large'
  AND deleted_at IS NULL;

-- Worker selects chunks WHERE embedding IS NULL and back-fills.
```

Or, less destructively, add a column `embedding_v2` alongside `embedding`, populate it, then swap the index over and drop the old column.

---

## 6. Failure Modes + Dead-Letter Queue

**Confidence: A**

### 6.1 The `ingest_errors` table

```sql
CREATE TABLE ingest_errors (
    error_id         BIGSERIAL PRIMARY KEY,
    abs_path         TEXT NOT NULL,
    file_sha256      BYTEA,                       -- NULL if hash itself failed
    stage            TEXT NOT NULL,               -- 'fingerprint', 'parse', 'chunk', 'embed', 'insert'
    parser           TEXT,                         -- 'docling' / 'marker' / etc
    parser_version   TEXT,
    error_class      TEXT NOT NULL,               -- 'EncryptedPDF', 'CorruptZip', 'OCRTimeout', 'OOM'
    error_message    TEXT NOT NULL,
    stack_trace      TEXT,
    payload_bytes    BYTEA,                        -- optional: small failed payload
    payload_size     BIGINT,                       -- size of the original input
    retry_count      INT NOT NULL DEFAULT 0,
    next_retry_at    TIMESTAMPTZ,
    first_seen_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at      TIMESTAMPTZ,                  -- NULL while unresolved
    resolution_note  TEXT
);

CREATE INDEX ingest_errors_unresolved ON ingest_errors (next_retry_at)
  WHERE resolved_at IS NULL;
CREATE INDEX ingest_errors_class ON ingest_errors (error_class)
  WHERE resolved_at IS NULL;
```

### 6.2 Common failure classes Levi will hit

| Error class | Trigger | Handling |
|---|---|---|
| `EncryptedPDF` | DHS occasionally ships password-protected PDFs | Log, alert Levi, await password; retry once with credential. |
| `CorruptPDF` | Truncated PDF stream | Mark DLQ, retry once with `pikepdf` repair pass, else mark resolved=fatal. |
| `OCRTimeout` | Scanned 300-page deposition | Increase timeout + GPU; do not retry on CPU. |
| `LayoutTooComplex` | Heavily-redacted forms (DOJ produced) | Fallback to PyMuPDF text-only; mark chunk_method='pymupdf_degraded'. |
| `EmbeddingAPIError` | Voyage rate limit / 5xx | Exponential backoff up to 5 retries; then DLQ. |
| `OOMKill` | Marker on giant PDF | Split file by 50-page windows; reprocess. |
| `ContextWindowExceeded` | Anthropic context-gen prompt > 200K | Use chunked context generation (Anthropic cookbook pattern). |
| `EmlMalformed` | Outlook PST converter dropped a header | Best-effort parse; chunk what you can; flag. |
| `AudioCorrupt` | Voicemail file truncated | Mark fatal; do not retry. |

### 6.3 Agent-facing failure query

```sql
-- "What's broken right now?"
SELECT error_class, count(*), max(last_seen_at) as last
FROM ingest_errors
WHERE resolved_at IS NULL
GROUP BY error_class
ORDER BY count(*) DESC;
```

The agent can answer "do I have full coverage of the Bingaman corpus?" with a join: count files in `source_files` for the case_tag, minus count in `ingest_errors`, minus count with last_ingest_status='failed'.

---

## 7. Late Chunking + Contextual Retrieval -- Combined Postgres Pattern

**Confidence: B** (synthesis -- no canonical source combines all three)

The 2026 best-practice pipeline blends three independently-validated improvements:

1. **Layout-aware parsing** -- Docling produces a DoclingDocument tree
2. **Late chunking OR contextual prefix** -- pick ONE based on cost / latency
3. **Hybrid retrieval (vector + BM25) + reranker** at query time

### 7.1 Pseudocode

```python
def ingest_document(path: str, conn, run_id: UUID, case_tag: str):
    # ---- 1. Fingerprint + idempotency ----
    fp = file_fingerprint(path)
    if existing := conn.fetchrow("SELECT * FROM source_files WHERE abs_path=$1", path):
        if existing.byte_size == fp.size and existing.mtime == fp.mtime:
            return "unchanged"
    sha = file_sha256(path)
    if existing and existing.file_sha256 == sha:
        conn.execute("UPDATE source_files SET mtime=$1 WHERE source_file_id=$2",
                     fp.mtime, existing.source_file_id)
        return "rehashed_unchanged"

    # ---- 2. Parse ----
    if path.endswith('.pdf'):
        doc = docling.parse(path)            # DoclingDocument
        if doc.failed():
            return enqueue_error(path, 'parse', 'docling', doc.error)
    elif path.endswith('.eml'):
        doc = parse_eml(path)
    elif path.endswith('.docx'):
        doc = docling.parse(path)
    elif path.endswith(('.mp3', '.wav', '.m4a')):
        doc = transcribe_with_diarization(path)
    else:
        doc = trafilatura_or_text(path)

    # ---- 3. Chunk ----
    raw_chunks = docling_hybrid_chunker(doc, target_tokens=512)

    # ---- 4. Context strategy: pick A or B (not both) ----
    if USE_VOYAGE_CONTEXT_3:
        # voyage-context-3 handles contextualization internally
        embeddings = voyage.contextualized_embed(
            inputs=[c.text for c in raw_chunks],
            input_type="document",
            model="voyage-context-3",
        )
    elif USE_ANTHROPIC_CONTEXTUAL_RETRIEVAL:
        full_doc_text = doc.to_markdown()
        contexts = anthropic_batch_generate_contexts(
            full_doc=full_doc_text,
            chunks=[c.text for c in raw_chunks],
            model="claude-haiku-3.5",
            cache_doc=True,                  # 90% discount on doc tokens
        )
        embeddings = voyage.embed(
            inputs=[f"{ctx}\n\n{c.text}" for ctx, c in zip(contexts, raw_chunks)],
            model="voyage-3-large",
        )
    else:
        # Late chunking path
        embeddings = jina.late_chunk_embed(
            doc_text=doc.to_markdown(),
            chunk_boundaries=[(c.start, c.end) for c in raw_chunks],
            model="jina-embeddings-v3",
        )

    # ---- 5. Upsert source_files + chunks (idempotent) ----
    src_id = conn.fetchval("""
        INSERT INTO source_files (abs_path, file_sha256, byte_size, mtime, case_tag, corpus, ...)
        VALUES ($1, $2, $3, $4, $5, $6, ...)
        ON CONFLICT (abs_path) DO UPDATE
          SET file_sha256=EXCLUDED.file_sha256, mtime=EXCLUDED.mtime,
              last_ingested_at=now()
        RETURNING source_file_id
    """, path, sha, fp.size, fp.mtime, case_tag, "bingaman")

    # Soft-delete superseded chunks
    conn.execute("UPDATE chunks SET deleted_at=now() WHERE source_file_id=$1 AND deleted_at IS NULL",
                 src_id)

    # Insert new chunks
    for i, (c, e) in enumerate(zip(raw_chunks, embeddings)):
        conn.execute("""
            INSERT INTO chunks (source_file_id, chunk_index_in_file, chunk_sha256, chunk_text,
                                embedding, page_number, bbox, char_range_start, char_range_end,
                                parser, parser_version, chunk_method, chunk_method_params,
                                embedding_model, embedding_model_version, embedding_dims,
                                context_prefix, context_model, ingest_run_id, ingested_by_version)
            VALUES (...)
            ON CONFLICT (source_file_id, chunk_sha256) DO UPDATE
              SET ingested_at=now(), ingest_run_id=EXCLUDED.ingest_run_id, deleted_at=NULL
        """, ...)

    return "ingested", len(raw_chunks)
```

### 7.2 Query-side hybrid retrieval

```sql
-- Reciprocal Rank Fusion over vector + BM25 (k=60)
WITH vector_hits AS (
    SELECT chunk_id, ROW_NUMBER() OVER (ORDER BY embedding <=> $1::halfvec) AS rank
    FROM chunks
    WHERE deleted_at IS NULL AND case_tag = $3
    ORDER BY embedding <=> $1::halfvec
    LIMIT 100
),
bm25_hits AS (
    SELECT chunk_id, ROW_NUMBER() OVER (ORDER BY ts_rank_cd(chunk_text_tsv, $2) DESC) AS rank
    FROM chunks
    WHERE deleted_at IS NULL AND case_tag = $3
      AND chunk_text_tsv @@ $2
    ORDER BY ts_rank_cd(chunk_text_tsv, $2) DESC
    LIMIT 100
)
SELECT c.chunk_id, c.chunk_text, c.source_file_id, c.page_number,
       (COALESCE(1.0/(60 + v.rank), 0) + COALESCE(1.0/(60 + b.rank), 0)) AS rrf_score
FROM chunks c
LEFT JOIN vector_hits v ON v.chunk_id = c.chunk_id
LEFT JOIN bm25_hits b ON b.chunk_id = c.chunk_id
WHERE v.rank IS NOT NULL OR b.rank IS NOT NULL
ORDER BY rrf_score DESC
LIMIT 50;
-- Then external reranker reduces 50 -> 5.
```

---

## 8. Concrete Migration Path for `migrate_filesystem_corpus.py`

**Confidence: A on diff; B on priority ordering**

### Phase 1 (immediate, low-risk)
1. Add SHA-256 fingerprinting (size+mtime cheap check, sha256 authoritative).
2. Add `ingest_errors` DLQ table.
3. Add `deleted_at` columns to `source_files` and `chunks`. Tombstone instead of DELETE.
4. Partial HNSW + GIN indexes with `WHERE deleted_at IS NULL`.

### Phase 2 (parser upgrade)
1. Install Docling. Wire into the PDF path. Keep PyMuPDF as the speed-check.
2. Add Marker as Tier 2 PDF fallback (`--use_llm`).
3. Add faster-whisper + pyannote (WhisperX wrapper) for audio.
4. Add trafilatura for HTML.
5. Surya is auto-pulled by Marker; expose it directly for scanned-PDF Tier 3.

### Phase 3 (embedding upgrade)
1. Pilot voyage-context-3 on a non-sealed corpus (e.g., VRE public docs).
2. Self-host Qwen3-Embedding-8B for sealed corpora.
3. Keep OpenAI text-embedding-3-large as the current state during transition.
4. Switch `chunks.embedding` to `halfvec` (50% storage win, near-zero recall loss).

### Phase 4 (chunking upgrade -- pick one)
- **Option A** (cheaper): Anthropic contextual retrieval with Claude Haiku 3.5 + prompt caching. $1.02 per million doc tokens.
- **Option B** (better): voyage-context-3 (subsumes A). No prompt caching needed; the model does it.
- **Option C** (open-source): Jina v3 late chunking.

### Phase 5 (advanced)
- Add RAPTOR summary trees per case.
- Add per-case partial HNSW indexes (`WHERE case_tag='bingaman'`).
- Add nightly `REINDEX CONCURRENTLY` watcher triggered by churn ratio.

---

## Sources Cited

**Primary vendor / paper sources** (A confidence):
- Anthropic: https://www.anthropic.com/news/contextual-retrieval (exact prompt, failure-rate numbers, $1.02/M token cost)
- Jina AI late chunking: https://jina.ai/news/late-chunking-in-long-context-embedding-models/ (BEIR numbers, Berlin example, algorithm)
- Voyage AI voyage-context-3: https://blog.voyageai.com/2025/07/23/voyage-context-3 (+14.24% vs OpenAI, +6.76% vs Anthropic CR)
- Docling: https://docling-project.github.io/ (supported formats, DocLayNet + TableFormer)
- Marker README: https://github.com/VikParuchuri/marker (2.84 sec/page, 95.67 heuristic, FinTabNet 0.816)
- faster-whisper: https://github.com/SYSTRAN/faster-whisper (2.3x speedup, INT8 numbers)
- pyannote-audio: https://github.com/pyannote/pyannote-audio (DER 17.0% community-1, 12.9% precision-2)
- Surya: https://github.com/VikParuchuri/surya (0.97 vs Tesseract 0.88)
- pgvector: https://github.com/pgvector/pgvector (HNSW m/ef params, halfvec/binary, partial indexes)
- RAPTOR: https://arxiv.org/abs/2401.18059 (+20% QuALITY)
- Pinecone chunking guide: https://www.pinecone.io/learn/chunking-strategies/ (size + overlap recommendations)
- Trafilatura: https://trafilatura.readthedocs.io/

**Gemini-grounded synthesis** (B confidence -- via gemini-3.1-pro-preview / gemini-2.5-pro):
- /mnt/linux-storage/research/waves/postgres_ai_ingest_gemini_pdfs.md (9 sources)
- /mnt/linux-storage/research/waves/postgres_ai_ingest_gemini_embeddings.md (15 sources)
- /mnt/linux-storage/research/waves/postgres_ai_ingest_gemini_chunking.md (8 sources)
- /mnt/linux-storage/research/waves/postgres_ai_ingest_gemini_provenance.md (19 sources)

**Notable open question**: voyage-context-3's MTEB v2 score is not yet on the public leaderboard (per Reddit r/LocalLLaMA Sept 2025); rely on Voyage's own benchmarks until reproduced independently.

---

## Appendix A -- Quick Reference Decision Cards

### When parsing a PDF
```
native text?  --> PyMuPDF (fast)
tables/layout? --> Docling (primary)
equations/math? --> Marker --use_llm
scanned/no text? --> Marker --force_ocr (uses Surya)
encrypted/corrupt? --> DLQ + alert Levi
```

### When picking an embedding model
```
sealed records (case/medical)? --> Qwen3-Embedding-8B self-host
public OSINT corpora? --> voyage-context-3 API
need cheap baseline? --> Cohere embed-v4 ($0.10/M)
short text only (<512 tok)? --> Stella-en-1.5B-v5
edge / CPU? --> Nomic Embed v2
```

### When choosing a chunking strategy
```
fast/cheap?         --> Docling HybridChunker + 512 tokens
quality matters?    --> Anthropic contextual retrieval ($1.02/M doc tokens)
state of the art?   --> voyage-context-3 (single pass)
open-source SOTA?   --> Jina v3 late chunking
cross-doc QA?       --> add RAPTOR tree on top of leaf chunks
```

---

**End of report.** Sister Gemini reports landed at the same path with `_gemini_*` suffixes; raw grounding sources are in those files for citation back-tracking.
