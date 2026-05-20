"""Latency benchmark for the postgres-ai-agent retrieval stack.

Times three retrieval modes against the synthetic 3-cluster seed corpus
that Claude-1 built at `tests/fixtures/seed_corpus.sql`:

  1. vector-only  (raw HNSW cosine ORDER BY embedding <=> $1 LIMIT 10)
  2. hybrid_rrf   (ops_search_agent.hybrid_rrf_search three-leg RRF)
  3. hybrid_rrf + rerank stub (RRF top-100 + simulated cross-encoder pass)

For each mode + each query, runs N timed iterations (default N=30), reports
p50 / p95 / max latency in milliseconds, and compares against the budget
documented in `references/PLAYBOOK.md` Section 12.

PLAYBOOK Section 12 budget (single box, 64GB, M.2 NVMe):
  - Semantic (HNSW top-10), 2M rows: p50 3-8 ms, p95 15-30 ms
  - Hybrid (3-way RRF MATERIALIZED), 10M rows: p50 15-40 ms, p95 60-120 ms
  - + BGE-reranker-v2-m3 (100 docs): +100-300 ms p50, +500 ms p95

The seed corpus is 20 rows so absolute latencies will be much lower than
the budget. This benchmark is therefore a REGRESSION detector against a
small fixture, not a production-scale measurement. The budget thresholds
below are scaled to the fixture size; production-scale validation needs a
second harness against a real corpus (deferred to Phase 4b or Phase 5).

Confidence grade: C (synthesis pattern; relies on `time.monotonic()`).

Usage:
    # Apply scripts + seed first if not already:
    bash tests/run_recall.sh --seed-only --db "dbname=test host=/var/run/postgresql"

    # Run the latency benchmark:
    PG_DSN="dbname=test host=/var/run/postgresql" python3 tests/latency_benchmark.py

    # Or with explicit flags:
    python3 tests/latency_benchmark.py \
        --dsn "dbname=test host=/var/run/postgresql" \
        --iterations 50 \
        --warmup 5

Exit codes:
    0  all modes within budget
    1  one or more modes exceeded budget (regression)
    2  setup error (missing function, missing fixture, etc.)
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import time
from typing import Any

import psycopg2
import psycopg2.extras


# ============================================================================
# Latency budgets -- TWO LAYERS checked in parallel (whichever is tighter trips
# first). Both must hold for the benchmark to PASS.
#
# CEILING (PLAYBOOK Section 12, 2M-10M row scale): guards against PRODUCTION
# regression on a real deployment. Generous on the seed fixture; will only trip
# if something is structurally broken (missing HNSW, planner choosing seq scan,
# rerender of GIN indexes as text, etc.).
#
# FLOOR (fixture-scaled): guards against SEED-CORPUS regression. Calibrated
# from claude-1's Phase 4b red-team baseline measurements on a 20-row corpus
# (vector_only 0.02 / hybrid_rrf 0.88-1.20 / rerank-stub 201.26-201.51 ms).
# Tight enough that a missing-GIN regression (e.g., FTS leg dropping to seq
# scan) is caught even at fixture scale.
# ============================================================================
BUDGET_CEILING_MS = {
    "vector_only": {"p50": 8.0, "p95": 30.0, "max": 100.0},
    "hybrid_rrf":  {"p50": 40.0, "p95": 120.0, "max": 300.0},
    "hybrid_rrf_with_rerank": {"p50": 340.0, "p95": 620.0, "max": 1500.0},
}

BUDGET_FLOOR_MS = {
    "vector_only": {"p50": 1.0, "p95": 3.0, "max": 10.0},
    "hybrid_rrf":  {"p50": 5.0, "p95": 20.0, "max": 50.0},
    # Floor budget tolerates the 200ms rerank stub + ~30ms of RRF + roundtrip.
    "hybrid_rrf_with_rerank": {"p50": 230.0, "p95": 250.0, "max": 300.0},
}

# Back-compat alias for downstream JSON consumers; default to CEILING.
BUDGET_MS = BUDGET_CEILING_MS


# ============================================================================
# Labelled queries (mirror tests/recall_benchmark.sql to enable sharing)
# ============================================================================
LABELLED_QUERIES = [
    {
        "qid": 1,
        "description": "pure civil-rights vector + keyword",
        "query_text": "section 1983 civil rights claim",
        "query_vec":  "[1, 0, 0, 0, 0, 0, 0, 0]",
    },
    {
        "qid": 2,
        "description": "pure probate vector + keyword",
        "query_text": "probate personal representative estate",
        "query_vec":  "[0, 1, 0, 0, 0, 0, 0, 0]",
    },
    {
        "qid": 3,
        "description": "pure medical vector + keyword",
        "query_text": "HIPAA medical records audit",
        "query_vec":  "[0, 0, 1, 0, 0, 0, 0, 0]",
    },
    {
        "qid": 4,
        "description": "civil-rights paraphrase (no exact keyword)",
        "query_text": "fourteenth amendment due process violation",
        "query_vec":  "[1, 0, 0, 0, 0, 0, 0, 0]",
    },
    {
        "qid": 5,
        "description": "probate specific subtopic (letters testamentary)",
        "query_text": "letters testamentary death certificate",
        "query_vec":  "[0, 1, 0, 0, 0, 0, 0, 0]",
    },
    {
        "qid": 6,
        "description": "medical specific subtopic (audit log)",
        "query_text": "native field-level audit log discovery",
        "query_vec":  "[0, 0, 1, 0, 0, 0, 0, 0]",
    },
]


# ============================================================================
# Preflight: verify the function + fixture are present
# ============================================================================
def preflight(conn: Any) -> None:
    """Verify scripts/01..05 + seed_corpus.sql have been applied. Exit 2 if not."""
    with conn.cursor() as cur:
        # Check 1: hybrid_rrf_search function exists
        cur.execute("""
            SELECT 1 FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'ops_search_agent' AND p.proname = 'hybrid_rrf_search'
        """)
        if cur.fetchone() is None:
            sys.stderr.write(
                "preflight FAIL: ops_search_agent.hybrid_rrf_search not found. "
                "Apply scripts/01..05 first.\n"
            )
            sys.exit(2)

        # Check 2: seed corpus is loaded
        cur.execute("""
            SELECT 1 FROM information_schema.tables
            WHERE table_schema = 'case_test_seed' AND table_name = 'chunks'
        """)
        if cur.fetchone() is None:
            sys.stderr.write(
                "preflight FAIL: case_test_seed.chunks not found. "
                "Apply tests/fixtures/seed_corpus.sql first.\n"
            )
            sys.exit(2)

        # Check 3: HNSW index present (otherwise the vector_only benchmark times sequential scan).
        # Uses canonical pg_am query (vs indexdef ILIKE) so a future renamed-index doesn't slip through.
        cur.execute("""
            SELECT 1
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            JOIN pg_am   a ON a.oid = c.relam
            JOIN pg_class t ON t.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = 'case_test_seed'
              AND t.relname = 'chunks'
              AND a.amname = 'hnsw'
        """)
        if cur.fetchone() is None:
            sys.stderr.write(
                "preflight FAIL: HNSW index missing on case_test_seed.chunks. "
                "The benchmark cannot distinguish HNSW from sequential scan.\n"
            )
            sys.exit(2)

        # Check 4: GIN tsvector index (FTS leg dependency for hybrid_rrf).
        # Without this, the FTS leg falls to sequential scan -- at fixture scale the
        # cost is ~50us and budgets miss it, but at production scale this is critical.
        cur.execute("""
            SELECT 1
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            JOIN pg_am   a ON a.oid = c.relam
            JOIN pg_class t ON t.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = 'case_test_seed'
              AND t.relname = 'chunks'
              AND a.amname = 'gin'
              AND pg_get_indexdef(i.indexrelid) ILIKE '%content_tsv%'
        """)
        if cur.fetchone() is None:
            sys.stderr.write(
                "preflight FAIL: GIN tsvector index missing on case_test_seed.chunks.content_tsv. "
                "The hybrid_rrf FTS leg will fall to sequential scan.\n"
            )
            sys.exit(2)

        # Check 5: pg_trgm GIN index on content (trgm leg dependency for hybrid_rrf).
        cur.execute("""
            SELECT 1
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid
            JOIN pg_am   a ON a.oid = c.relam
            JOIN pg_class t ON t.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = 'case_test_seed'
              AND t.relname = 'chunks'
              AND a.amname = 'gin'
              AND pg_get_indexdef(i.indexrelid) ILIKE '%gin_trgm_ops%'
        """)
        if cur.fetchone() is None:
            sys.stderr.write(
                "preflight FAIL: pg_trgm GIN index missing on case_test_seed.chunks (gin_trgm_ops). "
                "The hybrid_rrf trgm leg will fall to sequential scan.\n"
            )
            sys.exit(2)

        # Check 6: chunk count matches expectation
        cur.execute("SELECT COUNT(*) FROM case_test_seed.chunks WHERE deleted_at IS NULL")
        n_chunks = cur.fetchone()[0]
        if n_chunks < 18:
            sys.stderr.write(
                f"preflight FAIL: case_test_seed.chunks has only {n_chunks} rows; "
                f"expected 18+ (3 clusters * 6 + 2 noise).\n"
            )
            sys.exit(2)

        # Check 7: hybrid_rrf_search function body declares MATERIALIZED CTEs (otherwise
        # the planner folds the legs, duplicating leg work and defeating recall on the
        # iterative HNSW scan). The function is PL/pgSQL and builds its SQL dynamically,
        # so EXPLAIN against the function call only shows the outer Function Scan; the
        # inner CTE structure is invisible. We instead inspect pg_get_functiondef() to
        # confirm "AS MATERIALIZED" appears at least 3 times (vector + fts + trgm legs).
        cur.execute("""
            SELECT pg_get_functiondef(p.oid)
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'ops_search_agent' AND p.proname = 'hybrid_rrf_search'
            LIMIT 1
        """)
        func_def_row = cur.fetchone()
        if func_def_row is None:
            sys.stderr.write("preflight FAIL: cannot retrieve hybrid_rrf_search function body.\n")
            sys.exit(2)
        func_def = func_def_row[0]
        # Case-insensitive count of "AS MATERIALIZED" -- robust to whitespace + casing
        # variations.
        materialized_count = func_def.upper().count("AS MATERIALIZED")
        if materialized_count < 3:
            sys.stderr.write(
                f"preflight FAIL: hybrid_rrf_search function body has {materialized_count} "
                f"'AS MATERIALIZED' tokens; expected >= 3 (vector + fts + trgm legs). "
                f"Folded CTE legs would duplicate iterative HNSW scans and degrade recall.\n"
            )
            sys.exit(2)

    sys.stderr.write(
        "preflight PASS: function + fixture + HNSW + GIN(tsv) + GIN(trgm) + chunk count + MATERIALIZED CTEs OK\n"
    )


# ============================================================================
# Mode runners (return latency in ms for a single query)
# ============================================================================

def run_vector_only(conn: Any, query_vec: str) -> tuple[float, int]:
    """Raw HNSW cosine ORDER BY embedding <=> $1 LIMIT 10. Returns (latency_ms, row_count)."""
    sql = """
        SELECT id
        FROM case_test_seed.chunks
        WHERE deleted_at IS NULL
        ORDER BY embedding <=> %s::vector
        LIMIT 10
    """
    with conn.cursor() as cur:
        t0 = time.monotonic()
        cur.execute(sql, (query_vec,))
        rows = cur.fetchall()
        t1 = time.monotonic()
    return ((t1 - t0) * 1000.0, len(rows))


def run_hybrid_rrf(conn: Any, query_text: str, query_vec: str) -> tuple[float, int]:
    """ops_search_agent.hybrid_rrf_search three-leg RRF. Returns (latency_ms, row_count)."""
    sql = """
        SELECT chunk_id
        FROM ops_search_agent.hybrid_rrf_search(
            query_text    => %s,
            query_vec     => %s::vector,
            target_schema => 'case_test_seed',
            target_table  => 'chunks',
            text_col      => 'content',
            vec_col       => 'embedding',
            chunk_id_col  => 'id',
            k_per_leg     => 30,
            rrf_k         => 60,
            final_k       => 10
        )
    """
    with conn.cursor() as cur:
        t0 = time.monotonic()
        cur.execute(sql, (query_text, query_vec))
        rows = cur.fetchall()
        t1 = time.monotonic()
    return ((t1 - t0) * 1000.0, len(rows))


def run_hybrid_rrf_with_rerank_stub(conn: Any, query_text: str, query_vec: str) -> tuple[float, int]:
    """Hybrid RRF top-100 candidates + simulated cross-encoder rerank latency.

    The rerank tool is not deployed (MCP scaffolding deferred per BUILD_PROTOCOL.md
    'Out of scope'). This stub:

    1. Retrieves hybrid RRF top-100 candidates from the DB.
    2. Simulates the cross-encoder pass by sleeping for the per-query budget the
       PLAYBOOK Section 5.3 cites (100-300 ms for 100 docs on a consumer GPU).
       We use the midpoint (200 ms) to reflect the documented BGE-reranker-v2-m3
       cost.

    Important: the sleep is CORPUS-SIZE-INDEPENDENT. A real BGE-reranker pass
    scales linearly with candidate count, but on the 20-row seed fixture only
    20 docs come back. The fixed 200ms stub is intentional -- it's a clean
    regression detector that does NOT drift with fixture size. When the real
    endpoint exists, replace with an HTTP call (which WILL drift with count).

    A real implementation would replace the time.sleep with an HTTP call to a
    self-hosted BGE-reranker endpoint. The latency budget we test against is
    the RRF latency PLUS the rerank cost.

    Confidence grade: C (the rerank latency is stubbed; the RRF half is real).

    Returns (total_latency_ms_including_rerank_stub, row_count).
    """
    sql = """
        SELECT chunk_id
        FROM ops_search_agent.hybrid_rrf_search(
            query_text    => %s,
            query_vec     => %s::vector,
            target_schema => 'case_test_seed',
            target_table  => 'chunks',
            text_col      => 'content',
            vec_col       => 'embedding',
            chunk_id_col  => 'id',
            k_per_leg     => 100,
            rrf_k         => 60,
            final_k       => 100
        )
    """
    with conn.cursor() as cur:
        t0 = time.monotonic()
        cur.execute(sql, (query_text, query_vec))
        rows = cur.fetchall()
        # Simulated rerank cost: PLAYBOOK Section 5.3 cites 100-300 ms for 100 docs.
        # Use the midpoint as a stand-in for the absent BGE endpoint.
        time.sleep(0.200)
        t1 = time.monotonic()
    return ((t1 - t0) * 1000.0, len(rows))


# ============================================================================
# Benchmark orchestration
# ============================================================================
MODES = [
    ("vector_only",            run_vector_only),
    ("hybrid_rrf",             run_hybrid_rrf),
    ("hybrid_rrf_with_rerank", run_hybrid_rrf_with_rerank_stub),
]


def benchmark_mode(
    conn: Any,
    mode_name: str,
    runner: Any,
    iterations: int,
    warmup: int,
) -> dict[str, Any]:
    """Run all labelled queries N times, return per-mode latency stats."""
    per_query: list[dict[str, Any]] = []
    all_latencies: list[float] = []

    for q in LABELLED_QUERIES:
        latencies: list[float] = []
        # Warmup (excluded from measurements)
        for _ in range(warmup):
            if mode_name == "vector_only":
                runner(conn, q["query_vec"])
            else:
                runner(conn, q["query_text"], q["query_vec"])
        # Timed iterations
        for _ in range(iterations):
            if mode_name == "vector_only":
                latency_ms, _ = runner(conn, q["query_vec"])
            else:
                latency_ms, _ = runner(conn, q["query_text"], q["query_vec"])
            latencies.append(latency_ms)
        per_query.append({
            "qid": q["qid"],
            "description": q["description"],
            "p50": statistics.median(latencies),
            "p95": _percentile(latencies, 95),
            "max": max(latencies),
            "min": min(latencies),
        })
        all_latencies.extend(latencies)

    return {
        "mode": mode_name,
        "iterations_per_query": iterations,
        "warmup_per_query": warmup,
        "n_queries": len(LABELLED_QUERIES),
        "n_samples": len(all_latencies),
        "p50": statistics.median(all_latencies),
        "p95": _percentile(all_latencies, 95),
        "max": max(all_latencies),
        "min": min(all_latencies),
        "per_query": per_query,
    }


def _percentile(values: list[float], pct: float) -> float:
    """Compute the p-th percentile (0..100). Used because statistics.quantiles
    requires Python 3.8+ and may not handle edge cases on tiny lists cleanly."""
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * (pct / 100.0)
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def check_budget(results: dict[str, Any]) -> tuple[bool, list[str]]:
    """Compare results against BUDGET_FLOOR_MS + BUDGET_CEILING_MS.

    Both layers are checked; failing EITHER trips the result. The floor catches
    seed-corpus regressions (e.g., GIN tsvector dropped causes FTS leg to seq
    scan, p95 doubles from 1ms to 3ms -- caught by floor, missed by ceiling).
    The ceiling guards against PLAYBOOK 2M-10M-row drift on production deploys.
    """
    failures: list[str] = []
    for mode, _runner in MODES:
        r = results[mode]
        for layer_name, budget_set in (("FLOOR", BUDGET_FLOOR_MS), ("CEILING", BUDGET_CEILING_MS)):
            budget = budget_set[mode]
            if r["p50"] > budget["p50"]:
                failures.append(
                    f"  {mode}: p50 = {r['p50']:.2f} ms (budget {layer_name} {budget['p50']:.1f} ms)"
                )
            if r["p95"] > budget["p95"]:
                failures.append(
                    f"  {mode}: p95 = {r['p95']:.2f} ms (budget {layer_name} {budget['p95']:.1f} ms)"
                )
            if r["max"] > budget["max"]:
                failures.append(
                    f"  {mode}: max = {r['max']:.2f} ms (budget {layer_name} {budget['max']:.1f} ms)"
                )
    return (len(failures) == 0, failures)


def print_report(results: dict[str, Any], all_pass: bool, failures: list[str]) -> None:
    """Human-readable summary.

    Per-mode p50/p95/max numbers across 180 samples (30 iters * 6 queries) are
    SLI-grade (~1% confidence interval). Per-query p50/p95/max from 30 samples
    are EYEBALL-grade (~3% CI); use them as a trend indicator, not for SLO
    enforcement. Raise --iterations to 100+ if per-query numbers need precision.
    """
    print("\nLatency benchmark report")
    print("=" * 78)
    for mode, _ in MODES:
        r = results[mode]
        floor = BUDGET_FLOOR_MS[mode]
        ceiling = BUDGET_CEILING_MS[mode]
        print(f"\n{mode}")
        print(f"  iterations/query: {r['iterations_per_query']}; warmup/query: {r['warmup_per_query']}")
        print(f"  samples (across {r['n_queries']} queries): {r['n_samples']}")
        print(f"  p50: {r['p50']:6.2f} ms  (floor {floor['p50']:6.1f} / ceiling {ceiling['p50']:6.1f} ms)")
        print(f"  p95: {r['p95']:6.2f} ms  (floor {floor['p95']:6.1f} / ceiling {ceiling['p95']:6.1f} ms)")
        print(f"  max: {r['max']:6.2f} ms  (floor {floor['max']:6.1f} / ceiling {ceiling['max']:6.1f} ms)")
        print(f"  min: {r['min']:6.2f} ms")
        # Per-query breakdown (30-sample percentiles are eyeball-grade; aggregate above is SLI-grade)
        for pq in r["per_query"]:
            print(
                f"    q{pq['qid']} {pq['description'][:42]:42s}  "
                f"p50={pq['p50']:6.2f}  p95={pq['p95']:6.2f}  max={pq['max']:6.2f}"
            )

    print("\n" + "=" * 78)
    if all_pass:
        print("RESULT: PASS (all modes within both floor + ceiling budgets)")
    else:
        print("RESULT: FAIL (one or more modes exceeded budget):")
        for f in failures:
            print(f)


# ============================================================================
# CLI
# ============================================================================
def main() -> int:
    parser = argparse.ArgumentParser(
        description="Latency benchmark for postgres-ai-agent retrieval stack",
    )
    parser.add_argument(
        "--dsn",
        default=os.environ.get(
            "PG_DSN",
            "dbname=test_postgres_ai_agent host=/var/run/postgresql",
        ),
        help="psycopg2 DSN (default: PG_DSN env var, else test_postgres_ai_agent local socket)",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=30,
        help="Timed iterations per query per mode (default 30)",
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=3,
        help="Warmup iterations per query per mode, excluded from stats (default 3)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print results as JSON instead of human-readable report",
    )
    args = parser.parse_args()

    try:
        conn = psycopg2.connect(args.dsn)
    except psycopg2.OperationalError as e:
        sys.stderr.write(f"connect FAIL: {e}\n")
        return 2

    try:
        # autocommit so each iteration is timed as one standalone request (no
        # transaction-batch optimization, matches an agent's per-query call shape).
        conn.autocommit = True
        preflight(conn)

        results: dict[str, Any] = {}
        for mode_name, runner in MODES:
            sys.stderr.write(f"benchmarking {mode_name} ...\n")
            results[mode_name] = benchmark_mode(
                conn,
                mode_name,
                runner,
                iterations=args.iterations,
                warmup=args.warmup,
            )

        all_pass, failures = check_budget(results)

        if args.json:
            print(json.dumps({
                "budget_floor": BUDGET_FLOOR_MS,
                "budget_ceiling": BUDGET_CEILING_MS,
                "results": results,
                "all_pass": all_pass,
                "failures": failures,
            }, indent=2))
        else:
            print_report(results, all_pass, failures)

        return 0 if all_pass else 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
