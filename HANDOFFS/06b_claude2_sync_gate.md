# 06b -- Claude 2 -- Phase 3 sync-gate result (post claude-1 fixes)

## Slice

This is a follow-up to `06_claude2_fixes.md` -- runs the 3-check sync gate I proposed in Ask 4 against claude-1's Phase 3 scripts + applies the SKILL.md Quick-start example fix to close the watch-item claude-1 flagged.

## Status

FIXES (sync gate verification + watch-item resolution)

## Sync gate run

Per Ask 4 in `06_claude2_fixes.md`, the 3 checks to run at end of Phase 3:

### Check 1 -- Column-set agreement

PLAYBOOK Section 8 canonical query_log columns vs scripts/03 actual columns:

| Canonical column | In scripts/03? | Type matches |
|------------------|----------------|--------------|
| id | yes (bigserial PRIMARY KEY) | yes |
| ts | yes (timestamptz NOT NULL DEFAULT now()) | yes |
| session_id | yes (text NOT NULL) | yes |
| agent_id | yes (text NOT NULL) | yes |
| tool_name | yes (text NOT NULL) | yes |
| args | yes (jsonb NOT NULL DEFAULT '{}'::jsonb) | yes |
| result_count | yes (integer) | yes |
| result_chunk_ids | yes (bigint[]) | yes -- BIGINT[] per Ask 2 decision |
| latency_ms | yes (integer) | yes |
| cache_hit | yes (boolean NOT NULL DEFAULT false) | yes |
| rerank_used | yes (boolean NOT NULL DEFAULT false) | yes |
| rerank_model | yes (text) | yes |
| confidence | yes (double precision) | yes |
| downstream_use | yes (text) | yes |
| privilege_flag | yes (boolean NOT NULL DEFAULT false) | yes |
| error | yes (text) | yes |

Plus useful extras kept: `query_text`, `query_text_hash` (with COALESCE for NULL safety), `embedding_model`, `schema_targets`, `k`, `rrf_k`, `top_score`, `user_judgment` family.

**PASS.** All 16 canonical PLAYBOOK Section 8 columns present in scripts/03 with correct types.

### Check 2 -- Function-signature agreement

scripts/05 `hybrid_rrf_search` signature (per origin/build/claude-1 eb1b498):

```sql
hybrid_rrf_search(
    query_text       text,
    query_vec        vector,
    target_schema    text,
    target_table     text DEFAULT 'chunks',
    text_col         text DEFAULT 'content',
    vec_col          text DEFAULT 'embedding',
    chunk_id_col     text DEFAULT 'id',
    k_per_leg        integer DEFAULT 60,
    rrf_k            integer DEFAULT 60,
    final_k          integer DEFAULT 20
)
```

My prior SKILL.md Quick-start example used named-args `k =>`, `per_leg =>`, `rrf_k =>` -- DID NOT MATCH the signature.

**FIXED in commit 1b7c2c9 (just pushed).** SKILL.md Quick-start now uses:
- `query_text =>`
- `query_vec =>`
- `target_schema => 'case_26cv11493_hearing_prep'` (required; no default)
- `k_per_leg => 60`
- `rrf_k => 60`
- `final_k => 20`

Schema-qualified function name (`ops_search_agent.hybrid_rrf_search`) used. Comment added noting target_schema is required and other defaults are PLAYBOOK Section 2 canonical.

**PASS** after fix.

### Check 3 -- Default-defaults agreement

scripts/02 corpus_registry defaults (per origin/build/claude-1 eb1b498):

```sql
embedding_model    text NOT NULL DEFAULT 'voyageai/voyage-context-3',
embedding_dim      integer NOT NULL DEFAULT 1024,
chunk_table        text NOT NULL DEFAULT 'chunks',
chunk_text_col     text NOT NULL DEFAULT 'content',
chunk_vec_col      text NOT NULL DEFAULT 'embedding',
chunk_id_col       text NOT NULL DEFAULT 'id',
```

PLAYBOOK Section 2 canonical schema uses table=`chunks`, content column=`content`, embedding=`halfvec(1024)`. Defaults match canonical.

**PASS.** Defaults aligned to PLAYBOOK Section 2.

## Watch-item resolution

Claude-1 flagged: "I added `chunk_id_col text DEFAULT 'id'` to hybrid_rrf_search signature between vec_col and k_per_leg. If SKILL.md Quick-start passes positional args past vec_col, the new param shifts k_per_leg -- needs a named-arg call or doc tweak."

SKILL.md Quick-start was already using named-arg form (with the wrong names). Fix in commit `1b7c2c9` updates all named args to match the new signature including `chunk_id_col` default (not passed, relies on default `'id'`).

## Commits landed this phase

- `5f3cfda  phase3 cleanup: soften em-dash style rule per claude-1 EM_DASH_RULE_CLARIFICATION`
- `1b7c2c9  phase3 sync: align SKILL.md Quick-start example to claude-1 hybrid_rrf_search signature`

Plus the prior:
- `995a935  phase3: apply all docs-slice fixes (claude-2 self-audit + claude-1 red-team)`
- `d60a32d  phase3: claude-2 fixes handoff + STATE.md update`

## Confirmation of claude-1's reconciled cross-slice decisions

- result_chunk_ids = BIGINT[]: scripts/03 confirmed; PLAYBOOK Section 8 confirmed
- BQ scope acknowledged in SKILL.md frontmatter: confirmed (commit 995a935)
- 3-check sync gate accepted by claude-1: gate run + all 3 checks pass

## Asks of Claude 1

1. Phase 4a kickoff -- the test harness sub-slice (BUILD_PROTOCOL.md "Phase 4 -- tests/ sub-slice"). Per protocol I build `tests/latency_benchmark.py` + `tests/README.md`; you build `tests/fixtures/seed_corpus.sql` + `tests/recall_benchmark.sql` + `tests/run_recall.sh`. Confirm we kick off Phase 4a now or wait for sign-off on Phase 3 fixes first.

2. Should `tests/sync_check.sh` (per my Ask 4 in 06_claude2_fixes.md) be:
   - (a) Built in Phase 4a alongside the recall + latency harnesses (as a third script verifying SKILL/PLAYBOOK <-> scripts agreement at every commit), OR
   - (b) Deferred to a future iteration?

   Recommend (a). The 3 checks I just ran manually become a 30-line bash script that lives in tests/.

3. The `tests/README.md` I build in Phase 4 will document how to run all three harnesses (recall, latency, sync). Confirm scope.

## Open questions / deferred

- gemini_supplements wave 3 coverage gap (asymmetric 7+4+1+0) noted in SKILL.md + README.md. Deferred to a future iteration if Levi commissions a wave_3 schema design supplement.
- The `valor_agent` role-name placeholder appears in both docs (PLAYBOOK Section 4.3) and scripts (scripts/01 uses `:"role"` psql var with documented `psql -v role=valor_agent ...` invocation per claude-1's Phase 3 fix). Consistent. Closed.
- LICENSE consistency verified clean.

[CLAUDE-2 // 2026-05-20T09:55Z]
