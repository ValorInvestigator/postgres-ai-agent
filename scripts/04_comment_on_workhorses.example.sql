-- 04_comment_on_workhorses.example.sql
-- Per PLAYBOOK Section 0 Move 3 + Section 7
-- Confidence grade: A (pg_description is core Postgres; agents demonstrably use it)
--
-- *** EXAMPLE / REFERENCE TEMPLATE -- DO NOT RUN UNMODIFIED ***
--
-- Adds COMMENT ON metadata for the four workhorse schemas + their key tables/columns.
-- Agents reading pg_description write drastically better SQL on first try.
--
-- This script is preserved here as a worked-example template using Valor's specific
-- schema names (case_26cv11493, case_bingaman_dhs, ops_gmail, etc). Running it
-- unmodified will ABORT on the first COMMENT ON for a schema/table that does not
-- exist on your cluster. That is intentional: it forces you to adapt the comments
-- to your own deployment.
--
-- HOW TO ADAPT
--   1. Copy this file to scripts/04_comment_on_workhorses.sql (your local working copy).
--   2. Replace each schema/table name with your case_*/corpus_*/legal_* schemas.
--   3. Rewrite each COMMENT ON ... IS '...' string to describe YOUR data.
--   4. Run: psql -d <your_db> -f scripts/04_comment_on_workhorses.sql
--
-- WHAT MAKES A GOOD COMMENT
--   * Schema-level: what corpus is this, what model + dim, what file count / chunk count.
--   * Table-level: row count, key indexes, join keys.
--   * Column-level: index type, units, format, gotchas (timestamp epoch units, array
--     conventions, normalization status, casing).
--
-- Agents read these via pg_description / \d+. See PLAYBOOK Section 7 for the full
-- pattern + a worked retrieval evaluation showing the recall lift.

-- ============================================================================
-- case_26cv11493 (refile-prep evidence)
-- ============================================================================
COMMENT ON SCHEMA case_26cv11493 IS
  'Refile-prep evidence for Bakke v. ODHS (Marion County Circuit Court Case 26CV11493, dismissed without prejudice 2026-05-13). 1,257 source files / 28,463 chunks. Embedding model: sentence-transformers/all-MiniLM-L6-v2 (384 dim, normalized, cosine_ops). Replace text_chunks join key with source_files.sha256.';

COMMENT ON TABLE case_26cv11493.text_chunks IS
  'Chunked content from case_26cv11493 source_files. One row per (file_sha256, chunk_idx). Embedding column is HNSW-indexed vector_cosine_ops 384-dim.';

COMMENT ON COLUMN case_26cv11493.text_chunks.chunk_id IS 'Surrogate PK from sequence.';
COMMENT ON COLUMN case_26cv11493.text_chunks.file_sha256 IS 'FK to source_files.sha256. Use to join back to file metadata.';
COMMENT ON COLUMN case_26cv11493.text_chunks.chunk_idx IS 'Zero-indexed chunk position within the file.';
COMMENT ON COLUMN case_26cv11493.text_chunks.text IS 'The text content of the chunk. Searchable via tsvector GIN index + pg_trgm.';
COMMENT ON COLUMN case_26cv11493.text_chunks.embedding IS 'sentence-transformers/all-MiniLM-L6-v2 embedding (vector(384), normalized, cosine_ops). HNSW indexed.';
COMMENT ON COLUMN case_26cv11493.text_chunks.char_start IS 'Character offset of chunk start within the source file.';
COMMENT ON COLUMN case_26cv11493.text_chunks.char_end IS 'Character offset of chunk end within the source file.';
COMMENT ON COLUMN case_26cv11493.text_chunks.token_count IS 'Token count of the chunk (approximate; uses tiktoken cl100k_base).';

COMMENT ON TABLE case_26cv11493.source_files IS
  'One row per ingested source file in the case_26cv11493 corpus. SHA-256 is the canonical identifier.';

-- ============================================================================
-- case_26cv11493_hearing_prep (current session ingest of hearing-prep folder)
-- ============================================================================
COMMENT ON SCHEMA case_26cv11493_hearing_prep IS
  'Codex-1 ingest 2026-05-19 of /home/levi/Desktop/hearing prep/26CV11493_Case_File/. 1,079 source files / 24,709 chunks. Same embedding model + dim as case_26cv11493. Use this schema for current Bakke v. ODHS refile work; case_26cv11493 has the earlier prep snapshot.';

COMMENT ON TABLE case_26cv11493_hearing_prep.text_chunks IS
  'Chunked content from hearing-prep folder. Identical schema to case_26cv11493.text_chunks. HNSW indexed on embedding.';

COMMENT ON TABLE case_26cv11493_hearing_prep.source_files IS
  'One row per ingested file from /home/levi/Desktop/hearing prep/26CV11493_Case_File/.';

-- ============================================================================
-- case_bingaman_dhs (DHS folder ingest)
-- ============================================================================
COMMENT ON SCHEMA case_bingaman_dhs IS
  'DHS-side evidence for the Bingaman matter. 1,021 source files / 31,175 chunks. Embedding: sentence-transformers/all-MiniLM-L6-v2 (384). Includes APS investigation files, contact logs, and DHS staff communications.';

COMMENT ON TABLE case_bingaman_dhs.text_chunks IS
  'Chunked content from DHS evidence folder. HNSW-indexed on embedding.';

-- ============================================================================
-- corpus_oregon_public_records_filesystem (Oregon Public Records folder)
-- ============================================================================
COMMENT ON SCHEMA corpus_oregon_public_records_filesystem IS
  'Oregon public records filesystem corpus. 2,607 source files / 238,659 chunks (largest workhorse). Contains AG orders, ORS / OAR text, OJCIN opinions, public records training materials. Use for general Oregon-law lookups; for the 1,670-row case-law database see BigQuery oregon_legal_cases.';

COMMENT ON TABLE corpus_oregon_public_records_filesystem.text_chunks IS
  'Chunked content from Oregon public records corpus. 238K chunks total. Largest HNSW index in valor_consolidated.';

COMMENT ON TABLE corpus_oregon_public_records_filesystem.source_files IS
  'One row per Oregon public records file. Includes /corpus/opinions/orctapp/* Oregon Court of Appeals opinions.';

-- ============================================================================
-- ops_gmail (5,690 messages mirrored from Gmail)
-- ============================================================================
COMMENT ON SCHEMA ops_gmail IS
  'Gmail mirror via Gmail API 2026-05-18. 5,690 messages + 1,683 attachments + 65,971 embedded chunks. body_plain has GIN tsvector + pg_trgm indexes. Use to_addrs and cc_addrs (text[] arrays) with unnest() for recipient queries.';

COMMENT ON TABLE ops_gmail.messages IS
  'One row per Gmail message. Body indexed for tsvector FTS. from_addr is btree-indexed; to_addrs and cc_addrs are GIN-indexed text arrays.';

COMMENT ON COLUMN ops_gmail.messages.gmail_id IS 'Gmail-assigned message ID (primary key).';
COMMENT ON COLUMN ops_gmail.messages.thread_id IS 'Gmail thread ID. Use to group conversation history.';
COMMENT ON COLUMN ops_gmail.messages.internal_date_ms IS 'Unix epoch milliseconds. Convert via to_timestamp(internal_date_ms/1000.0).';
COMMENT ON COLUMN ops_gmail.messages.from_addr IS 'Sender email address. Btree-indexed; case-sensitive (use LOWER() or ILIKE for case-insensitive).';
COMMENT ON COLUMN ops_gmail.messages.to_addrs IS 'Recipient email addresses as text[]. GIN-indexed; use unnest() to query individual recipients.';
COMMENT ON COLUMN ops_gmail.messages.cc_addrs IS 'CC email addresses as text[]. GIN-indexed.';
COMMENT ON COLUMN ops_gmail.messages.subject IS 'Email subject. GIN tsvector index for FTS.';
COMMENT ON COLUMN ops_gmail.messages.body_plain IS 'Plain-text body. GIN tsvector index for FTS + pg_trgm for fuzzy search.';
COMMENT ON COLUMN ops_gmail.messages.body_html IS 'HTML body (if present). Generally not indexed; use body_plain for search.';

-- ============================================================================
-- ops_search_agent (the agent observability layer)
-- ============================================================================
COMMENT ON SCHEMA ops_search_agent IS
  'Agent retrieval observability layer. Holds query_log (every agent query), corpus_registry (which schemas are searchable), and v_evidence_search (auto-rebuilt cross-schema UNION ALL view).';

-- ============================================================================
-- VERIFY: count user-written COMMENT ON entries vs system
-- ============================================================================
SELECT
    n.nspname AS schema,
    COUNT(*) FILTER (WHERE d.description IS NOT NULL) AS commented_objects
FROM pg_namespace n
LEFT JOIN pg_class c ON c.relnamespace = n.oid
LEFT JOIN pg_description d ON d.objoid = c.oid
WHERE n.nspname IN ('case_26cv11493', 'case_26cv11493_hearing_prep', 'case_bingaman_dhs',
                    'corpus_oregon_public_records_filesystem', 'ops_gmail', 'ops_search_agent')
GROUP BY n.nspname
ORDER BY n.nspname;
