# Plan 001: Make the killing-test function name a single canonical, file+line-keyed format across every dispatch path

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e231628..HEAD -- references/ORCHESTRATION.md references/PLAYBOOK.md workflow/pipeline.js scripts/self-test.sh`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e231628`, 2026-06-14

## Why this matters

This skill advertises **resumability** as a headline feature (README "Resumable";
`SKILL.md` design choices). The resume mechanism that prevents duplicate test
generation is an **exact-function-name grep** (`ORCHESTRATION.md:213`:
"dedup `kill_mutant_*` by exact fn-name grep"). But the killing-test function
name is specified *three different ways* across the repo, and one component of
the documented format (`<op>`) is never defined at all:

- `references/ORCHESTRATION.md` and `references/PLAYBOOK.md` say `kill_mutant_<file>_<line>_<op>`.
- `workflow/pipeline.js:157` tells its fixer to write `kill_mutant_<function_name>_<line>` — **no file, no op**.
- The schema example at `ORCHESTRATION.md:150` shows `kill_mutant_src_lib_rs_2_sub`.

Consequence: a run done through the optional Workflow path produces names the
documented resume-dedup grep cannot match, so a later direct-dispatch resume can
**re-generate a test that already exists**. And because `<op>` is undefined while
one test is meant to kill an entire *cluster* of operator swaps on a line (the
merge key is `(file, function_name, line)` — `IMPACT-RUBRIC.md:126`), `<op>` is
not just undefined but actively ambiguous (which of the cluster's ops?).

This plan picks **one** canonical format and propagates it everywhere.

## The decision (canonical format)

```
kill_mutant_<file_sanitized>_<line>
```

where `<file_sanitized>` is the mutant's source file path with every character
that is not `[A-Za-z0-9]` replaced by `_`. Example: a finding at `src/lib.rs`
line `2` → `kill_mutant_src_lib_rs_2`.

Rationale, so you can defend edits that touch surrounding prose:
- `(file, line)` is the unique key of a cargo-mutants mutant location and uniquely
  identifies a finding's cluster — `<op>` is dropped because one test kills the
  whole cluster, so there is no single op to name.
- File+line (not function+line) because file is part of the canonical merge key
  and avoids collisions when two files share a function name.

## Current state

Files and the exact lines to change:

- `references/ORCHESTRATION.md`
  - `:81` — FIXER prompt prose: "The test fn is named `kill_mutant_<file>_<line>_<op>`; it MUST run green…"
  - `:92` — verbatim prompt skeleton: "Write ONE test fn `kill_mutant_<file>_<line>_<op>` into {TEST_FILE}…"
  - `:150` — fixer-report JSON example: `"test_fn": "kill_mutant_src_lib_rs_2_sub",`
  - `:213` — resume dedup mechanics: "grep the target test file for the exact `fn kill_mutant_<file>_<line>_<op>` — skip if present."
- `references/PLAYBOOK.md`
  - `:42-43` — "Test fns are named `kill_mutant_<file>_<line>_<op>` for dedup on resume."
- `workflow/pipeline.js`
  - `:152-163` — the fixer `agent(...)` call. Line 157 currently:
    ```js
    float-tolerance discipline. Write ONE test fn into a DISTINCT lane file tests/kill_${f.id}.rs named
    kill_mutant_${f.function_name}_${f.line} that kills EVERY mutant in claimed_cluster_names:
    ```
  - Note `pipeline.js:72` already has a helper `const slug = s => s.replace(/[^A-Za-z0-9]/g, '')` — but it **strips** rather than replacing with `_`, so do NOT reuse it for the file token; compute the underscore-sanitized name explicitly (see Step 3).
- `scripts/self-test.sh`
  - `:167` — fixture test fn in the throwaway demo crate: `fn kill_mutant_residual()`. This is a demo name, not load-bearing, but should match the convention as an exemplar (the file at `src/lib.rs` line 2 → `kill_mutant_src_lib_rs_2`).

Note: `scripts/verify-rerun.sh:57` greps `fn kill_mutant_[A-Za-z0-9_]+` (a generic
prefix match) — this **already works** with the canonical name and must NOT be
changed.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Self-test (fast) | `bash scripts/self-test.sh --quick` | last line `self-test: N passed, 0 failed` |
| JS still valid | `node --check <(printf 'async function __wf(args,agent,parallel,pipeline,phase,log,budget,workflow){\n'; sed 's/^export const meta/const meta/' workflow/pipeline.js; printf '\n}\n')` | exit 0, no output |
| Grep for stale format | `grep -rn 'kill_mutant_<file>_<line>_<op>\|<op>' references/ workflow/` | no matches |

Run all commands from the repo root (`~/Projects/mutation-killing-orchestrator`).

## Scope

**In scope** (the only files you should modify):
- `references/ORCHESTRATION.md`
- `references/PLAYBOOK.md`
- `workflow/pipeline.js`
- `scripts/self-test.sh`

**Out of scope** (do NOT touch):
- `scripts/verify-rerun.sh` — its generic `kill_mutant_[A-Za-z0-9_]+` grep already
  matches the canonical name; changing it risks breaking the dedup warning.
- Any rubric / scoring / schema logic. This plan is *only* the test-fn naming string.
- `README.md` — naming is internal; do not document it there.

## Git workflow

- Branch: `advisor/001-canonical-killing-test-name`
- One commit is fine; message style is conventional commits (repo log uses plain
  imperative subjects, e.g. "Make engine routing opportunistic…"). Suggested:
  `fix: unify killing-test fn name to kill_mutant_<file>_<line> across all paths`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Fix the two reference docs

In `references/ORCHESTRATION.md`, replace every `kill_mutant_<file>_<line>_<op>`
with `kill_mutant_<file_sanitized>_<line>` at lines `:81` and `:92`, and at
`:213` change `fn kill_mutant_<file>_<line>_<op>` to
`fn kill_mutant_<file_sanitized>_<line>`. Add, once (in the `:81` paragraph), a
one-sentence definition: "`<file_sanitized>` = the source file path with every
non-alphanumeric character replaced by `_` (e.g. `src/lib.rs` → `src_lib_rs`);
`<op>` is intentionally dropped because one test kills the whole `(file,line)`
cluster."

At `ORCHESTRATION.md:150`, change the example to match: `src/lib.rs` line 2 →
`"test_fn": "kill_mutant_src_lib_rs_2",`.

In `references/PLAYBOOK.md:42-43`, change `kill_mutant_<file>_<line>_<op>` to
`kill_mutant_<file_sanitized>_<line>`.

**Verify**: `grep -rn '<op>\|<line>_<op>' references/` → no matches.

### Step 2: Update the fixer prompt in pipeline.js to compute and pass the canonical name

In `workflow/pipeline.js`, inside the `triage.top_findings.map((f, i) => ...)`
fixer dispatch (lines ~152-163), compute the canonical name in JS so the model
is handed the exact string instead of a template it has to assemble. Replace the
naming line so the prompt names the function explicitly. Target shape:

```js
const reports = (await parallel(triage.top_findings.map((f, i) => () => {
  const tfn = 'kill_mutant_' + f.file.replace(/[^A-Za-z0-9]/g, '_') + '_' + f.line
  return agent(`${IN}. You are a mutation-killing fixer for finding ${f.id} (lane m_${i + 1}).
Finding: ${JSON.stringify(f)}
Read the recipe for playbook_shape="${f.playbook_shape}" in ${SKILL}/references/PLAYBOOK.md and the
float-tolerance discipline. Write ONE test fn into a DISTINCT lane file tests/kill_${f.id}.rs named
exactly ${tfn} that kills EVERY mutant in claimed_cluster_names:
  ${JSON.stringify(f.claimed_cluster_names)}
Pin exact expected values; if numeric, use a tolerance tighter than half the real-vs-mutated gap
(never a loose range). Run \`cargo nextest run\` and confirm GREEN on the real code before returning.
claimed_killed must be exactly the cluster names your test kills.`,
    { model: FIXER, label: `fix:${f.id}`, phase: 'Fix', schema: FIXER_SCHEMA })
}))).filter(Boolean)
```

The only behavioral change is: the arrow body becomes a block (`{ ... return ... }`)
so it can declare `tfn`, and the prompt now says "named exactly `${tfn}`" using
`<file>_<line>` instead of `<function_name>_<line>`. Do not change any option
object, schema, or the `.filter(Boolean)`.

**Verify**: run the "JS still valid" command from the table → exit 0. Then
`grep -n 'function_name}_\${f.line}\|kill_mutant_\${f.function_name}' workflow/pipeline.js`
→ no matches.

### Step 3: Align the self-test demo fixture name

In `scripts/self-test.sh:164-167`, the appended kill test currently declares
`fn kill_mutant_residual()`. The demo source is written to `src/lib.rs` and
`residual` is at line 2, so rename it to `kill_mutant_src_lib_rs_2` to model the
convention:

```bash
mod kill { use super::*; #[test] fn kill_mutant_src_lib_rs_2() { assert_eq!(residual(10,3), 7); } }
```

This is a demo crate compiled only during the full self-test smoke; the rename is
cosmetic-but-exemplary and does not affect any assertion (the smoke matches on
mutant `.name` strings, not the test fn name).

**Verify**: `grep -n 'kill_mutant_src_lib_rs_2' scripts/self-test.sh` → 1 match;
`grep -n 'kill_mutant_residual' scripts/self-test.sh` → no matches.

### Step 4: Run the self-test

**Verify**: `bash scripts/self-test.sh --quick` → final line `self-test: N passed, 0 failed`
(N ≥ 39). No `✗` lines.

## Test plan

No new test is required — this is a string-convention unification. The existing
`self-test.sh` checks (cross-links, JS syntax, drift guards) plus the two new
greps in the Done criteria are the regression net. If you want belt-and-braces,
add a single assertion to `self-test.sh` Section 9 (the workflow block) that the
canonical pattern is present and the old one is gone:

```bash
grep -q 'kill_mutant_.*file.*replace' workflow/pipeline.js \
  && ! grep -q 'kill_mutant_\${f.function_name}' workflow/pipeline.js \
  && ok "pipeline.js uses file+line killing-test name" \
  || bad "pipeline.js still uses function_name-based killing-test name"
```
(Optional — only if it slots cleanly into the existing `if [ -f "$WF" ]` block.)

## Done criteria

ALL must hold:

- [ ] `grep -rn '<op>' references/ workflow/` returns no matches
- [ ] `grep -rn 'kill_mutant_<file>_<line>' references/` returns no matches (old templated form gone)
- [ ] `grep -n 'kill_mutant_\${f.function_name}' workflow/pipeline.js` returns no matches
- [ ] The "JS still valid" command exits 0
- [ ] `bash scripts/self-test.sh --quick` ends `self-test: N passed, 0 failed`
- [ ] `git status` shows only the four in-scope files modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any in-scope file's content around the cited lines does not match the "Current
  state" excerpts (the repo drifted since `e231628`).
- `pipeline.js` no longer has the `triage.top_findings.map((f, i) => () => ...)`
  fixer block, or its fixer prompt has been restructured — the safe edit point is gone.
- The self-test fails after the change and the failure is not obviously your edit.
- You find a *fourth* place that emits a killing-test name not listed in "Current
  state" — report it rather than guessing whether to change it.

## Maintenance notes

- If a future change makes one finding span multiple test functions (today it is
  strictly one test per finding/lane), the `(file,line)` name will collide and
  `<op>` or an index suffix will need reintroducing — revisit then.
- A reviewer should confirm `scripts/verify-rerun.sh`'s dedup grep was left
  untouched and still matches the canonical name (`fn kill_mutant_[A-Za-z0-9_]+`).
- This plan is the cheap fix for the root cause; the deeper "two dispatch paths
  duplicate their contracts" debt is tracked separately (finding #5, not planned).
