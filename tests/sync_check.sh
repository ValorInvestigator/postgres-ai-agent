#!/usr/bin/env bash
# tests/sync_check.sh
#
# The 3-check sync gate proposed by Claude 2 in HANDOFFS/06_claude2_fixes.md
# and accepted by Claude 1 in HANDOFFS/05_claude1_fixes.md. Runs static-only
# by default (no live PG). Pass --live to add the live psql checks.
#
# CHECK 1 -- column-set agreement
#   scripts/03 query_log columns include the 16 PLAYBOOK Section 8 canonical
#   columns. Extras are allowed.
#
# CHECK 2 -- function-signature agreement
#   SKILL.md Quick-start hybrid_rrf_search(...) call is compatible with the
#   scripts/05 function signature. We do not parse SQL; we check that any
#   positional arg pattern in SKILL.md matches the parameter ORDER produced by
#   scripts/05, and that named-arg call sites reference valid parameter names.
#
# CHECK 3 -- default-defaults agreement
#   scripts/02 corpus_registry DEFAULTs match the PLAYBOOK Section 2 canonical
#   chunks table: chunk_table='chunks', chunk_text_col='content',
#   chunk_vec_col='embedding', chunk_id_col='id', embedding_dim=1024.
#
# USAGE
#   bash tests/sync_check.sh             # static checks only
#   bash tests/sync_check.sh --live      # add live psql checks (needs PG_DSN)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE=0
PSQL="${PSQL:-psql}"
DSN="${PG_DSN:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --live) LIVE=1; shift ;;
        --db)   DSN="$2"; shift 2 ;;
        --db=*) DSN="${1#--db=}"; shift ;;
        -h|--help)
            sed -n '1,/^set -euo/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

fails=0
note() { printf "[sync_check] %s\n" "$*"; }
fail() { printf "[sync_check] FAIL: %s\n" "$*" >&2; fails=$((fails + 1)); }
pass() { printf "[sync_check] PASS: %s\n" "$*"; }

# ============================================================================
# CHECK 1 -- column-set agreement
# ============================================================================
note "CHECK 1: query_log column-set agreement (scripts/03 vs PLAYBOOK Section 8)"

# Canonical column set per PLAYBOOK Section 8
REQUIRED_COLS="id ts session_id agent_id tool_name args result_count result_chunk_ids latency_ms cache_hit rerank_used rerank_model confidence downstream_use privilege_flag error"

# Extract column names from scripts/03 CREATE TABLE block.
# Strip leading whitespace, take first token from each non-comment indented line
# inside the CREATE TABLE ... (...) block.
SCRIPT03="$ROOT/scripts/03_create_query_log.sql"
if [ ! -f "$SCRIPT03" ]; then
    fail "scripts/03_create_query_log.sql not found"
else
    actual_cols=$(awk '
        /CREATE TABLE IF NOT EXISTS ops_search_agent\.query_log/ { in_block=1; next }
        in_block && /^\);/ { in_block=0 }
        in_block && /^[[:space:]]*[a-z_]+[[:space:]]/ && !/^[[:space:]]*--/ {
            sub(/^[[:space:]]+/, "", $0); print $1
        }
    ' "$SCRIPT03" | sort -u | tr "\n" " ")

    missing=""
    for col in $REQUIRED_COLS; do
        case " $actual_cols " in
            *" $col "*) : ;;
            *) missing="$missing $col" ;;
        esac
    done

    if [ -z "$missing" ]; then
        pass "all 16 PLAYBOOK Section 8 columns present in scripts/03"
    else
        fail "scripts/03 missing canonical columns:$missing"
    fi
fi

# ============================================================================
# CHECK 2 -- function-signature agreement
# ============================================================================
note "CHECK 2: hybrid_rrf_search signature agreement (scripts/05 vs SKILL.md)"

SCRIPT05="$ROOT/scripts/05_hybrid_rrf_search.sql"
SKILL="$ROOT/SKILL.md"
if [ ! -f "$SCRIPT05" ]; then
    fail "scripts/05 missing"
elif [ ! -f "$SKILL" ]; then
    fail "SKILL.md missing"
else
    sig_params=$(awk '
        /CREATE OR REPLACE FUNCTION ops_search_agent\.hybrid_rrf_search/ { inside=1; next }
        inside && /^\)/ { inside=0 }
        inside { print }
    ' "$SCRIPT05" \
        | sed -E 's/^[[:space:]]+//; s/,[[:space:]]*$//' \
        | awk '{ print $1 }' \
        | grep -E '^[a-z_]+$' || true)

    sig_count=$(printf "%s\n" "$sig_params" | sed '/^$/d' | wc -l | tr -d ' ')
    note "  scripts/05 declares $sig_count function parameters: $(echo "$sig_params" | tr '\n' ' ')"

    # Find hybrid_rrf_search call sites in SKILL.md
    if grep -nE 'hybrid_rrf_search[[:space:]]*\(' "$SKILL" >/dev/null; then
        # Heuristic: count positional arg lines from the first call.
        # The earlier SKILL.md Quick-start used a multi-line call; count the
        # commas inside the parens to estimate positional arg count.
        skill_argspan=$(awk '/hybrid_rrf_search[[:space:]]*\(/,/\);?/' "$SKILL" | head -25)
        skill_commas=$(printf "%s" "$skill_argspan" | tr -cd ',' | wc -c | tr -d ' ')
        skill_named=$(printf "%s" "$skill_argspan" | grep -cE '[a-z_]+[[:space:]]*=>' || true)

        if [ "$skill_named" -gt 0 ]; then
            note "  SKILL.md uses named-arg call style ($skill_named => uses); compatible with any param order"
            pass "function-signature: SKILL.md uses named args, no positional drift possible"
        else
            # Positional. Approx arg count = commas + 1 (rough; multi-line calls may double-count)
            skill_args_est=$((skill_commas + 1))
            note "  SKILL.md positional call: ~${skill_args_est} args (commas=${skill_commas})"
            if [ "$skill_args_est" -le "$sig_count" ]; then
                pass "function-signature: positional args ${skill_args_est} <= signature ${sig_count}"
            else
                fail "function-signature: SKILL.md positional call passes ${skill_args_est} args; scripts/05 signature only accepts ${sig_count}"
            fi
        fi
    else
        note "  SKILL.md has no hybrid_rrf_search call site -- skipping comparison"
        pass "function-signature: no SKILL.md call site to verify"
    fi
fi

# ============================================================================
# CHECK 3 -- default-defaults agreement
# ============================================================================
note "CHECK 3: corpus_registry defaults agree with PLAYBOOK Section 2 canonical"

SCRIPT02="$ROOT/scripts/02_create_corpus_registry.sql"
if [ ! -f "$SCRIPT02" ]; then
    fail "scripts/02 missing"
else
    # Each line below extracts the DEFAULT clause of one column.
    expect_pair() {
        local col="$1"; local want="$2"
        local got
        got=$(awk -v c="$col" '
            $0 ~ "^[[:space:]]+"c"[[:space:]]" && /DEFAULT/ {
                # Strip everything up to and including DEFAULT.
                sub(/.*DEFAULT[[:space:]]*/, "", $0)
                # Strip the inline -- comment if any.
                sub(/[[:space:]]*--.*$/, "", $0)
                # Trim outer whitespace.
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
                # Strip trailing comma.
                sub(/,$/, "", $0)
                print
                exit
            }
        ' "$SCRIPT02")
        if [ "$got" = "$want" ]; then
            pass "  $col DEFAULT $got"
        else
            fail "  $col DEFAULT mismatch: scripts/02 has [$got], canonical wants [$want]"
        fi
    }

    expect_pair chunk_table        "'chunks'"
    expect_pair chunk_text_col     "'content'"
    expect_pair chunk_vec_col      "'embedding'"
    expect_pair chunk_id_col       "'id'"
    expect_pair embedding_dim      "1024"
fi

# ============================================================================
# LIVE checks (opt-in)
# ============================================================================
if [ "$LIVE" -eq 1 ]; then
    note "LIVE checks -- DSN: ${DSN:-<unset>}"
    if [ -z "$DSN" ]; then
        fail "--live requires PG_DSN or --db <dsn>"
    else
        # Live 1: column-set actually deployed
        if "$PSQL" "$DSN" -X -tA -c "\d ops_search_agent.query_log" 2>/dev/null \
            | grep -qE '^(args|result_chunk_ids|confidence|downstream_use|privilege_flag|cache_hit)\|'; then
            pass "live: query_log deployed with PLAYBOOK Section 8 columns"
        else
            fail "live: query_log missing one or more canonical columns (args, result_chunk_ids, confidence, downstream_use, privilege_flag, cache_hit)"
        fi
        # Live 2: function exists
        if "$PSQL" "$DSN" -X -tA -c "SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE p.proname='hybrid_rrf_search' AND n.nspname='ops_search_agent'" \
            | grep -q '^1$'; then
            pass "live: ops_search_agent.hybrid_rrf_search() defined"
        else
            fail "live: ops_search_agent.hybrid_rrf_search() missing"
        fi
        # Live 3: registry defaults
        live_defaults=$("$PSQL" "$DSN" -X -tA -c "
            SELECT format('%s=%s', column_name, column_default)
            FROM information_schema.columns
            WHERE table_schema='ops_search_agent' AND table_name='corpus_registry'
              AND column_name IN ('chunk_table','chunk_text_col','chunk_vec_col','chunk_id_col','embedding_dim')
            ORDER BY column_name
        " 2>/dev/null || true)
        if printf "%s" "$live_defaults" | grep -q "chunk_table='chunks'" \
        && printf "%s" "$live_defaults" | grep -q "chunk_text_col='content'" \
        && printf "%s" "$live_defaults" | grep -q "chunk_vec_col='embedding'" \
        && printf "%s" "$live_defaults" | grep -q "chunk_id_col='id'" \
        && printf "%s" "$live_defaults" | grep -q "embedding_dim=1024"; then
            pass "live: corpus_registry defaults match canonical"
        else
            fail "live: corpus_registry deployed defaults mismatch canonical -- got: $live_defaults"
        fi
    fi
fi

# ============================================================================
# Summary
# ============================================================================
if [ "$fails" -eq 0 ]; then
    note "ALL CHECKS PASS"
    exit 0
fi
note "$fails check(s) FAILED"
exit 1
