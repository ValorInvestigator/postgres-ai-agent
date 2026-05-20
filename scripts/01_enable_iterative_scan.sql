-- 01_enable_iterative_scan.sql
-- Per PLAYBOOK Section 0 Move 1 + Section 4
-- Confidence grade: A (pgvector 0.8.0+ documented feature)
--
-- Without this, WHERE-filtered HNSW queries silently lose recall.
-- pgvector 0.8.0 added two iterative-scan modes:
--   * strict_order  -- preserves k-NN ordering at higher cost
--   * relaxed_order -- best recall/perf trade-off for most agent retrieval
-- See https://github.com/pgvector/pgvector#iterative-scans
--
-- Per-role recommended. Session-level fallback if role-level not feasible.

-- Verify pgvector version supports iterative_scan (>= 0.8.0)
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'vector';

-- Set at role level (preferred). Replace `levi` with the agent role if different.
ALTER ROLE levi SET hnsw.iterative_scan = 'relaxed_order';

-- Session-level alternative (run each connection):
-- SET hnsw.iterative_scan = 'relaxed_order';

-- Optional: tune iterative scan tuples. Defaults are 20000 / 100; for very-large
-- filtered scans you may need to raise. Start at defaults; tune via query_log.
-- ALTER ROLE levi SET hnsw.max_scan_tuples = 20000;
-- ALTER ROLE levi SET hnsw.scan_mem_multiplier = 1;

-- Verify (reconnect and run):
-- SHOW hnsw.iterative_scan;
-- Expected output: relaxed_order
