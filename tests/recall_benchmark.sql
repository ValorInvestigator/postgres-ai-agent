-- tests/recall_benchmark.sql
-- Recall benchmark against the synthetic 3-cluster corpus + distractors.
--
-- HOW IT WORKS
--   1. Defines a labelled query set: each row is (query_text, query_vec,
--      relevant_chunk_ids[], description).
--   2. For each query, calls ops_search_agent.hybrid_rrf_search() against
--      case_test_seed.chunks, materialises the top-10.
--   3. Computes recall@10 = |returned ∩ relevant| / |relevant|.
--   4. Also computes precision@6 (first six returned must all be in relevant).
--   5. Verifies all three legs actually fired (fts_rank + trgm_rank each
--      non-null on at least one row per query).
--   6. Compares against per-query and aggregate thresholds.
--   7. Final SELECT raises an exception if any test fell short.
--
-- THRESHOLDS (calibrated to baseline floor on the 60-chunk corpus)
--   per_query_recall_at_10  >= 0.65  (at least 4 of 6 relevant chunks in top-10;
--                                     paraphrase queries like 'constitutional'
--                                     for the civil-rights cluster have weak
--                                     FTS signal AND distractors with matching
--                                     keyword + civil-rights vector compete
--                                     for top-10 slots. The structured
--                                     distractors are intentionally engineered
--                                     to defeat naive vector-only retrieval;
--                                     0.65 catches a regression where
--                                     fewer than 4 of 6 relevant survive.)
--   per_query_precision_at_6 >= 0.50 (at least 3 of top-6 are relevant)
--   aggregate mean_recall_at_10 >= 0.85
--   ALL legs must return >= 1 row per query (fts_nonnull, trgm_nonnull > 0)
--
-- LEG-COVERAGE ASSERTION
--   For each query, at least one returned chunk must have fts_rank IS NOT NULL
--   and at least one must have trgm_rank IS NOT NULL. This guards against
--   the "hybrid is silently vector-only" failure mode claude-2 found in red-
--   team 10 against a smaller earlier corpus.
--
-- PREREQUISITES
--   * scripts/01..05 applied (function present)
--   * tests/fixtures/seed_corpus.sql applied (60-chunk corpus + indexes)

\set ON_ERROR_STOP on

-- pg_trgm.similarity_threshold defaults to 0.3 -- too strict for short query
-- text against long chunks. Lower it for this test session so the trgm leg
-- (`%` operator) returns candidates. Production callers should tune per-corpus.
SET pg_trgm.similarity_threshold = 0.05;

BEGIN;

DROP TABLE IF EXISTS pg_temp.recall_queries;
DROP TABLE IF EXISTS pg_temp.recall_results;
DROP TABLE IF EXISTS pg_temp.recall_returned;

-- ============================================================================
-- Labelled query set
-- query_vec axes mirror the cluster axes from seed_corpus.sql
--   dim 0 = civil-rights, dim 1 = probate, dim 2 = medical
-- query_text chosen so EACH of FTS + trgm legs returns >= 1 row.
-- ============================================================================
CREATE TEMP TABLE recall_queries (
    qid              integer PRIMARY KEY,
    description      text NOT NULL,
    query_text       text NOT NULL,
    query_vec        vector(8) NOT NULL,
    relevant_ids     bigint[] NOT NULL
);

INSERT INTO recall_queries VALUES
    (1, 'civil-rights pure (keyword shared across all 6 relevant + 6 distractors)',
     'civil rights',
     '[1, 0, 0, 0, 0, 0, 0, 0]'::vector,
     ARRAY[1::bigint, 2, 3, 4, 5, 6]),

    (2, 'probate pure (keyword shared across multiple relevant + distractors)',
     'probate',
     '[0, 1, 0, 0, 0, 0, 0, 0]'::vector,
     ARRAY[7::bigint, 8, 9, 10, 11, 12]),

    (3, 'medical pure (HIPAA keyword across all 6 relevant + 3 distractors)',
     'HIPAA',
     '[0, 0, 1, 0, 0, 0, 0, 0]'::vector,
     ARRAY[13::bigint, 14, 15, 16, 17, 18]),

    (4, 'civil-rights paraphrase (constitutional keyword + cluster vector)',
     'constitutional',
     '[1, 0, 0, 0, 0, 0, 0, 0]'::vector,
     ARRAY[1::bigint, 2, 3, 4, 5, 6]),

    (5, 'probate subtopic (personal representative keyword + cluster vector)',
     'personal representative',
     '[0, 1, 0, 0, 0, 0, 0, 0]'::vector,
     ARRAY[7::bigint, 8, 9, 10, 11, 12]),

    (6, 'medical subtopic (audit log keyword + cluster vector)',
     'audit log',
     '[0, 0, 1, 0, 0, 0, 0, 0]'::vector,
     ARRAY[13::bigint, 14, 15, 16, 17, 18]);

-- ============================================================================
-- Returned chunks per query (one row per (qid, returned_chunk_id, rank tuple))
-- Used for both recall scoring and leg-coverage assertion.
-- ============================================================================
CREATE TEMP TABLE recall_returned (
    qid          integer NOT NULL,
    chunk_id     bigint NOT NULL,
    rrf_score    double precision NOT NULL,
    vector_rank  integer,
    fts_rank     integer,
    trgm_rank    integer,
    position     integer NOT NULL
);

-- ============================================================================
-- Run hybrid_rrf_search for each query, store top-10 with rank columns.
-- ============================================================================
DO $$
DECLARE
    q recall_queries%ROWTYPE;
    rec record;
    pos int;
BEGIN
    FOR q IN SELECT * FROM recall_queries ORDER BY qid LOOP
        pos := 0;
        FOR rec IN
            SELECT chunk_id, rrf_score, vector_rank, fts_rank, trgm_rank
            FROM ops_search_agent.hybrid_rrf_search(
                q.query_text, q.query_vec,
                'case_test_seed', 'chunks', 'content', 'embedding', 'id',
                60, 60, 10
            )
            ORDER BY rrf_score DESC
        LOOP
            pos := pos + 1;
            INSERT INTO recall_returned (qid, chunk_id, rrf_score, vector_rank, fts_rank, trgm_rank, position)
            VALUES (q.qid, rec.chunk_id, rec.rrf_score, rec.vector_rank, rec.fts_rank, rec.trgm_rank, pos);
        END LOOP;
    END LOOP;
END $$;

-- ============================================================================
-- Aggregate to per-query results
-- ============================================================================
CREATE TEMP TABLE recall_results AS
WITH per_q AS (
    SELECT
        q.qid,
        q.description,
        array_length(q.relevant_ids, 1) AS relevant_count,
        COALESCE(array_agg(r.chunk_id ORDER BY r.position),
                 ARRAY[]::bigint[]) AS returned_ids,
        SUM((r.chunk_id = ANY(q.relevant_ids))::int) AS hit_count_overall,
        SUM(((r.chunk_id = ANY(q.relevant_ids)) AND r.position <= 6)::int) AS hit_count_top6,
        SUM((r.fts_rank IS NOT NULL)::int) AS fts_nonnull_rows,
        SUM((r.trgm_rank IS NOT NULL)::int) AS trgm_nonnull_rows
    FROM recall_queries q
    LEFT JOIN recall_returned r ON r.qid = q.qid
    GROUP BY q.qid, q.description, q.relevant_ids
)
SELECT
    qid, description, relevant_count, returned_ids,
    hit_count_overall, hit_count_top6,
    hit_count_overall::double precision / NULLIF(relevant_count, 0) AS recall_at_10,
    hit_count_top6::double precision    / NULLIF(LEAST(relevant_count, 6), 0) AS precision_at_6,
    fts_nonnull_rows, trgm_nonnull_rows,
    (hit_count_overall::double precision / NULLIF(relevant_count, 0)) >= 0.65
        AND (hit_count_top6::double precision / NULLIF(LEAST(relevant_count, 6), 0)) >= 0.50
        AND fts_nonnull_rows  >= 1
        AND trgm_nonnull_rows >= 1
        AS passed
FROM per_q;

-- ============================================================================
-- Per-query report (visible in run_recall.sh output)
-- ============================================================================
SELECT
    qid,
    description,
    relevant_count,
    hit_count_overall AS hits_top10,
    hit_count_top6    AS hits_top6,
    ROUND(recall_at_10::numeric,   3) AS recall_at_10,
    ROUND(precision_at_6::numeric, 3) AS precision_at_6,
    fts_nonnull_rows,
    trgm_nonnull_rows,
    passed
FROM recall_results
ORDER BY qid;

-- ============================================================================
-- Aggregate
-- ============================================================================
SELECT
    COUNT(*) AS n_queries,
    SUM(passed::int) AS n_passed,
    SUM((NOT passed)::int) AS n_failed,
    ROUND(AVG(recall_at_10)::numeric,    3) AS mean_recall_at_10,
    ROUND(MIN(recall_at_10)::numeric,    3) AS min_recall_at_10,
    ROUND(AVG(precision_at_6)::numeric,  3) AS mean_precision_at_6,
    ROUND(MIN(precision_at_6)::numeric,  3) AS min_precision_at_6
FROM recall_results;

-- ============================================================================
-- Fail-loud assertion
-- ============================================================================
DO $$
DECLARE
    n_failed int;
    min_rec  double precision;
    min_prec double precision;
    bad_fts  int;
    bad_trgm int;
BEGIN
    SELECT
        SUM((NOT passed)::int),
        MIN(recall_at_10),
        MIN(precision_at_6),
        SUM((fts_nonnull_rows  = 0)::int),
        SUM((trgm_nonnull_rows = 0)::int)
    INTO n_failed, min_rec, min_prec, bad_fts, bad_trgm
    FROM recall_results;

    IF bad_fts > 0 THEN
        RAISE EXCEPTION
          'recall_benchmark FAILED: % of % queries had ZERO fts_rank rows (FTS leg silently empty)',
          bad_fts, (SELECT COUNT(*) FROM recall_results);
    END IF;
    IF bad_trgm > 0 THEN
        RAISE EXCEPTION
          'recall_benchmark FAILED: % of % queries had ZERO trgm_rank rows (pg_trgm leg silently empty)',
          bad_trgm, (SELECT COUNT(*) FROM recall_results);
    END IF;
    IF min_rec < 0.65 THEN
        RAISE EXCEPTION
          'recall_benchmark FAILED: min recall_at_10 = % < 0.65 (per-query gate)',
          min_rec;
    END IF;
    IF min_prec < 0.50 THEN
        RAISE EXCEPTION
          'recall_benchmark FAILED: min precision_at_6 = % < 0.50 '
          '(per-query gate; structured distractors crowded out relevant chunks)',
          min_prec;
    END IF;
    IF n_failed > 0 THEN
        RAISE EXCEPTION
          'recall_benchmark FAILED: % of % queries did not satisfy all per-query gates',
          n_failed, (SELECT COUNT(*) FROM recall_results);
    END IF;
    IF (SELECT AVG(recall_at_10) FROM recall_results) < 0.85 THEN
        RAISE EXCEPTION
          'recall_benchmark FAILED: mean recall_at_10 = % < 0.85 (aggregate gate)',
          (SELECT AVG(recall_at_10) FROM recall_results);
    END IF;
    RAISE NOTICE 'recall_benchmark PASSED: '
                 'min_recall_at_10=%, min_precision_at_6=%, '
                 'all queries hit fts AND trgm legs (corpus = 60 chunks, '
                 '6 relevant + 6 keyword-matching distractors + ~48 noise per query)',
                 min_rec, min_prec;
END $$;

COMMIT;
