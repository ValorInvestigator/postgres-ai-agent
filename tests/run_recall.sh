#!/usr/bin/env bash
# tests/run_recall.sh
#
# Apply scripts/01..05, seed the synthetic corpus, run the recall benchmark.
# Reports per-query and aggregate recall@10; exits non-zero on any failure.
#
# USAGE
#   bash tests/run_recall.sh                          # uses PG_DSN env var
#   bash tests/run_recall.sh --db postgres://...      # explicit DSN
#   bash tests/run_recall.sh --keep-db                # do not drop test schema
#   bash tests/run_recall.sh --seed-only              # apply + seed, skip recall
#   bash tests/run_recall.sh --no-apply               # skip scripts/, seed + run
#
# ENVIRONMENT
#   PG_DSN           default DSN if --db not given
#   PSQL             override path to psql (default: psql)
#
# PREREQUISITES
#   * pgvector >= 0.8.0
#   * pg_trgm
#   * A throwaway DB the caller has CREATE on. The seed creates schema
#     case_test_seed and writes to ops_search_agent (created by scripts/02-03).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL="${PSQL:-psql}"
DSN="${PG_DSN:-}"
KEEP_DB=0
SEED_ONLY=0
NO_APPLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --db)         DSN="$2"; shift 2 ;;
        --db=*)       DSN="${1#--db=}"; shift ;;
        --keep-db)    KEEP_DB=1; shift ;;
        --seed-only)  SEED_ONLY=1; shift ;;
        --no-apply)   NO_APPLY=1; shift ;;
        -h|--help)
            sed -n '1,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)            echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$DSN" ]; then
    echo "ERROR: no DSN. Pass --db <dsn> or set PG_DSN." >&2
    exit 2
fi

run_sql() {
    local label="$1"; shift
    local file="$1"; shift
    echo "[run_recall] $label -- $file"
    "$PSQL" "$DSN" -v ON_ERROR_STOP=1 -X -f "$file" "$@"
}

echo "[run_recall] target: $DSN"
echo "[run_recall] root:   $ROOT"

# ---- preflight extensions ---------------------------------------------------
"$PSQL" "$DSN" -X -tA -c "SELECT extname || ' ' || extversion FROM pg_extension WHERE extname IN ('vector','pg_trgm')" \
    | tee /tmp/run_recall_exts.txt
if ! grep -q '^vector ' /tmp/run_recall_exts.txt; then
    echo "[run_recall] FAIL: pgvector not installed. Run: CREATE EXTENSION vector;" >&2
    exit 3
fi
if ! grep -q '^pg_trgm ' /tmp/run_recall_exts.txt; then
    echo "[run_recall] FAIL: pg_trgm not installed. Run: CREATE EXTENSION pg_trgm;" >&2
    exit 3
fi

# ---- apply scripts/ ---------------------------------------------------------
if [ "$NO_APPLY" -eq 0 ]; then
    # scripts/01 expects -v role=<name>; pass the connecting role
    SCRIPT_ROLE="$("$PSQL" "$DSN" -X -tA -c 'SELECT current_user')"
    "$PSQL" "$DSN" -v ON_ERROR_STOP=1 -v "role=$SCRIPT_ROLE" -X -f "$ROOT/scripts/01_enable_iterative_scan.sql"
    run_sql "scripts/02"  "$ROOT/scripts/02_create_corpus_registry.sql"
    run_sql "scripts/03"  "$ROOT/scripts/03_create_query_log.sql"
    run_sql "scripts/05"  "$ROOT/scripts/05_hybrid_rrf_search.sql"
    # NOTE: scripts/04 is the example template -- intentionally skipped here.
fi

# ---- seed corpus ------------------------------------------------------------
run_sql "fixtures/seed_corpus.sql" "$ROOT/tests/fixtures/seed_corpus.sql"

if [ "$SEED_ONLY" -eq 1 ]; then
    echo "[run_recall] --seed-only: stopping after seed."
    exit 0
fi

# ---- run benchmark ----------------------------------------------------------
set +e
run_sql "recall_benchmark" "$ROOT/tests/recall_benchmark.sql"
status=$?
set -e

# ---- teardown ---------------------------------------------------------------
if [ "$KEEP_DB" -eq 0 ]; then
    "$PSQL" "$DSN" -X -c 'DROP SCHEMA IF EXISTS case_test_seed CASCADE;'
    "$PSQL" "$DSN" -X -c "DELETE FROM ops_search_agent.corpus_registry WHERE schema_name = 'case_test_seed';" || true
fi

if [ "$status" -ne 0 ]; then
    echo "[run_recall] FAIL"
    exit "$status"
fi
echo "[run_recall] PASS"
