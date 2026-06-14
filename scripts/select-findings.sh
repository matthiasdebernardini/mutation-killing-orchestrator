#!/usr/bin/env bash
# select-findings.sh — deterministic pre-grouping of cargo-mutants survivors.
#
# Owns the work the triage agent must NOT re-do: filter MissedMutant rows from
# outcomes.json, group them by the canonical merge key (file, function_name, line),
# compute cluster size (kills_per_test), parse op-class from the mutant .name (the swap
# is NOT in .replacement), and pre-tag obvious noise. Emits one grouped+noise-pretagged
# JSON document to a fixed path for the Opus triage agent to consume with no further jq.
#
# Usage:   select-findings.sh [OUTCOMES_JSON] [GROUPED_OUT]
#   OUTCOMES_JSON  default: mutants.out/outcomes.json
#   GROUPED_OUT    default: mutants.out/mko-grouped.json  ("-" = stdout)
#
# Exit codes: 0 ok · 1 schema drift (renamed counter/enum) · 2 missing/malformed outcomes file · 3 jq not installed.
# NEVER uses rm.

set -euo pipefail

OUTCOMES="${1:-mutants.out/outcomes.json}"
GROUPED="${2:-mutants.out/mko-grouped.json}"

# --- preconditions (jq is a HARD requirement, not a soft skip) ------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "select-findings.sh: jq is required but not installed (brew install jq)" >&2
  exit 3
fi
if [ ! -f "$OUTCOMES" ]; then
  echo "select-findings.sh: outcomes file not found: $OUTCOMES" >&2
  exit 2
fi

# --- schema-drift guard: MissedMutant filter count must equal top-level .missed -
# A jq parse/eval failure (truncated file, missing .outcomes) maps to exit 2, NOT jq's raw
# exit 5 (which would collide with verify-rerun.sh's documented "infra/flood" code 5).
n=$(jq '[.outcomes[]|select(.summary=="MissedMutant")]|length' "$OUTCOMES") \
  || { echo "select-findings.sh: $OUTCOMES is not valid/parseable JSON (or .outcomes is missing)" >&2; exit 2; }
m=$(jq '.missed' "$OUTCOMES") \
  || { echo "select-findings.sh: $OUTCOMES is not valid/parseable JSON" >&2; exit 2; }
case "$n" in ''|*[!0-9]*)
  echo "select-findings.sh: could not count MissedMutant rows (got '$n') — .outcomes missing or malformed" >&2; exit 2 ;;
esac
# A missing/non-numeric top-level .missed IS the drift this guard exists to catch — jq returns
# the string "null" for an absent key, so validate it is an integer rather than comparing blind.
case "$m" in ''|*[!0-9]*)
  echo "select-findings.sh: schema drift — top-level .missed is missing or non-numeric (got '$m'); the counter/enum was likely renamed in this cargo-mutants version" >&2; exit 1 ;;
esac
if [ "$n" -ne "$m" ]; then
  echo "select-findings.sh: schema drift — MissedMutant filter ($n) != top-level .missed ($m); the summary enum was likely renamed in this cargo-mutants version" >&2
  exit 1
fi

# --- build the grouped document -------------------------------------------------
# op-class is derived from genre + the original operator parsed out of .name.
# Severity tiers: arithmetic 5 · comparison/boolean/fnvalue/unary 3 · label/other 1.
JQ_PROG='
def opclass(genre; name):
  if genre == "FnValue" then
    ( if (name|test("as_str|::fmt|Display|Debug|to_string")) then {op_class:"label", sev:1}
      else {op_class:"fnvalue", sev:3} end )
  elif genre == "BinaryOperator" then
    ( (name | capture("replace (?<a>[^ ]+) with ") | .a) // "?" ) as $orig
    | if   ($orig|test("^[-+*/%]$"))            then {op_class:"arithmetic", sev:5}
      elif ($orig|test("^(<|>|<=|>=|==|!=)$"))  then {op_class:"comparison", sev:3}
      elif ($orig|test("^(&&|\\|\\|)$"))        then {op_class:"boolean",    sev:3}
      else                                            {op_class:"binop-other", sev:3} end
  elif genre == "UnaryOperator" then {op_class:"unary", sev:3}
  elif (name|test("as_str|Display|Debug")) then {op_class:"label", sev:1}
  else {op_class:"other", sev:1} end;

def pathnoise(file):
  if   (file|test("kani"))                  then "proof-harness"
  elif (file|test("/benches/|(^|/)benches")) then "bench"
  elif (file|test("/examples/|(^|/)examples")) then "example"
  elif (file|test("build\\.rs$"))           then "build-script"
  else null end;

{ source: $src, missed_total: (.missed) }
+ { findings:
    ( [ .outcomes[]
        | select(.summary=="MissedMutant")
        | .scenario.Mutant as $m
        | ($m.name) as $name
        | (opclass($m.genre; $name)) as $oc
        | { file:          $m.file,
            function_name: $m.function.function_name,
            line:          $m.span.start.line,
            return_type:   ($m.function.return_type // null),
            genre:         $m.genre,
            replacement:   $m.replacement,
            name:          $name,
            op_class:      $oc.op_class,
            silent_severity: $oc.sev } ]
      | group_by([.file, .function_name, .line])
      | map(
          ( .[0].file ) as $file
          | ( [ .[] | select(.op_class!="label") ] | length == 0 ) as $all_label
          | ( pathnoise($file) ) as $pn
          | { file: $file,
              function_name: .[0].function_name,
              line: .[0].line,
              return_type: .[0].return_type,
              kills_per_test: length,
              max_silent_severity: ( [ .[].silent_severity ] | max ),
              op_classes: ( [ .[].op_class ] | unique ),
              noise: ( ($pn != null) or $all_label ),
              noise_reason: ( if $pn != null then $pn elif $all_label then "label-noise" else null end ),
              members: ( [ .[] | {name, genre, replacement, op_class, silent_severity} ] ) } )
      | sort_by( [ (if .noise then 1 else 0 end), (-(.max_silent_severity)), (-(.kills_per_test)) ] ) ) }
'

RESULT=$(jq -c --arg src "$OUTCOMES" "$JQ_PROG" "$OUTCOMES") \
  || { echo "select-findings.sh: failed to build grouped JSON from $OUTCOMES (malformed outcomes?)" >&2; exit 2; }

if [ "$GROUPED" = "-" ]; then
  printf '%s\n' "$RESULT" | jq .
else
  mkdir -p "$(dirname "$GROUPED")"
  printf '%s\n' "$RESULT" | jq . > "$GROUPED"
  killable=$(printf '%s' "$RESULT" | jq '[.findings[]|select(.noise|not)]|length')
  noise=$(printf '%s' "$RESULT" | jq '[.findings[]|select(.noise)]|length')
  echo "select-findings.sh: wrote $GROUPED — $m missed → $(printf '%s' "$RESULT" | jq '.findings|length') findings ($killable killable, $noise pre-tagged noise)" >&2
fi
