# Workflow engine (optional accelerator)

The skill's **default** engine is direct `Task`/Agent dispatch (Phase 2–4 in `SKILL.md`), which works
in any Claude Code session. When the host **has the `Workflow` tool** and the user **opts in**, the
orchestrator can instead deploy `workflow/pipeline.js` to run the whole loop as one deterministic,
resumable, multi-engine pipeline.

## When to use it (gate)

Deploy the workflow **only** when BOTH hold:

1. The `Workflow` tool exists in the session (orchestration-enabled setup), and
2. The user opted in — a `--workflow` / `--deep-verify` flag, or orchestration is already on.

Otherwise fall back to the direct Task dispatch. **Never make the workflow a hard requirement** — it
won't exist in a plain CLI install. Workflows are also token-heavy (they can spawn many agents), so
they must not fire by default.

## What it adds over direct dispatch

- **Deterministic fan-out** of the parallel fixers and the cross-vendor audit panel.
- **Structured output** (schema-validated `findings.json` / fixer reports / verdicts) with retries.
- **Resumability** — re-deploy with the runtime's resume to skip completed stages.
- **Engine variety** — a cross-vendor adversarial audit (see `ENGINES.md`).

## How the orchestrator deploys it

After Phase 0 detection (scope + baseline + engine availability), call the host `Workflow` tool:

```js
Workflow({
  scriptPath: "<skill_dir>/workflow/pipeline.js",
  args: {
    skill_dir:    "<abs path to this skill>",
    crate_dir:    "<abs path to the target crate>",   // cwd for all cargo/script calls
    outcomes_path:"mutants.out/outcomes.json",        // relative to crate_dir (or absolute)
    top_n: 3,                  // selection cap (--top N)
    blast_mode: "ripgrep",     // or "codegraph" if .codegraph/ exists
    run_mutants: false,        // true => the workflow also runs Phase 0/1 (baseline + cargo mutants)
    engines: {                 // from Phase-0 detection (see ENGINES.md)
      judge: "opus",           // opus | fable
      fixer: "sonnet",
      codex: true,             // pi present
      pior:  true,             // pi present AND ~/.config/orcc/key present (EXPENSIVE)
      claude_skeptic: false    // also add a Claude leg to the audit panel?
    }
  }
})
```

## Phases (mirror the 4-phase spine + an audit)

| Phase | Engine | Output |
|---|---|---|
| Run (optional) | shell agent | `outcomes.json` (only if `run_mutants` and it's missing) |
| Triage | Claude judge (opus→fable) | `findings.json` (top-N, schema-validated) |
| Fix | sonnet × N (parallel, lane-isolated) | one killing test + fixer report per finding |
| Verify | `verify-rerun.sh` | `verify.json` — per-finding caught/missed (cargo-mutants is ground truth) |
| Audit | cross-vendor panel (Codex + fusion) | per confirmed kill: `suspect` flag + per-engine verdicts |

## Return shape

```jsonc
{
  "confirmed":   [ { finding_id, file, function_name, impact_score, suspect:false, verdicts:[...] } ],
  "suspect":     [ { ..., suspect:true, verdicts:[ {engine, refuted, dimension, reason} ] } ],
  "fake_kills":  [ "F2" ],            // cargo-mutants says NOT caught -> re-dispatch/escalate
  "accepted_count": N, "deferred_count": N,
  "engines_used": { judge, fixer, audit_panel:[...] },
  "summary": "..."
}
```

`confirmed` = killed AND survived the audit. `suspect` = killed but a vendor flagged the test as
brittle/over-fit/semantically-wrong/vacuous — review before commit. `fake_kills` feed the
re-dispatch→escalate ladder in `ORCHESTRATION.md`. Tests are left **staged, never committed**.

## Relationship to the scripts

The workflow does **not** reimplement anything — its agents call the same
`scripts/select-findings.sh` and `scripts/verify-rerun.sh` as the direct-dispatch path. Only the
orchestration (fan-out, structured output, the cross-vendor audit) lives in `pipeline.js`.
