# Plan 002: Cover all 8 op-class branches of the deterministic parser in self-test.sh

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e231628..HEAD -- scripts/self-test.sh scripts/select-findings.sh`
> If either file changed since this plan was written, compare the "Current state"
> excerpts against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `e231628`, 2026-06-14

## Why this matters

`scripts/select-findings.sh` is the deterministic core of the whole skill: it
classifies every survivor into an `op_class` and assigns its `silent_severity`,
which drives 35% of the impact score. The classifier (`select-findings.sh:55-68`)
has **eight** branches — `arithmetic`, `comparison`, `boolean`, `binop-other`,
`unary`, `fnvalue`, `label`, `other` — and several use fiddly regexes (notably the
boolean branch's `^(&&|\\|\\|)$` with its doubled backslash-escaped pipes).

The current `self-test.sh` end-to-end smoke (`:148-162`) only ever exercises **two**
of those branches: `arithmetic` (the `residual` fn) and `label` (the `as_str` fn).
A regression in the comparison/boolean/binop/unary/fnvalue classification — say a
botched escape during an edit — would ship green. This plan adds a fast,
model-free, fixture-driven check that pins all eight classifications.

## Current state

`scripts/select-findings.sh:55-68` — the classifier (read it to confirm the
expected mapping below is current):

```
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
```

Expected `(op_class, silent_severity)` per input, which your fixture will assert:

| genre | original op (from `.name`) | op_class | sev |
|---|---|---|---|
| BinaryOperator | `+` | arithmetic | 5 |
| BinaryOperator | `<` | comparison | 3 |
| BinaryOperator | `&&` | boolean | 3 |
| BinaryOperator | `&` (bitwise) | binop-other | 3 |
| UnaryOperator | `!` | unary | 3 |
| FnValue | (stub, name has no label token) | fnvalue | 3 |
| FnValue | (name contains `as_str`) | label | 1 |

`scripts/self-test.sh` structure (so you insert in the right place):
- `:102-117` — Section 7 "output schema-drift guard" (uses a `mktemp` fixture and
  asserts `select-findings.sh` exits non-zero on a tampered `.missed` count). This
  is the closest existing pattern to follow.
- `:119-182` — Section 8 "crate smoke" (the slow `cargo mutants` run; gated by `--quick`).
- The helper functions are defined at `:24-26`: `ok "msg"`, `bad "msg"`, `sect "title"`.
- Note `select-findings.sh`'s schema-drift guard (`select-findings.sh:32-50`)
  requires top-level `.missed` to **equal** the count of `MissedMutant` rows, so the
  fixture's `"missed"` must match the number of outcome rows or the script exits 1.
- The grouping merge key is `(file, function_name, line)` (`select-findings.sh:93`),
  so give every fixture row a **distinct** `function_name`+`line` to get one finding
  per row, which makes per-function assertions unambiguous.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Self-test (fast) | `bash scripts/self-test.sh --quick` | last line `self-test: N passed, 0 failed` |
| jq present | `command -v jq` | a path |

Run from the repo root. (`--quick` skips the slow cargo smoke; the new section
must run in `--quick` too, since it needs no cargo.)

## Scope

**In scope** (the only file you should modify):
- `scripts/self-test.sh`

**Out of scope** (do NOT touch):
- `scripts/select-findings.sh` — this plan *tests* the classifier, it does not
  change it. If a branch is genuinely wrong, that is a separate finding — STOP and report.
- `references/IMPACT-RUBRIC.md` — the expected mapping is documented there
  (`:35-44`) and is the source of truth for the table above; do not edit it.

## Git workflow

- Branch: `advisor/002-opclass-parser-coverage`
- One commit; suggested message: `test: cover all 8 op-class branches in self-test`
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Add an op-class coverage section to self-test.sh

Insert a new section **after** Section 7 (the schema-drift guard, ends at
`self-test.sh:117`) and **before** Section 8 (`# --- 8. deterministic end-to-end smoke`).
It must run unconditionally (not gated by `--quick`) because it uses only `jq`
and `select-findings.sh`, no cargo. Paste exactly:

```bash
# --- 7b. op-class parser coverage (all 8 branches, model-free) -------------------
sect "op-class parser coverage"
OCFIX="$(mktemp)"
cat > "$OCFIX" <<'JSON'
{ "missed": 7, "total_mutants": 7, "outcomes": [
  {"summary":"MissedMutant","scenario":{"Mutant":{"name":"src/a.rs:1:1: replace + with * in f_arith","file":"src/a.rs","function":{"function_name":"f_arith","return_type":"-> i64"},"span":{"start":{"line":1}},"replacement":"*","genre":"BinaryOperator"}}},
  {"summary":"MissedMutant","scenario":{"Mutant":{"name":"src/a.rs:2:1: replace < with <= in f_cmp","file":"src/a.rs","function":{"function_name":"f_cmp","return_type":"-> bool"},"span":{"start":{"line":2}},"replacement":"<=","genre":"BinaryOperator"}}},
  {"summary":"MissedMutant","scenario":{"Mutant":{"name":"src/a.rs:3:1: replace && with || in f_bool","file":"src/a.rs","function":{"function_name":"f_bool","return_type":"-> bool"},"span":{"start":{"line":3}},"replacement":"||","genre":"BinaryOperator"}}},
  {"summary":"MissedMutant","scenario":{"Mutant":{"name":"src/a.rs:4:1: replace & with | in f_bit","file":"src/a.rs","function":{"function_name":"f_bit","return_type":"-> u8"},"span":{"start":{"line":4}},"replacement":"|","genre":"BinaryOperator"}}},
  {"summary":"MissedMutant","scenario":{"Mutant":{"name":"src/a.rs:5:1: replace ! with  in f_neg","file":"src/a.rs","function":{"function_name":"f_neg","return_type":"-> bool"},"span":{"start":{"line":5}},"replacement":"","genre":"UnaryOperator"}}},
  {"summary":"MissedMutant","scenario":{"Mutant":{"name":"src/a.rs:6:1: replace f_stub -> i64 with 0","file":"src/a.rs","function":{"function_name":"f_stub","return_type":"-> i64"},"span":{"start":{"line":6}},"replacement":"0","genre":"FnValue"}}},
  {"summary":"MissedMutant","scenario":{"Mutant":{"name":"src/a.rs:7:1: replace Color::as_str -> &'static str with \"\"","file":"src/a.rs","function":{"function_name":"as_str","return_type":"-> &'static str"},"span":{"start":{"line":7}},"replacement":"\"\"","genre":"FnValue"}}}
]}
JSON
OCGROUPED="$(mktemp)"
if "$SKILL_DIR/scripts/select-findings.sh" "$OCFIX" "$OCGROUPED" 2>/dev/null; then
  ok "select-findings.sh ran on the op-class fixture"
  # expected: function_name -> "op_class:severity"
  for spec in \
    "f_arith:arithmetic:5" "f_cmp:comparison:3" "f_bool:boolean:3" \
    "f_bit:binop-other:3" "f_neg:unary:3" "f_stub:fnvalue:3" "as_str:label:1"; do
    fn="${spec%%:*}"; rest="${spec#*:}"; want_oc="${rest%%:*}"; want_sev="${rest##*:}"
    got_oc="$(jq -r --arg fn "$fn" '.findings[]|select(.function_name==$fn)|.op_classes[0]' "$OCGROUPED")"
    got_sev="$(jq -r --arg fn "$fn" '.findings[]|select(.function_name==$fn)|.max_silent_severity' "$OCGROUPED")"
    if [ "$got_oc" = "$want_oc" ] && [ "$got_sev" = "$want_sev" ]; then
      ok "$fn -> $got_oc (sev $got_sev)"
    else
      bad "$fn -> got $got_oc/$got_sev, expected $want_oc/$want_sev"
    fi
  done
else
  bad "select-findings.sh failed on the op-class fixture (see stderr)"
fi
```

Notes for you (do not paste these):
- The fixture sets `"missed": 7` to match its 7 `MissedMutant` rows so the
  drift guard in `select-findings.sh` passes.
- Each row has a distinct `function_name`+`line`, so each becomes its own finding
  and `.op_classes[0]` / `.max_silent_severity` are single-valued and unambiguous.
- `$SKILL_DIR` is already defined at `self-test.sh:20`; `ok`/`bad`/`sect` at `:24-26`.
- Leave the `mktemp` files; the script never uses `rm` (a hygiene rule the
  self-test itself enforces at `:50-59`).

### Step 2: Run the self-test and confirm all 7 specs pass

**Verify**: `bash scripts/self-test.sh --quick` →
- a new section header `== op-class parser coverage ==` appears
- 8 new `✓` lines under it (the ran-ok line + 7 spec lines)
- final line `self-test: N passed, 0 failed` with no `✗`

### Step 3: Confirm the check actually fails on a regression (sanity, then revert)

Temporarily break one classifier branch to prove the new check has teeth, then
revert. In `scripts/select-findings.sh:63`, change `{op_class:"comparison", sev:3}`
to `{op_class:"WRONG", sev:3}`, run `bash scripts/self-test.sh --quick`, and
confirm you now see `✗ f_cmp -> got WRONG/3, expected comparison/3` and a non-zero
exit. Then **restore the line exactly** (`git checkout scripts/select-findings.sh`).

**Verify**: after restore, `git status` shows `select-findings.sh` unmodified, and
`bash scripts/self-test.sh --quick` is green again.

## Test plan

This plan *is* a test addition. Cases covered: all 8 op-class branches
(arithmetic, comparison, boolean, binop-other, unary, fnvalue, label) — the
`other` branch is the conservative default and is implicitly the fallback; if you
want it too, add one row with `genre:"Unknown"` and an unparseable name expecting
`other:1`, but it is optional. Structural pattern followed: Section 7's
`mktemp` + `select-findings.sh` + assert approach (`self-test.sh:102-117`).

## Done criteria

ALL must hold:

- [ ] `bash scripts/self-test.sh --quick` prints `== op-class parser coverage ==`
      with 8 `✓` lines and ends `self-test: N passed, 0 failed`
- [ ] Step 3 demonstrated a `✗` on a deliberate regression, then a clean revert
      (`git status` shows only `scripts/self-test.sh` changed at the end)
- [ ] No edit remains in `scripts/select-findings.sh`
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The classifier at `select-findings.sh:55-68` does not match the "Current state"
  excerpt (it was changed since `e231628`) — the expected mapping may be stale.
- Any spec fails on the **unmodified** classifier (Step 2). That means either the
  fixture is wrong or the classifier has a real bug — do not "fix" it by editing
  `select-findings.sh`; report which spec failed and the actual `op_class`/`sev`.
- The new section cannot be placed before Section 8 because the file structure
  differs from the cited line numbers.

## Maintenance notes

- If a new `op_class` branch is added to `select-findings.sh`, add a matching
  fixture row + spec line here so coverage stays complete.
- The boolean branch regex `^(&&|\\|\\|)$` is the most fragile (escaped pipes);
  the `f_bool` spec is specifically its guard — reviewers touching that line
  should re-run the self-test.
- This is pure test hardening; it does not change skill behavior.
