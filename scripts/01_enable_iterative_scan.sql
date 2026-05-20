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
--
-- USAGE
--   psql -v role=valor_agent -f scripts/01_enable_iterative_scan.sql
--
-- The :"role" psql variable expands to the role name passed via -v role=...
-- If you do not pass -v, the script will error with a clear message.
--
-- RECONNECT REQUIRED
--   ALTER ROLE settings only take effect on NEW sessions. After running this,
--   reconnect (\c <db>) before SHOW hnsw.iterative_scan; will reflect the change.
--   For an immediate same-session effect, use SET LOCAL inside a transaction.

-- Pre-flight: hard-fail if pgvector is missing or below 0.8.0
DO $$
DECLARE
    v_ver text;
BEGIN
    SELECT extversion INTO v_ver
    FROM pg_extension
    WHERE extname = 'vector';

    IF v_ver IS NULL THEN
        RAISE EXCEPTION
          'pgvector extension is not installed. Install with: CREATE EXTENSION vector;';
    END IF;

    IF string_to_array(v_ver, '.')::int[] < ARRAY[0, 8, 0]::int[] THEN
        RAISE EXCEPTION
          'pgvector % is installed; iterative_scan requires >= 0.8.0. Upgrade pgvector.', v_ver;
    END IF;

    RAISE NOTICE 'pgvector % detected; iterative_scan available.', v_ver;
END $$;

-- Verify version is reported for the install log
SELECT extname, extversion
FROM pg_extension
WHERE extname = 'vector';

-- Set at role level (preferred). Pass the role via -v role=<rolename>.
-- Default to 'valor_agent' if no variable was passed (matches PLAYBOOK Section 0).
\if :{?role}
\else
  \set role valor_agent
\endif

-- Bridge the psql :'role' client-side variable into the server-side DO block
-- via a transient custom GUC. Custom GUCs in a namespaced "x.y" form are
-- settable session-locally by any role; they do NOT require superuser.
SET ai_iter.target_role = :'role';

-- ALTER ROLE on a custom GUC (hnsw.*) requires either superuser or ALTER
-- SYSTEM privilege (PG 15+). Non-privileged roles hit "permission denied to
-- set parameter". We wrap the ALTER ROLE in an EXCEPTION handler so the
-- deploy completes with a NOTICE instead of dying -- the operator then uses
-- the per-session SET fallback below.
DO $do$
DECLARE
    target_role text := current_setting('ai_iter.target_role');
BEGIN
    EXECUTE format('ALTER ROLE %I SET hnsw.iterative_scan = %L',
                   target_role, 'relaxed_order');
    RAISE NOTICE
      'hnsw.iterative_scan = relaxed_order applied at role level for "%". Reconnect to pick up.',
      target_role;
EXCEPTION
    WHEN insufficient_privilege THEN
        RAISE NOTICE
          'ALTER ROLE blocked: current user lacks privilege to set hnsw.iterative_scan for "%". '
          'Either rerun this script as a superuser, OR add '
          'SET hnsw.iterative_scan = ''relaxed_order''; '
          'to each agent session (or SET LOCAL inside the agent transaction).',
          target_role;
    WHEN undefined_object THEN
        RAISE EXCEPTION
          'Role "%" does not exist. Pass -v role=<existing-role>.', target_role;
END
$do$;

-- Session-level alternative (run on each connection):
--   SET hnsw.iterative_scan = 'relaxed_order';
-- Transaction-local (no reconnect needed; scoped to current txn):
--   SET LOCAL hnsw.iterative_scan = 'relaxed_order';

-- Optional: tune iterative scan tuples. Defaults are 20000 / 100; for very-large
-- filtered scans you may need to raise. Start at defaults; tune via query_log.
-- ALTER ROLE :"role" SET hnsw.max_scan_tuples = 20000;
-- ALTER ROLE :"role" SET hnsw.scan_mem_multiplier = 1;

-- Verify after RECONNECTING (settings apply to new sessions only):
--   \c <db>
--   SHOW hnsw.iterative_scan;
-- Expected output: relaxed_order
