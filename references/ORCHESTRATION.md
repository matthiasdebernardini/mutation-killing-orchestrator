# Orchestration — dispatch, prompts, schemas, state machine

The operational contract behind the 4-phase spine in `SKILL.md`. Read this at dispatch time.

## Dispatch contract

The host **`Task`** tool (the Agent dispatch tool) accepts a per-agent **`model:`** override.

- **Phase 2 (triage):** ONE `Task` call, `model: opus`, effort `high` (use `xhigh` only when
  the raw `MissedMutant` count > 100). Prompt below.
- **Phase 3 (fix):** up to N `Task` calls (N = `top_findings` length, default cap 3), issued in
  a **single message** so they run in parallel. Each `model: sonnet`, one fixer per finding.
  Exception: two fixers that must write to the same shared in-module test block run sequentially.

> Tool-name note: if this install names the dispatch tool something other than `Task`, substitute
> the real name in `SKILL.md` frontmatter and the dispatch lines. The `model:` override is an
> asserted runtime precondition (Phase 0 documents it; it is not probed at runtime).

## Division of labor — script vs Opus agent

| Owner | Responsibilities |
|---|---|
| `scripts/select-findings.sh` (deterministic, runs at the Phase 0/2 boundary) | Filter `MissedMutant` from `outcomes.json`; group by the merge key; compute `kills_per_test`; parse `.name` → `op_class` + `silent_severity`; pre-tag path/label noise. Writes grouped JSON to `mutants.out/mko-grouped.json`. |
| The single Opus triage agent (consumes that file, **no re-jq**) | criticality keyword judgment; blast-radius lookup (codegraph/rg); killability-gate equivalence arguments; the 1/3/5 scoring + weighted impact; ranking; top-N selection; writing `findings.json`. |

## TRIAGE prompt contract (`model: opus`)

**Inputs to bake into the prompt:**
- Absolute path to `mutants.out/mko-grouped.json` (script output: findings with `op_class`,
  `max_silent_severity`, `kills_per_test`, `noise`/`noise_reason` already set).
- The rubric (`references/IMPACT-RUBRIC.md`): weights, 1/3/5 scales, domain keyword lists,
  blast-radius procedure, tie-break ladder, accepted taxonomy.
- The `playbook_shape` enum (`references/PLAYBOOK.md`).
- `blast_radius_mode` to use (`codegraph` if `.codegraph/` exists, else `ripgrep`).
- The selection cap (`--top N`, default 3).

**Allowed tools:** `codegraph_*` (callers/node/impact), `rg`/`Bash` (fallback + reading),
`Read` (inspect source for criticality + killability arguments). **No Edit/Write to source.**

**Output:** write `findings.json` (schema below) conforming exactly — `top_findings` length
`1..N`, every `accepted[]` with a written `argument`, all remaining killable survivors in
`deferred[]`. Restate inline the two non-negotiable rules: drop noise; gate equivalents to
`accepted` rather than spending a test.

**Verbatim prompt skeleton:**
```
You are the mutation-triage judge. Read the pre-grouped survivors at
{GROUPED_PATH} (already filtered to MissedMutant, grouped by (file,function_name,line),
with op_class, max_silent_severity, and kills_per_test computed). DO NOT re-run jq.

For each finding:
  1. silent_severity = max_silent_severity (already computed). Do not recompute.
  2. criticality (1/3/5): keyword-match function_name + file path + return_type against the
     domain lists in {RUBRIC_PATH}. You MAY Read the source for context.
  3. blast_radius (1/3/5): use {MODE}. codegraph_callers on function_name (or rg fallback);
     record the raw count. Public API or >=10 callers = 5; 3-9 = 3; 1-2 = 1.
  4. cluster_size (1/3/5): from kills_per_test. >=8 = 5; 4-7 = 3; 1-3 = 1.
  5. killability_gate: if no input both reaches the line AND observes a different result,
     set gate x0 and move the finding to accepted[] with reason (one of the 5 taxonomy
     tokens) and a written argument. Otherwise gate x1.
  6. impact = gate * (0.35*silent + 0.30*crit + 0.20*blast + 0.15*cluster).
  7. pick playbook_shape from the PLAYBOOK mapping.

Drop noise (noise:true findings) — list them in accepted[] with their noise_reason if they
are equivalence-class noise, else omit. Rank gated survivors by impact desc, tie-break per
{RUBRIC_PATH}. Take the top {N}. Everything killable below the cut -> deferred[].

Write findings.json to {FINDINGS_PATH} exactly matching the schema. Assign lanes m_1..m_N
in rank order and ids F1..FN. Emit the four sub-scores under "rubric" so the score is auditable.
```

## FIXER prompt contract (`model: sonnet`, one per finding)

**Inputs:** exactly one `top_findings` entry; the matching `PLAYBOOK.md` recipe for its
`playbook_shape`; the orchestrator-computed float bound (if numeric); the target source file
path; the lane id; the per-lane test-file target (`tests/kill_F<k>.rs`).

**Allowed tools:** `Read`, `Write`, `Edit`, `Bash` (to run `cargo nextest run`).

**Output:** a fixer report (schema below). The test fn is named
`kill_mutant_<file_sanitized>_<line>`; it MUST run green on real (unmutated) code before the fixer
returns. `<file_sanitized>` = the source file path with every non-alphanumeric character replaced by
`_` (e.g. `src/lib.rs` → `src_lib_rs`); `<op>` is intentionally dropped because one test kills the
whole `(file,line)` cluster. For numeric findings the assertion MUST use the supplied float bound.

**Verbatim prompt skeleton:**
```
You are a mutation-killing fixer. Finding:
{FINDING_JSON}
Recipe (playbook_shape={SHAPE}):
{RECIPE_TEXT}
Float bound (if numeric): {FLOAT_BOUND_JSON}   # {input, expected, mutated, suggested_bound}

Write ONE test fn `kill_mutant_<file_sanitized>_<line>` into {TEST_FILE} that kills EVERY mutant in
the finding's cluster_members. Pin exact expected values; if numeric, use suggested_bound (a
tolerance tighter than half the expected-vs-mutated gap) — never a loose range. Run
`cargo nextest run` and confirm green on real code. Then return ONLY the fixer-report JSON:
its claimed_killed must list the exact .name strings of the cluster_members you intend to kill.
```

## The float bound (what "compute the float bound" means)

For each numeric finding the orchestrator emits a concrete bound the fixer pins against:

1. Select a representative input for the mutated function.
2. Compute `expected` (real code) and `mutated` (the `op_class` swap applied) for that input.
   **Method:** prefer a **scratch eval** — write the one-line formula into a throwaway
   `fn main()` (or a `#[test]` with `dbg!`) and run it — for any nonlinear or multi-term
   formula; fall back to static reasoning only for a single trivial operation. (This decision
   is fixed for v1: scratch eval is permitted and preferred for reliability.)
3. Emit `{ input, expected, mutated, suggested_bound }` where
   `suggested_bound = |x - expected| < tol` and `tol < |expected - mutated| / 2`.

The **Phase-4 static float pre-check** runs before the scoped re-run: it confirms the fixer's
assertion tolerance is tighter than the expected-vs-mutated gap. Non-numeric findings set
`float_check = "n/a"`.

## Schemas

### `findings.json` (written by the triage agent)
```json
{
  "blast_radius_mode": "codegraph",
  "top_findings": [
    { "id": "F1", "file": "src/lib.rs", "line": 2, "function_name": "residual",
      "genre": "BinaryOperator", "replacement": "/",
      "mutant_name": "src/lib.rs:2:15: replace - with / in residual",
      "op_class": "arithmetic", "playbook_shape": "formula-op",
      "cluster_members": [ {"name":"src/lib.rs:2:15: replace - with / in residual","file":"src/lib.rs","line":2,"genre":"BinaryOperator","replacement":"/","op_class":"arithmetic"} ],
      "kills_per_test": 5,
      "rubric": { "silent": 5, "criticality": 5, "blast": 3, "cluster": 3 },
      "impact_score": 4.45, "blast_radius_callers": 6,
      "domain": "money", "lane": "m_1", "status": "pending", "justification": "..." }
  ],
  "accepted": [
    { "cluster": "src/lib.rs:scale:6", "reason": "guarded-threshold", "gate_outcome": "x0",
      "argument": "earlier guard guarantees trials>=3, so trials>0 vs trials>=0 is unobservable" }
  ],
  "deferred": [ { "cluster": "src/lib.rs:foo:9", "impact_score": 2.10, "playbook_shape": "threshold-le" } ],
  "promoted": []
}
```
- `top_findings` length `1..N` (default cap N=3; never 0). `status ∈ {pending, caught, missed, accepted}`.
- `op_class ∈ {arithmetic, comparison, boolean, unary, fnvalue, label, binop-other, other}` (the full set `select-findings.sh` emits — see `IMPACT-RUBRIC.md §1`).
- **`cluster_members[]` is derived from the grouped-JSON `members[]`** that `select-findings.sh` produces; carry each member's full mutant **`name`** through. Element = `{name, file, line, genre, replacement, op_class}`. The fixer copies these `name` strings into its `claimed_killed`, and `verify-rerun.sh` matches on exactly that `name` — so dropping `name` here breaks verification.
- `function_name` (not `function`) everywhere.
- Required per finding: id, file, line, function_name, genre, replacement, op_class, playbook_shape, impact_score, domain, lane, status. Optional: mutant_name, cluster_members, rubric, blast_radius_callers, justification.

### fixer report (returned by each Sonnet fixer)
```json
{ "finding_id": "F1", "test_file": "tests/kill_F1.rs",
  "test_fn": "kill_mutant_src_lib_rs_2",
  "claimed_killed": [ "src/lib.rs:2:15: replace - with / in residual" ],
  "float_check": "n/a | mutated=<X> bound_excludes=true",
  "passes_on_real_code": true }
```

### `verify.json` (written by `verify-rerun.sh`)
```json
{ "generated_at": "2026-01-01T00:00:00Z", "scope": "src/lib.rs",
  "per_finding": [
    { "finding_id": "F1",
      "claimed_killed": [ "src/lib.rs:2:15: replace - with / in residual" ],
      "caught": true, "status": "caught" } ] }
```
A finding is `caught` iff NONE of its `claimed_killed` names appears in the re-run's fresh
`MissedMutant` rows. `status` spelling matches `top_findings[].status`.

**Write-back rule:** the orchestrator assembles the claims JSON for `verify-rerun.sh` from the
fixer reports (`{scope, per_finding:[{finding_id, claimed_killed}]}`), runs the script, then
patches each `findings.json` `top_findings[].status` from the matching `verify.json`
`per_finding[]` (by `finding_id`) **before** any resume decision.

## Re-dispatch → escalate ladder (per finding, Phase 4)

1. Verify says **caught** → done for that finding.
2. **Fake-kill** (not caught): re-dispatch the **same Sonnet fixer ONCE**, now handed the
   orchestrator-computed `mutated` value so it can tighten the assertion.
3. Still not caught → escalate that ONE finding to an **Opus fixer** that either writes the
   killing test OR reclassifies the finding to `accepted` with an argument. Then done.

Never loop more than this ladder; never re-run the whole suite chasing a single finding.

## DEFERRED promotion (bounded, v1)

When a top finding turns out equivalent at fix time (gate flips to ×0), refill the slot by
promoting the **next-highest already-scored** finding from `deferred[]` — **no second triage
pass** (it is already scored and ranked). Append each promotion to the `promoted` ledger so a
resume cannot re-promote the same item or loop. Refill up to the cap **once**; if still no
killable finding remains, report an honest zero with the accepted arguments.

## Terminal-state & robustness matrix

| Condition | Behavior |
|---|---|
| 0 missed after run | Report success, skip dispatch, done. |
| Fewer than 3 real survivors (N∈{1,2}) | Dispatch N fixers; `top_findings` holds N; partial verify. |
| All top findings equivalent at fix time | Bounded DEFERRED promotion (above); else honest zero. |
| Fake-kill on a finding | Re-dispatch same Sonnet once → escalate to Opus once → done for that finding. |
| Failure flood | Distinguish flaky (baseline twice / `--no-shuffle`) from jobs contention (`--jobs 1`); re-run ONCE; if it persists, HALT with a diagnostic — do not loop back to RUN. |
| Resume after compaction / partial run | If `findings.json` exists: skip CAUGHT/accepted (via `status` + `verify.json`); dedup `kill_mutant_*` by exact fn-name grep; continue from `deferred[]` via the monotonic `promoted` ledger. |
| Budget | Optional `--max-mutants-before-confirm` / wall-clock governor for unattended runs. |
| Lint gate | Verify runs the project's fmt/clippy on new test fns so they don't block the commit. |

Accepted-equivalents are **report-only** by default; writing `exclude_re` into
`.cargo/mutants.toml` requires explicit per-repo approval and is performed by the orchestrator
at the verify/report boundary — never by a script, never silently. Killing tests are left
**staged, not committed**.

## Resume / idempotency mechanics

- **Status:** each `top_findings` entry carries `status` (§schema); `verify.json` holds
  per-finding results. On resume, CAUGHT/accepted findings are skipped.
- **Dedup:** before dispatching a fixer, grep the target test file for the exact
  `fn kill_mutant_<file_sanitized>_<line>` — skip if present.
- **Promotion ledger:** DEFERRED→top promotions append to `promoted` (monotonic) so resume
  cannot re-promote or loop.
