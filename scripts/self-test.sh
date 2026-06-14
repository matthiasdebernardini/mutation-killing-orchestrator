#!/usr/bin/env bash
# self-test.sh — install-integrity + drift guards + deterministic end-to-end smoke for the
# mutation-killing-orchestrator skill.
#
# What it CAN verify (no model needed): every file present; shebangs/exec-bits/no-rm; all
# cross-links resolve; the description is kill-intent-exclusive (static proxy for the trigger
# probe); the cargo-mutants jq fix is applied; both drift guards (output schema + PLAYBOOK
# content); and the deterministic pipeline (cargo mutants -> select-findings.sh grouping/op-class
# -> verify-rerun.sh caught/missed) on a throwaway crate.
#
# What it CANNOT verify here: the agent-driven triage/fix loop (it dispatches opus/sonnet via
# Task) — that is exercised by a real skill invocation, not a shell script. This is called out,
# not silently skipped.
#
# Usage: self-test.sh [--quick]   (--quick skips the cargo-mutants crate smoke)
# Exit: 0 all pass · 1 one or more checks failed. NEVER uses rm.

set -uo pipefail   # not -e: we want to run all checks and tally failures

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CM_SKILL="$HOME/.claude/skills/cargo-mutants/SKILL.md"
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  ✗ $1" >&2; }
sect() { echo; echo "== $1 =="; }

# --- 1. file inventory ----------------------------------------------------------
sect "file inventory"
EXPECTED=(
  SKILL.md
  references/IMPACT-RUBRIC.md references/PLAYBOOK.md references/ORCHESTRATION.md
  scripts/select-findings.sh scripts/verify-rerun.sh scripts/self-test.sh
)
for f in "${EXPECTED[@]}"; do
  if [ -f "$SKILL_DIR/$f" ]; then ok "$f"; else bad "missing $f"; fi
done

# --- 2. script hygiene: shebang + set -euo pipefail + exec bit + no rm ----------
sect "script hygiene"
for s in "$SKILL_DIR"/scripts/*.sh; do
  base="$(basename "$s")"
  head -1 "$s" | grep -q '^#!/usr/bin/env bash' && ok "$base shebang" || bad "$base missing shebang"
  grep -q 'set -' "$s" && ok "$base set-flags" || bad "$base missing set flags"
  [ -x "$s" ] && ok "$base exec bit" || bad "$base not executable"
done
# blanket no-rm over every shipped script: match rm used as a COMMAND (at a command position,
# followed by whitespace + an argument-start char), scanning CODE only — full-comment lines are
# stripped first so prose mentioning "rm" never trips the guard.
RM_CMD='(^|[[:space:];&|(])rm[[:space:]]+[-/."$~*]'
rm_violation=0
for s in "$SKILL_DIR"/scripts/*.sh; do
  if grep -vE '^[[:space:]]*#' "$s" | grep -nE "$RM_CMD" >/dev/null 2>&1; then
    rm_violation=1
    echo "  ✗ $(basename "$s") invokes 'rm':" >&2
    grep -vE '^[[:space:]]*#' "$s" | grep -nE "$RM_CMD" >&2
  fi
done
[ "$rm_violation" -eq 0 ] && ok "no 'rm' command in any shipped script" || bad "a shipped script invokes 'rm' — use trash or leave mktemp dirs"

# --- 3. cross-links resolve -----------------------------------------------------
sect "cross-links"
for ref in references/IMPACT-RUBRIC.md references/PLAYBOOK.md references/ORCHESTRATION.md \
           scripts/select-findings.sh scripts/verify-rerun.sh scripts/self-test.sh; do
  grep -q "$(basename "$ref")" "$SKILL_DIR/SKILL.md" && ok "SKILL.md references $(basename "$ref")" \
    || bad "SKILL.md does not reference $(basename "$ref")"
done

# --- 4. description is kill-intent-exclusive (static trigger proxy) -------------
sect "description / trigger disambiguation"
desc="$(awk '/^description:/{p=1} p{print} /^allowed-tools:/{exit}' "$SKILL_DIR/SKILL.md")"
echo "$desc" | grep -qiE 'KILL|triage|highest-impact' && ok "leads with kill/triage intent" \
  || bad "description lacks kill/triage intent words"
echo "$desc" | grep -qi 'use cargo-mutants instead' && ok "cedes run/find intent to cargo-mutants" \
  || bad "description does not defer run/find intent to cargo-mutants"
grep -q 'allowed-tools:.*Task' "$SKILL_DIR/SKILL.md" && ok "allowed-tools includes Task" \
  || bad "allowed-tools missing Task (dispatch tool)"

# --- 5. PLAYBOOK content-drift guard (token presence, not line-range diff) ------
sect "PLAYBOOK content-drift"
SHAPES=(label-enum threshold-le threshold-flip predicate-bool formula-op validate-stub comparator-key conversion-stub)
n_present=0
for t in "${SHAPES[@]}"; do
  grep -q "$t" "$SKILL_DIR/references/PLAYBOOK.md" && n_present=$((n_present+1)) || bad "PLAYBOOK missing shape token: $t"
done
[ "$n_present" -eq 8 ] && ok "all 8 playbook_shape tokens present" || bad "only $n_present/8 shape tokens present"
# the cargo-mutants seed table should still be referenced (uncontradicted), if installed
if [ -f "$CM_SKILL" ]; then
  grep -q 'cargo-mutants' "$SKILL_DIR/references/PLAYBOOK.md" && ok "PLAYBOOK cites cargo-mutants seed" \
    || bad "PLAYBOOK no longer cites its cargo-mutants seed"
fi

# --- 6. cargo-mutants jq fix applied -------------------------------------------
sect "cargo-mutants jq fix"
if [ -f "$CM_SKILL" ]; then
  if grep -q 'select(.summary == "MissedMutant")' "$CM_SKILL"; then ok "cargo-mutants uses MissedMutant"; else bad "cargo-mutants jq not patched to MissedMutant"; fi
  if grep -q 'select(.summary == "Missed")' "$CM_SKILL"; then bad "cargo-mutants still has stale \"Missed\" filter"; else ok "no stale \"Missed\" filter"; fi
else
  echo "  - cargo-mutants skill not installed; skipping jq-fix check"
fi

# --- 7. output schema-drift guard fires on tampered data -----------------------
sect "output schema-drift guard"
TAMPER="$(mktemp)"   # bare mktemp: portable (BSD mktemp only substitutes trailing X's)
cat > "$TAMPER" <<'JSON'
{ "missed": 2, "total_mutants": 2,
  "outcomes": [ { "summary": "MissedMutant", "scenario": { "Mutant": {
      "name":"src/x.rs:1:1: replace + with * in f","file":"src/x.rs",
      "function":{"function_name":"f","return_type":"-> i64"},
      "span":{"start":{"line":1}},"replacement":"*","genre":"BinaryOperator" } } } ] }
JSON
# missed=2 but only 1 MissedMutant row -> drift guard must exit 1
if "$SKILL_DIR/scripts/select-findings.sh" "$TAMPER" - >/dev/null 2>&1; then
  bad "select-findings.sh did NOT fire on schema drift (n=1 != missed=2)"
else
  ok "select-findings.sh exits non-zero on schema drift"
fi

# --- 8. deterministic end-to-end smoke (cargo mutants real run) ----------------
if [ "$QUICK" -eq 1 ]; then
  sect "crate smoke (skipped: --quick)"; echo "  - skipped"
else
  sect "crate smoke (cargo mutants -> select-findings -> verify-rerun)"
  if ! command -v cargo >/dev/null 2>&1 || ! cargo mutants --version >/dev/null 2>&1; then
    echo "  - cargo-mutants not available; skipping crate smoke"
  else
    WORK="$(mktemp -d /tmp/mko-selftest.XXXXXX)"
    ( cd "$WORK" && cargo new --lib demo >/dev/null 2>&1 )
    CRATE="$WORK/demo"
    # bash has no noclobber by default, so plain > is fine here.
    cat > "$CRATE/src/lib.rs" <<'RUST'
pub fn residual(principal: i64, paid: i64) -> i64 {
    principal - paid
}
pub enum Color { Red, Blue }
impl Color {
    pub fn as_str(&self) -> &'static str {
        match self { Color::Red => "red", Color::Blue => "blue" }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn t_res()  { let _ = residual(5, 3); }       // weak: residual mutants survive
    #[test] fn t_color(){ let _ = Color::Red.as_str(); }  // weak: as_str stub survives
}
RUST
    ( cd "$CRATE" && cargo mutants --file src/lib.rs --timeout 60 --jobs 4 >/tmp/mko-selftest-mut.log 2>&1 ) || true
    OUT="$CRATE/mutants.out/outcomes.json"
    if [ ! -f "$OUT" ]; then
      bad "crate smoke: no outcomes.json produced (see /tmp/mko-selftest-mut.log)"
    else
      GROUPED="$CRATE/mutants.out/mko-grouped.json"
      if "$SKILL_DIR/scripts/select-findings.sh" "$OUT" "$GROUPED" 2>/dev/null; then ok "select-findings.sh ran on real outcomes"; else bad "select-findings.sh failed on real outcomes"; fi
      # arithmetic (residual) must out-rank the label as_str finding -> first finding is residual, sev 5
      first_fn=$(jq -r '.findings[0].function_name' "$GROUPED")
      first_sev=$(jq -r '.findings[0].max_silent_severity' "$GROUPED")
      [ "$first_fn" = "residual" ] && ok "residual (arithmetic) ranks first" || bad "expected residual first, got '$first_fn'"
      [ "$first_sev" = "5" ] && ok "top finding silent_severity=5" || bad "top finding sev=$first_sev (expected 5)"
      # the as_str finding must be tagged label-noise
      label_noise=$(jq -r '[.findings[]|select((.function_name|test("as_str")) and .noise and .noise_reason=="label-noise")]|length' "$GROUPED")
      [ "$label_noise" = "1" ] && ok "as_str finding pre-tagged label-noise" || bad "as_str not tagged label-noise (got $label_noise)"
      # verify-rerun: add a killing test for residual, claim it, expect caught
      cat >> "$CRATE/src/lib.rs" <<'RUST'

#[cfg(test)]
mod kill { use super::*; #[test] fn kill_mutant_residual() { assert_eq!(residual(10,3), 7); } }
RUST
      CLAIMS="$(mktemp)"
      jq -nc '{scope:"src/lib.rs", per_finding:[{finding_id:"F1", claimed_killed:[
        "src/lib.rs:2:15: replace - with + in residual",
        "src/lib.rs:2:15: replace - with / in residual"]}]}' > "$CLAIMS"
      if ( cd "$CRATE" && "$SKILL_DIR/scripts/verify-rerun.sh" "$CLAIMS" -o "$CRATE/verify.json" -d "$CRATE/mv.out" -- --file src/lib.rs >/tmp/mko-selftest-verify.log 2>&1 ); then
        caught=$(jq -r '.per_finding[0].status' "$CRATE/verify.json" 2>/dev/null)
        [ "$caught" = "caught" ] && ok "verify-rerun reports residual CAUGHT" || bad "verify-rerun status=$caught (expected caught)"
      else
        bad "verify-rerun.sh exited non-zero on a finding that should be caught (see /tmp/mko-selftest-verify.log)"
      fi
    fi
    echo "  (left throwaway crate at $WORK — not deleted; remove with: trash $WORK)"
  fi
fi

# --- 9. multi-engine workflow layer (private-branch accelerator) ----------------
sect "workflow engine (optional multi-engine layer)"
WF="$SKILL_DIR/workflow/pipeline.js"
if [ -f "$WF" ]; then
  ok "workflow/pipeline.js present"
  for d in references/ENGINES.md references/WORKFLOW.md; do
    [ -f "$SKILL_DIR/$d" ] && ok "$d present" || bad "missing $d"
    grep -q "$(basename "$d")" "$SKILL_DIR/SKILL.md" && ok "SKILL.md references $(basename "$d")" || bad "SKILL.md does not reference $(basename "$d")"
  done
  grep -q 'pipeline.js' "$SKILL_DIR/SKILL.md" && ok "SKILL.md references pipeline.js" || bad "SKILL.md does not reference pipeline.js"
  # openrouter/fusion must be the EXPANDED command (pior is an interactive-only alias). Assert the
  # markers of the full expansion are present (provider + model + api-key), which the bare alias lacks.
  if grep -q 'provider openrouter' "$WF" && grep -q 'model fusion' "$WF" && grep -q -- '--api-key' "$WF"; then
    ok "pipeline.js uses the expanded openrouter/fusion command (provider+model+api-key)"
  else bad "pipeline.js missing the expanded openrouter/fusion command"; fi
  # JS validity: the runtime wraps the body in an async fn, so validate it that way.
  # node infers module format from the extension, so the temp file MUST end in .js.
  if command -v node >/dev/null 2>&1; then
    CHKD="$(mktemp -d)"; CHK="$CHKD/check.js"
    { echo 'async function __wf(args,agent,parallel,pipeline,phase,log,budget,workflow){'; sed 's/^export const meta/const meta/' "$WF"; echo '}'; } > "$CHK"
    if node --check "$CHK" 2>/tmp/mko-wf-check.log; then ok "pipeline.js is syntactically valid (as the runtime wraps it)"; else bad "pipeline.js has a syntax error (see /tmp/mko-wf-check.log)"; fi
  else echo "  - node not installed; skipping pipeline.js syntax check"; fi
else
  echo "  - no workflow/ layer installed (Claude-only core); skipping multi-engine checks"
fi

# --- agent-loop caveat ----------------------------------------------------------
sect "not covered here"
echo "  - The opus-triage / sonnet-fix dispatch loop needs the Task tool and is validated by a"
echo "    real skill invocation, not this shell script. Run the skill on a seeded crate to cover it."
echo "  - The cross-vendor audit panel (Codex via pi, openrouter/fusion via pior) needs those CLIs"
echo "    and live API calls — exercised by a real workflow run, not this script."

# --- tally ----------------------------------------------------------------------
echo; echo "==============================="
echo "self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
