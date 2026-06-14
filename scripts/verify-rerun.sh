#!/usr/bin/env bash
# verify-rerun.sh — Phase 4 verification: prove the killing tests actually catch the
# claimed mutants with ONE scoped cargo-mutants re-run.
#
# Contract:
#   1. nextest must be green ONCE (baseline + the new kill tests) — else exit 4.
#   2. ONE scoped cargo-mutants re-run over the findings' files/fns, written to a SEPARATE
#      output dir so the original mutants.out/ is not clobbered.
#   3. The run's summary line ("N mutants tested ... : M missed") is used ONLY for the binary
#      infra judgment (did the run complete, or flood?). Per-finding caught/missed comes from
#      the re-run outcomes.json: a finding is CAUGHT iff NONE of its claimed_killed mutant
#      .name values appears in the fresh MissedMutant rows.
#   4. Writes verify.json (per-finding status) and patches nothing — the orchestrator patches
#      findings.json[].status from verify.json before any resume decision.
#
# Usage:
#   verify-rerun.sh CLAIMS_JSON [-o VERIFY_JSON] [-d MUT_OUT_DIR] [-t TIMEOUT] -- <scope args>
#     CLAIMS_JSON : { "scope": "...", "per_finding": [ { "finding_id":"F1",
#                       "claimed_killed": ["src/lib.rs:2:15: replace - with + in residual"] } ] }
#     scope args  : passed verbatim to cargo mutants, e.g.  --file src/lib.rs  or  -F 'residual|scale'
#
# Exit codes: 0 all caught · 4 nextest red · 5 infra/flood (no usable outcomes) · 6 ≥1 not caught
#             · 2 missing claims file · 3 jq not installed.
# NEVER uses rm.

set -euo pipefail

VERIFY_JSON="verify.json"
MUT_OUT="mutants-verify.out"
TIMEOUT="60"
CLAIMS=""

# --- arg parse: options before "--", scope args after ---------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -o) [ $# -ge 2 ] || { echo "verify-rerun.sh: -o needs an argument" >&2; exit 2; }; VERIFY_JSON="$2"; shift 2 ;;
    -d) [ $# -ge 2 ] || { echo "verify-rerun.sh: -d needs an argument" >&2; exit 2; }; MUT_OUT="$2"; shift 2 ;;
    -t) [ $# -ge 2 ] || { echo "verify-rerun.sh: -t needs an argument" >&2; exit 2; }; TIMEOUT="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "verify-rerun.sh: unknown option $1" >&2; exit 2 ;;
    *)  if [ -z "$CLAIMS" ]; then CLAIMS="$1"; shift; else echo "verify-rerun.sh: unexpected arg $1" >&2; exit 2; fi ;;
  esac
done
SCOPE_ARGS=("$@")

command -v jq >/dev/null 2>&1 || { echo "verify-rerun.sh: jq required" >&2; exit 3; }
[ -n "$CLAIMS" ] && [ -f "$CLAIMS" ] || { echo "verify-rerun.sh: claims json not found: '$CLAIMS'" >&2; exit 2; }

# --- 1. nextest green once ------------------------------------------------------
echo "verify-rerun.sh: running nextest (must be green)…" >&2
if ! cargo nextest run >/tmp/mko-verify-nextest.log 2>&1; then
  echo "verify-rerun.sh: nextest is RED — fix the suite before verifying. See /tmp/mko-verify-nextest.log" >&2
  exit 4
fi

# --- non-fatal dedup scan: duplicate kill_mutant_* fn names ---------------------
dupes=$(grep -rhoE 'fn kill_mutant_[A-Za-z0-9_]+' tests src 2>/dev/null | sort | uniq -d || true)
[ -n "$dupes" ] && echo "verify-rerun.sh: WARNING duplicate kill_mutant_* fns: $dupes" >&2

# --- 2. one scoped re-run into a SEPARATE output dir ----------------------------
ncpu="$( { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4; } )"
echo "verify-rerun.sh: scoped re-run -> $MUT_OUT (scope: ${SCOPE_ARGS[*]:-<none>})…" >&2
RERUN_LOG="/tmp/mko-verify-rerun.log"
# "${SCOPE_ARGS[@]+...}" is the empty-array-safe expansion: on bash 4.0-4.3 a bare
# "${SCOPE_ARGS[@]}" on an empty array under set -u aborts with "unbound variable".
cargo mutants --test-tool nextest --jobs "$ncpu" --timeout "$TIMEOUT" \
  --output "$MUT_OUT" "${SCOPE_ARGS[@]+"${SCOPE_ARGS[@]}"}" >"$RERUN_LOG" 2>&1 || true

# cargo-mutants --output DIR writes to DIR/mutants.out/outcomes.json (it creates the
# mutants.out/ subdir itself), so the outcomes file is one level deeper than MUT_OUT.
OUTCOMES="$MUT_OUT/mutants.out/outcomes.json"
# --- 3. infra judgment from the summary line + outcomes presence ---------------
summary="$(grep -E '[0-9]+ mutants tested' "$RERUN_LOG" | tail -1 || true)"
if [ ! -f "$OUTCOMES" ] || ! jq -e . "$OUTCOMES" >/dev/null 2>&1; then
  echo "verify-rerun.sh: infra failure — no usable $OUTCOMES (likely build flood). Summary: ${summary:-none}. See $RERUN_LOG" >&2
  exit 5
fi
echo "verify-rerun.sh: re-run complete — ${summary:-<no summary line>}" >&2

# --- 4. per-finding caught/missed from the re-run outcomes ----------------------
FRESH_MISSED="$(jq -c '[.outcomes[]|select(.summary=="MissedMutant")|.scenario.Mutant.name]' "$OUTCOMES")"
TS="$(date -u +%FT%TZ)"
# Build the scope-args JSON without a spurious [""] element when SCOPE_ARGS is empty.
SCOPE_JSON="$(if [ "${#SCOPE_ARGS[@]}" -gt 0 ]; then printf '%s\n' "${SCOPE_ARGS[@]}"; fi | jq -R . | jq -s -c .)"

jq -n \
  --slurpfile claims "$CLAIMS" \
  --argjson missed "$FRESH_MISSED" \
  --arg ts "$TS" \
  --argjson scope_args "$SCOPE_JSON" '
  $claims[0] as $c
  | { generated_at: $ts,
      scope: ($c.scope // ($scope_args|join(" "))),
      per_finding:
        [ $c.per_finding[]
          | (.claimed_killed // []) as $ck
          | ( ($ck|length) > 0 and (any($ck[]; . as $n | ($missed|index($n)) != null) | not) ) as $caught
          | { finding_id: .finding_id,
              claimed_killed: $ck,
              caught: $caught,
              status: (if $caught then "caught" else "missed" end) } ] }
' > "$VERIFY_JSON"

n_missed=$(jq '[.per_finding[]|select(.caught|not)]|length' "$VERIFY_JSON")
n_total=$(jq '.per_finding|length' "$VERIFY_JSON")
echo "verify-rerun.sh: wrote $VERIFY_JSON — $((n_total - n_missed))/$n_total findings CAUGHT" >&2

[ "$n_missed" -eq 0 ] || exit 6
