---
name: mutation-killing-orchestrator
description: Triage and KILL the highest-impact surviving mutants in a Rust crate. Rank cargo-mutants survivors by real-world impact and write killing tests for the top findings, discarding equivalent mutants with written arguments. Use AFTER mutation testing has produced survivors. To RUN mutation testing or just find missed mutants, use cargo-mutants instead.
allowed-tools: Task, Bash, Read, Edit, Write, Glob, Grep
---

<!-- TOC: 1 One Rule · 2 When to use (vs cargo-mutants) · 3 The 4-phase spine · 4 Model dispatch · 5 Rubric summary · 6 Phase-1 command · 7 Anti-patterns · 8 Reference index -->

# mutation-killing-orchestrator

> **The One Rule.** Rank surviving mutants by real-world impact, kill up to the top
> three, defer the rest honestly — never chase 100%, and never spend a test killing an
> equivalent mutant. The smartest model judges; cheaper models execute.

This skill is a **routing spine**. The full rubric, prompts, schemas, and recipes live in
`references/`; the deterministic logic lives in `scripts/`. Do not inline verbatim prompts,
schemas, or rubric tables here — read them from the reference files at dispatch time.

## 1. When to use this skill (vs `/cargo-mutants`)

| You want to… | Use |
|---|---|
| RUN mutation testing, find missed mutants, check test quality | `cargo-mutants` skill |
| Triage existing survivors by impact and **write the killing tests** for the top findings | **this skill** |

This skill *reuses* the cargo-mutants run mechanics (it inlines the literal command, §6) but
owns the triage → fix → verify loop. Both can be installed side by side.

## 2. The 4-phase, model-tiered spine

| Phase | Model | What |
|---|---|---|
| 0 — Bootstrap & scope | Orchestrator (session Opus) | Confirm scope (`--package`/`--file`/`--in-diff <diff-file>`); gitignore `mutants.out/`; `cargo nextest run -p <crate>` baseline (HALT if red); assert cargo-mutants uses nextest (`--test-tool nextest`); detect codegraph + jq. Dispatch capability (`Task` + `model:` override) is an **asserted precondition** — not probed. |
| 1 — RUN | Deterministic shell | Inline cargo-mutants command (§6), background, judge from the **summary line** (never `\| tail`). 0 missed → report success, done. Failure flood → one flaky-vs-jobs re-run, then HALT. |
| 2 — TRIAGE | **1× Task, best frontier judge** (`model: fable` if available, else `model: opus`), effort=high (xhigh if raw `MissedMutant` count > 100) | Run `scripts/select-findings.sh` first (deterministic grouping + op-class + noise pre-tag), then dispatch ONE judge agent that **consumes** that grouped JSON (no re-jq), scores, selects up to top-3, and writes `findings.json`. Triage is judgment-heavy → use the best **detected** model (opportunistic; never hardcoded). Prompt: `references/ORCHESTRATION.md`. |
| 3 — FIX | **N× Task, `model: sonnet`** (N in 1..3, one message) | One fixer per finding, lane-isolated test file (`tests/kill_F1.rs`…), playbook recipe + orchestrator-supplied float bound. Tests are left **staged, never committed**. Prompt: `references/ORCHESTRATION.md`. |
| 4 — VERIFY | Orchestrator + escalation | nextest green once + static float pre-check + lint → `scripts/verify-rerun.sh` (one scoped re-run) → per-finding caught/missed → re-dispatch same Sonnet once → escalate that finding to an Opus fixer once. |

See `references/ORCHESTRATION.md` for the full state machine, terminal states, and
resume/idempotency contract.

## 3. Model dispatch (the literal mechanism)

The host **`Task`** tool (the Agent dispatch tool) accepts a per-agent **`model:`** override.
Dispatch:

1. **Triage:** one `Task` call, `model: opus`, with the triage prompt from
   `references/ORCHESTRATION.md`. Effort high; xhigh only when raw `MissedMutant` count > 100.
2. **Fix:** up to 3 `Task` calls **in a single message** (so they run in parallel), each
   `model: sonnet`, one fixer per finding.

> If this install names the dispatch tool something other than `Task`, substitute the real
> name in the frontmatter and here — but it must be present, or the `model:`-override
> dispatch will not work.

## 4. Impact rubric (summary — full version in `references/IMPACT-RUBRIC.md`)

`impact = killability_gate × (0.35·silent_severity + 0.30·criticality + 0.20·blast_radius + 0.15·cluster_size)` → 0..5.0

- **silent_severity (0.35):** arithmetic op-swap = 5; comparison/boolean/unary swap or `FnValue` stub = 3; label/cosmetic = 1 (full op-class table in `references/IMPACT-RUBRIC.md`). Op-class is parsed from `.scenario.Mutant.name`, not `.replacement`.
- **criticality (0.30):** money/health/identity/data-integrity keyword match → 5/3/1.
- **blast_radius (0.20):** codegraph callers (rg fallback) ≥10/public = 5; 3–9 = 3; 1–2 = 1.
- **cluster_size (0.15):** raw mutants sharing the merge key `(file, function_name, line)`. ≥8 = 5; 4–7 = 3; 1–3 = 1.
- **killability_gate (×0/×1):** ×0 → ACCEPTED if no input both reaches the line and observes a different result (`guarded-threshold`, `float-never-equals`).

**Selection:** cut = top 3 by default (`--top N` override); actual count = `min(cap, killable)`,
so `top_findings` has length 1..N (never 0 — the 0 case is the "0 missed" terminal state).

## 5. Phase-1 cargo-mutants command (inlined; cargo-mutants skill is the source of the flags)

```bash
cargo mutants -p <crate> --test-tool nextest --jobs "$(sysctl -n hw.ncpu)" \
  [--file <f> | --in-diff /tmp/scope.diff] --timeout <t>   # background; judge from the summary line
```

For `--in-diff`, Phase 0 produces the diff first (`git diff main... > /tmp/scope.diff`) — in
v27 the flag REQUIRES a diff-file value.

## 6. Anti-patterns (do not do these)

- Chase 100% kill ratio. The goal is the top-impact survivors, honestly reported.
- Spend a test on an equivalent mutant. Route it to ACCEPTED with a written argument.
- Triage on `missed.txt`. Triage on `outcomes.json` (it carries `genre`/`function`/`replacement`).
- Judge a run by exit code or `| tail`. Judge by the summary line and `outcomes.json`.
- Classify op severity from `genre` alone — arithmetic, comparison, and boolean all share `genre == "BinaryOperator"`. Parse the swap from `.scenario.Mutant.name`.
- Read `.replacement` as the swap — it is the NEW token only.
- Auto-commit the killing tests, or silently write `exclude_re`. Both require explicit approval.
- Use `rm` in any script — use `trash` or leave `mktemp -d` dirs.

## 7. Optional: multi-engine workflow accelerator

The default engine above (direct `Task` dispatch) works everywhere. **If** the host session has the
`Workflow` tool **and** the user opts in (a `--workflow` flag, or orchestration already on), the
orchestrator may instead deploy `workflow/pipeline.js` to run the whole loop as one deterministic,
resumable pipeline — with **opportunistic frontier routing**: reach for frontier intelligence on the
judgment-heavy phases *when it's available*, else fall back gracefully.

- **Triage:** best detected frontier judge — `fable` if present, else `opus`, else `sonnet`.
- **Fix:** `sonnet` (mechanical test authoring — not a frontier task).
- **Audit:** a **frontier, cross-vendor** skeptic panel — **Codex `gpt-5.5`** (via `pi`), **fable**,
  and **openrouter/fusion** (via the expanded `pior` command) — attacks each *confirmed* kill for
  brittleness/over-fitting; falls back to **opus** when no frontier engine is present.

Frontier engines are **detected** in Phase 0, never hardcoded — `fable` is temporarily unavailable
upstream but is **auto-used the moment it returns** (no code change). The pipeline always degrades to
Claude-only (opus/sonnet) when the external CLIs are absent. Never a hard dependency — see
`references/WORKFLOW.md` (deploy + gate) and `references/ENGINES.md` (roster, detection, the
`pior`-alias gotcha, cost guard, fallback ladder).

## 8. Reference index

- `references/IMPACT-RUBRIC.md` — full rubric, op-class derivation, domain keywords, blast-radius procedure (+ rg fallback), tie-break ladder, accepted taxonomy, float-tolerance trap.
- `references/PLAYBOOK.md` — the 8 mutant→test shapes (stable `playbook_shape` tokens).
- `references/ORCHESTRATION.md` — dispatch contract, verbatim triage + fixer prompts, `findings.json`/`fixer-report`/`verify.json` schemas, float-bound procedure, re-dispatch→escalate ladder, terminal-state matrix, resume/idempotency.
- `references/ENGINES.md` — multi-vendor engine roster, Phase-0 detection, the `pior`-alias gotcha, role→engine matrix, cost guard, fallback ladder.
- `references/WORKFLOW.md` — when/how the orchestrator deploys `workflow/pipeline.js`, the args contract, phases, and return shape.
- `workflow/pipeline.js` — the optional multi-engine Workflow script (triage → fix → verify → cross-vendor audit).
- `scripts/select-findings.sh` — deterministic grouping + op-class + noise pre-tag → grouped JSON.
- `scripts/verify-rerun.sh` — scoped re-run → per-finding caught/missed → `verify.json`.
- `scripts/self-test.sh` — install integrity + drift guards + end-to-end quick-smoke.
