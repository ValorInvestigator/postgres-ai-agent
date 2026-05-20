-- tests/recall_benchmark.sql
-- Recall benchmark against the synthetic 3-cluster corpus.
--
-- HOW IT WORKS
--   1. Defines a labeled query set: each row is (query_text, query_vec,
--      relevant_chunk_ids[], description).
--   2. For each query, calls ops_search_agent.hybrid_rrf_search() against
--      case_test_seed.chunks, materialises the top-10.
--   3. Computes recall@10 = |returned ∩ relevant| / |relevant|.
--   4. Compares against per-query and aggregate thresholds.
--   5. Final SELECT raises an exception if any test fell short.
--
-- THRESHOLDS
--   per_query_min_recall = 0.80   (each labeled query must hit ≥80% of relevant)
--   aggregate_min_recall = 0.90   (mean recall@10 across all queries)
--
-- PREREQUISITES
--   * scripts/01..05 applied (function present)
--   * tests/fixtures/seed_corpus.sql applied (corpus + indexes present)

\set ON_ERROR_STOP on

BEGIN;

DROP TABLE IF EXISTS pg_temp.recall_queries;
DROP TABLE IF EXISTS pg_temp.recall_results;

-- ============================================================================
-- Labeled query set
-- query_vec axes mirror the cluster axes from seed_corpus.sql
--   dim 0 = civil-rights, dim 1 = probate, dim 2 = medical
-- ============================================================================
CREATE TEMP TABLE recall_queries (
    qid              integer PRIMARY KEY,
    description      text NOT NULL,
    query_text       text NOT NULL,
    query_vec        vector(8) NOT NULL,
    relevant_ids     bigint[] NOT NULL
);

INSERT INTO recall_queries VALUES
    (1, 'pure civil-rights vector + keyword',
     'section 1983 civil rights claim',
     '[1, 0, 0, 0, 0, 0, 0, 0]'::vector,
     ARRAY[1::bigint, 2, 3, 4, 5, 6]),

    (2, 'pure probate vector + keyword',
     'probate personal representative estate',
     '[0, 1, 0, 0, 0, 0, 0, 0]'::vector,
     ARRAY[7::bigint, 8, 9, 10, 11, 12]),

    (3, 'pure medical vector + keyword',
     'HIPAA medical records audit',
     '[0, 0, 1, 0, 0, 0, 0, 0]'::vector,
     ARRAY[13::bigint, 14, 15, 16, 17, 18]),

    (4, 'civil-rights paraphrase (no exact keyword)',
     'fourteenth amendment due process violation',
     '[1, 0, 0, 0, 0, 0, 0, 0]'::vector,
     ARRAY[1::bigint, 2, 3, 4, 5, 6]),

    (5, 'probate specific subtopic (letters testamentary)',
     'letters testamentary death certificate',
     '[0, 1, 0, 0, 0, 0, 0, 0]'::vector,
     ARRAY[7::bigint, 8, 9, 10, 11, 12]),

    (6, 'medical specific subtopic (audit log)',
     'native field-level audit log discovery',
     '[0, 0, 1, 0, 0, 0, 0, 0]'::vector,
     ARRAY[13::bigint, 14, 15, 16, 17, 18]);

-- ============================================================================
-- Run hybrid_rrf_search for each query, collect top-10 chunk IDs.
-- ============================================================================
CREATE TEMP TABLE recall_results (
    qid              integer NOT NULL,
    description      text NOT NULL,
    relevant_count   integer NOT NULL,
    returned_ids     bigint[] NOT NULL,
    hit_count        integer NOT NULL,
    recall_at_10     double precision NOT NULL,
    passed           boolean NOT NULL
);

DO $$
DECLARE
    q recall_queries%ROWTYPE;
    returned bigint[];
    hits     int;
    rec_at_k double precision;
    per_q_min double precision := 0.80;
BEGIN
    FOR q IN SELECT * FROM recall_queries ORDER BY qid LOOP
        SELECT COALESCE(array_agg(s.chunk_id ORDER BY s.rrf_score DESC), ARRAY[]::bigint[])
        INTO returned
        FROM ops_search_agent.hybrid_rrf_search(
            q.query_text, q.query_vec,
            'case_test_seed', 'chunks', 'content', 'embedding', 'id',
            60, 60, 10
        ) s;

        hits := (
            SELECT count(*) FROM unnest(returned) AS r(id)
            WHERE r.id = ANY(q.relevant_ids)
        );

        rec_at_k := hits::double precision /
                    GREATEST(array_length(q.relevant_ids, 1), 1)::double precision;

        INSERT INTO recall_results
            (qid, description, relevant_count, returned_ids, hit_count, recall_at_10, passed)
        VALUES (
            q.qid, q.description,
            array_length(q.relevant_ids, 1),
            returned, hits, rec_at_k,
            rec_at_k >= per_q_min
        );
    END LOOP;
END $$;

-- ============================================================================
-- Per-query report (visible in the run_recall.sh output)
-- ============================================================================
SELECT
    qid,
    description,
    relevant_count,
    hit_count,
    ROUND(recall_at_10::numeric, 3) AS recall_at_10,
    passed,
    returned_ids
FROM recall_results
ORDER BY qid;

-- ============================================================================
-- Aggregate
-- ============================================================================
SELECT
    COUNT(*) AS n_queries,
    SUM(passed::int) AS n_passed,
    SUM((NOT passed)::int) AS n_failed,
    ROUND(AVG(recall_at_10)::numeric, 3) AS mean_recall_at_10,
    ROUND(MIN(recall_at_10)::numeric, 3) AS min_recall_at_10
FROM recall_results;

-- ============================================================================
-- Fail-loud assertion
-- ============================================================================
DO $$
DECLARE
    n_failed int;
    mean_r   double precision;
    agg_min  double precision := 0.90;
BEGIN
    SELECT
        SUM((NOT passed)::int),
        AVG(recall_at_10)
    INTO n_failed, mean_r
    FROM recall_results;

    IF n_failed > 0 THEN
        RAISE EXCEPTION
          'recall_benchmark FAILED: % of % queries below per-query threshold 0.80',
          n_failed, (SELECT COUNT(*) FROM recall_results);
    END IF;
    IF mean_r < agg_min THEN
        RAISE EXCEPTION
          'recall_benchmark FAILED: aggregate mean_recall_at_10 % below threshold %',
          mean_r, agg_min;
    END IF;
    RAISE NOTICE 'recall_benchmark PASSED: mean_recall_at_10 = %', mean_r;
END $$;

COMMIT;
