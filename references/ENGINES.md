# Engines — opportunistic frontier routing

The skill is **engine-aware** and **opportunistic**: it reaches for **frontier intelligence on the
judgment-heavy phases** (triage and the adversarial audit) *when a frontier engine is actually
available*, and otherwise falls back gracefully to opus, then sonnet. Engines are **detected** in
Phase 0, never hardcoded; nothing here is a hard requirement.

> Personal-setup dependency: the non-Claude engines below are *this machine's* CLIs (`pi`, `pior`).
> When they (or fable) aren't present, the pipeline still runs — Claude-only.

## Two tiers

| Tier | Engines | Used for |
|---|---|---|
| **Frontier** (use when present + the task benefits) | **fable**, **Codex gpt-5.5**, **openrouter/fusion** | triage judge; adversarial audit panel |
| **Workhorse** (always available; fallback) | **opus**, **sonnet** | fix (sonnet); triage/audit fallback (opus) |

The rule, in one line: **if a frontier engine is present and the task can leverage frontier
intelligence, use Codex or fable — otherwise fall back to opus → sonnet.**

## Roster

| Engine | Model | Invoked (headless) | Detect | Tier / role |
|---|---|---|---|---|
| **Fable** | `claude-fable-5` | host `Task` tool, `model: fable` | host model list / `claude --model` probe | **frontier** — triage judge (preferred), audit skeptic |
| Opus | `claude-opus-4-8` | host `Task` tool, `model: opus` | always | triage judge (fallback), audit fallback |
| Sonnet | `claude-sonnet-4-6` | host `Task` tool, `model: sonnet` | always | fix; last-resort fallback |
| **Codex** | `gpt-5.5` (openai-codex) | `pi -p --no-tools "<prompt>"` | `command -v pi` | **frontier** — audit skeptic (cross-vendor) |
| **openrouter/fusion** | `fusion` | expanded `pior` command (below) | `command -v pi` **and** `[ -f ~/.config/orcc/key ]` | **frontier** — audit skeptic ($$$$) |

> **fable is temporarily unavailable upstream** but is a **first-class frontier engine** here —
> kept in the roster on purpose. The routing is detection-driven, so **the moment fable is available
> again it is used automatically, with no code change.** Do not remove it.

`pi`'s default provider here is **openai-codex / gpt-5.5** (verified by headless probe). Default
`text` mode prints the answer; the skill lets a cheap Claude relay agent normalize it into the
verdict schema, so messy CLI output is fine.

## The `pior` alias gotcha (important)

`pior` is an **interactive shell alias**, not a binary:

```
pior='pi --provider openrouter --model fusion --api-key "$(cat "$HOME/.config/orcc/key")" \
      --no-context-files --no-skills --no-extensions --append-system-prompt <rails> ...'
```

Aliases **do not exist in scripts / non-interactive shells**, so the skill calls the **expanded
command**, and **drops the alias's Rails `--append-system-prompt` flags** (they'd bias a
mutation-test review):

```bash
pi --provider openrouter --model fusion --api-key "$(cat "$HOME/.config/orcc/key")" \
   --no-context-files --no-skills --no-extensions -p --no-tools "<prompt>"
```

## Phase-0 detection → `engines` object

The orchestrator detects availability once and passes an `engines` object to the workflow (or uses
it directly in the Task-dispatch path). Frontier engines are **opt-in**: only enabled when detected.

```bash
# frontier Claude: prefer fable if the session can run it (it can't during the ban), else opus
if claude --model claude-fable-5 -p "ok" >/dev/null 2>&1; then FABLE=1; JUDGE=fable; else JUDGE=opus; fi
command -v pi >/dev/null                              && CODEX=1   # Codex gpt-5.5
command -v pi >/dev/null && [ -f ~/.config/orcc/key ] && PIOR=1    # openrouter/fusion (EXPENSIVE)
```

```jsonc
engines: {
  fable: false,           // true the moment the ban lifts -> judge auto-becomes fable, fable joins the audit
  codex: true,            // pi present
  pior:  true,            // pi present AND orcc key present (EXPENSIVE)
  fixer: "sonnet"
  // judge omitted -> derived: fable if fable:true, else opus
}
```

A cheaper, probe-free detection for the Claude tier: `claude --model <id> --fallback-model <id>`
auto-falls-back when the primary is unavailable — `--model claude-fable-5 --fallback-model claude-opus-4-8`
yields fable when it's back and opus meanwhile.

## Role → engine matrix

| Phase | Engine(s) | Why |
|---|---|---|
| Triage | **fable → opus → sonnet** (best detected frontier judge) | judgment-heavy; the strongest model that's actually available |
| Fix | **sonnet** | mechanical Rust test authoring + compiles; not a frontier task |
| **Audit** | **Codex + fable + openrouter/fusion** (whichever are present); **opus** if none | adversarial review benefits most from frontier, cross-vendor diversity |

Audit is the right home for frontier diversity: cargo-mutants already proved the *kill*, so the panel
only judges *test quality* (brittle / over-fit / semantically-wrong / vacuous) — exactly where a
second and third independent frontier vendor earns its keep. The gate is advisory: **any** vendor
that refutes flags the finding `suspect` for human review before commit.

## Cost guard

- **openrouter/fusion is expensive** (a trivial Codex probe was ~$0.008; fusion is materially higher).
  It is opt-in via detection; set `engines.pior = false` to drop it.
- Audit cost ≈ `confirmed_kills × panel_size` model calls. With the default top-3 cap and a 2–3-engine
  panel that's a bounded handful per run — triage already capped the work at 3.
- The relay agents that shell out to `pi`/`pior` run on **haiku** (cheap) — they only ferry the
  prompt and parse the verdict; the judgment is the frontier model's.

## Fallback ladder (graceful degradation — answers "does it fail to opus/sonnet?")

1. **Triage:** fable if detected → else **opus** → else sonnet. (Always lands on a working judge.)
2. **Fix:** always **sonnet**.
3. **Audit:** Codex + fable + fusion (whichever detected) → if **none**, the best Claude (**opus**)
   does the audit. Never a hard failure.
4. **No Workflow tool at all:** the whole skill runs via **direct Task dispatch** (Claude-only); this
   multi-engine layer is an optional accelerator, never a dependency.
