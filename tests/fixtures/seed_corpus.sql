-- tests/fixtures/seed_corpus.sql
-- Synthetic 3-cluster corpus for deterministic recall testing.
--
-- Layout follows PLAYBOOK Section 2 canonical:
--   case_test_seed.chunks (id, source_file_id, chunk_idx, content,
--                          content_tsv, embedding, embedding_model,
--                          metadata, ingested_at, deleted_at)
--   case_test_seed.source_files (id, sha256, path, ...)
--
-- THREE SEMANTIC CLUSTERS
--   civil-rights (chunk ids 1..6)
--   probate      (chunk ids 7..12)
--   medical      (chunk ids 13..18)
--   noise        (chunk ids 19..20)
--
-- EMBEDDING: hand-crafted 8-dim float vectors so vector_leg is deterministic.
-- Cluster axes: civil-rights -> dim 0, probate -> dim 1, medical -> dim 2.
-- Small perturbations on the cluster axis keep ordering stable; near-zero on
-- other axes keeps clusters separable.
--
-- TSVECTOR: each chunk uses cluster-specific keywords so FTS leg ranks well.
-- PG_TRGM: keyword variations + misspellings so trgm leg has signal.
--
-- The function `ops_search_agent.hybrid_rrf_search` accepts unsized `vector`,
-- so the 8-dim test corpus is compatible without modification.

\set ON_ERROR_STOP on

BEGIN;

DROP SCHEMA IF EXISTS case_test_seed CASCADE;
CREATE SCHEMA case_test_seed;

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================================
-- source_files (one synthetic file per cluster + a noise file)
-- ============================================================================
CREATE TABLE case_test_seed.source_files (
    id        bigserial PRIMARY KEY,
    sha256    text UNIQUE NOT NULL,
    path      text NOT NULL,
    cluster   text NOT NULL  -- 'civil_rights' | 'probate' | 'medical' | 'noise'
);

INSERT INTO case_test_seed.source_files (id, sha256, path, cluster) VALUES
    (1, repeat('a', 64), '/synth/civil_rights.txt', 'civil_rights'),
    (2, repeat('b', 64), '/synth/probate.txt',      'probate'),
    (3, repeat('c', 64), '/synth/medical.txt',      'medical'),
    (4, repeat('d', 64), '/synth/noise.txt',        'noise');

SELECT setval(pg_get_serial_sequence('case_test_seed.source_files', 'id'),
              (SELECT max(id) FROM case_test_seed.source_files));

-- ============================================================================
-- chunks: PLAYBOOK Section 2 canonical layout
-- ============================================================================
CREATE TABLE case_test_seed.chunks (
    id              bigserial PRIMARY KEY,
    source_file_id  bigint NOT NULL REFERENCES case_test_seed.source_files(id),
    chunk_idx       integer NOT NULL,
    content         text NOT NULL,
    content_tsv     tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
    embedding       vector(8),                                        -- 8-dim for testability
    embedding_model text NOT NULL DEFAULT 'synthetic/8dim-cluster-axes',
    metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
    ingested_at     timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz                                       -- soft-delete column from PLAYBOOK
);

-- Indexes (function prerequisites)
CREATE INDEX chunks_hnsw_idx   ON case_test_seed.chunks USING hnsw (embedding vector_cosine_ops);
CREATE INDEX chunks_tsv_idx    ON case_test_seed.chunks USING gin (content_tsv);
CREATE INDEX chunks_trgm_idx   ON case_test_seed.chunks USING gin (content gin_trgm_ops);
CREATE INDEX chunks_source_idx ON case_test_seed.chunks (source_file_id, chunk_idx);

-- ============================================================================
-- CLUSTER A: civil rights (ids 1..6)
-- Embedding axis: dim 0
-- ============================================================================
INSERT INTO case_test_seed.chunks (id, source_file_id, chunk_idx, content, embedding) VALUES
    (1, 1, 0,
     'Plaintiff brings this section 1983 civil rights action against the state for the denial of due process under the Fourteenth Amendment.',
     '[0.98, 0.01, 0.02, 0.00, 0.01, 0.00, 0.00, 0.00]'),
    (2, 1, 1,
     'The constitutional violation occurred when defendants conspired under color of state law to deprive plaintiff of equal protection.',
     '[0.96, 0.03, 0.01, 0.01, 0.00, 0.01, 0.00, 0.00]'),
    (3, 1, 2,
     'Federal civil rights litigation under 42 U.S.C. 1983 requires a showing of state action and constitutional injury.',
     '[0.97, 0.00, 0.02, 0.00, 0.01, 0.00, 0.01, 0.00]'),
    (4, 1, 3,
     'The court must analyze municipal liability under Monell v. Department of Social Services for the civil rights claim.',
     '[0.95, 0.02, 0.01, 0.02, 0.00, 0.00, 0.00, 0.01]'),
    (5, 1, 4,
     'Section 1985 conspiracy claims require an agreement and an overt act in furtherance of the civil rights deprivation.',
     '[0.94, 0.04, 0.00, 0.01, 0.01, 0.00, 0.00, 0.00]'),
    (6, 1, 5,
     'Qualified immunity bars civil rights suits against officials unless clearly established law put them on notice.',
     '[0.93, 0.05, 0.01, 0.00, 0.00, 0.00, 0.01, 0.00]');

-- ============================================================================
-- CLUSTER B: probate (ids 7..12)
-- Embedding axis: dim 1
-- ============================================================================
INSERT INTO case_test_seed.chunks (id, source_file_id, chunk_idx, content, embedding) VALUES
    (7,  2, 0,
     'The probate court appoints a personal representative to administer the estate of the decedent under ORS 113.085.',
     '[0.02, 0.97, 0.01, 0.00, 0.00, 0.00, 0.00, 0.00]'),
    (8,  2, 1,
     'A petition for letters testamentary requires the original will and a death certificate be filed with the probate court.',
     '[0.01, 0.96, 0.02, 0.01, 0.00, 0.00, 0.00, 0.01]'),
    (9,  2, 2,
     'Estate administration includes inventorying assets, notifying creditors, paying debts, and distributing residue to devisees.',
     '[0.03, 0.95, 0.00, 0.02, 0.00, 0.00, 0.00, 0.00]'),
    (10, 2, 3,
     'Co-personal representatives may be appointed when the will nominates more than one or when the heirs cannot agree.',
     '[0.02, 0.94, 0.01, 0.01, 0.01, 0.01, 0.00, 0.00]'),
    (11, 2, 4,
     'The probate inventory must be filed within ninety days of appointment and lists every asset of the decedent.',
     '[0.00, 0.97, 0.02, 0.00, 0.00, 0.00, 0.00, 0.01]'),
    (12, 2, 5,
     'Successor personal representative is appointed when the original PR resigns, dies, or is removed for cause.',
     '[0.01, 0.96, 0.00, 0.02, 0.00, 0.00, 0.01, 0.00]');

-- ============================================================================
-- CLUSTER C: medical records (ids 13..18)
-- Embedding axis: dim 2
-- ============================================================================
INSERT INTO case_test_seed.chunks (id, source_file_id, chunk_idx, content, embedding) VALUES
    (13, 3, 0,
     'Patient medical records are governed by HIPAA at 45 CFR 164.524 with a 30-day production deadline.',
     '[0.01, 0.00, 0.98, 0.00, 0.01, 0.00, 0.00, 0.00]'),
    (14, 3, 1,
     'The HIPAA personal representative provision at 45 CFR 164.502(g) allows family access to a deceased patient chart.',
     '[0.02, 0.03, 0.95, 0.00, 0.00, 0.00, 0.00, 0.00]'),
    (15, 3, 2,
     'Hospital chart audit logs are required by HIPAA Security Rule and must capture every read of protected health information.',
     '[0.00, 0.01, 0.97, 0.01, 0.00, 0.01, 0.00, 0.00]'),
    (16, 3, 3,
     'Electronic medical record vendors include Epic, Cerner, and Meditech with native audit-log export capability.',
     '[0.01, 0.00, 0.96, 0.02, 0.00, 0.00, 0.00, 0.01]'),
    (17, 3, 4,
     'HIPAA designated record set means the protected health information used to make decisions about a patient.',
     '[0.03, 0.01, 0.94, 0.01, 0.01, 0.00, 0.00, 0.00]'),
    (18, 3, 5,
     'Medical records audit trail discovery in litigation requires native field-level logs not summary reports.',
     '[0.00, 0.02, 0.95, 0.01, 0.00, 0.00, 0.01, 0.01]');

-- ============================================================================
-- NOISE: orthogonal chunks (ids 19..20). Used as decoys.
-- ============================================================================
INSERT INTO case_test_seed.chunks (id, source_file_id, chunk_idx, content, embedding) VALUES
    (19, 4, 0,
     'The capital of France is Paris and the Seine flows through the city in a generally westward direction.',
     '[0.00, 0.00, 0.00, 0.95, 0.05, 0.00, 0.00, 0.00]'),
    (20, 4, 1,
     'Photosynthesis converts light energy into chemical energy stored in glucose by chlorophyll-bearing organisms.',
     '[0.00, 0.00, 0.00, 0.00, 0.95, 0.00, 0.05, 0.00]');

SELECT setval(pg_get_serial_sequence('case_test_seed.chunks', 'id'),
              (SELECT max(id) FROM case_test_seed.chunks));

-- ============================================================================
-- Register in corpus_registry so v_evidence_search auto-rebuilds.
-- Embedding type is vector(8); other corpora using halfvec(1024) or vector(N)
-- will type-mismatch the UNION ALL. Set in_evidence_search=false to keep the
-- test schema isolated from the main view.
-- ============================================================================
INSERT INTO ops_search_agent.corpus_registry (
    schema_name, corpus_type, description,
    embedding_model, embedding_dim,
    chunk_table, chunk_text_col, chunk_vec_col, chunk_id_col,
    source_files_table, in_evidence_search
) VALUES (
    'case_test_seed', 'case', 'Synthetic 3-cluster recall-test corpus',
    'synthetic/8dim-cluster-axes', 8,
    'chunks', 'content', 'embedding', 'id',
    'source_files', false
)
ON CONFLICT (schema_name) DO UPDATE
SET embedding_dim = 8,
    chunk_table = 'chunks',
    chunk_text_col = 'content',
    chunk_vec_col = 'embedding',
    chunk_id_col = 'id';

COMMIT;

-- Verify
SELECT
    sf.cluster,
    COUNT(*) AS n_chunks
FROM case_test_seed.chunks c
JOIN case_test_seed.source_files sf ON sf.id = c.source_file_id
GROUP BY sf.cluster
ORDER BY sf.cluster;
