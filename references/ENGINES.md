# Engines — multi-vendor dispatch

The skill is **engine-aware**. Claude is the backbone (it triages and writes the tests), but the
**adversarial audit** is deliberately **cross-vendor**: Claude proposes, rival vendors dispose. This
catches blind spots a single-vendor panel shares. Engines are **detected**, never hardcoded, and the
pipeline degrades gracefully when one is absent.

> Personal-setup dependency: the non-Claude engines below are *this machine's* CLIs (`pi`, `pior`).
> This whole layer lives on a private branch / the local install — the public skill is Claude-only.

## Roster

| Engine | Model | How it's invoked (headless) | Detect | Role |
|---|---|---|---|---|
| Claude Opus | `claude-opus-4-8` | host `Task` tool, `model: opus` | host model list / `claude --model` | triage judge (preferred) |
| Claude Fable | `claude-fable-5` | host `Task` tool, `model: fable` | host model list | triage judge (fallback) |
| Claude Sonnet | `claude-sonnet-4-6` | host `Task` tool, `model: sonnet` | always | fixers; safety-net skeptic |
| **Codex** | `gpt-5.5` (openai-codex) | `pi -p --no-tools "<prompt>"` | `command -v pi` | **audit skeptic** |
| **openrouter/fusion** | `fusion` | expanded `pior` command (below) | `command -v pi` **and** `[ -f ~/.config/orcc/key ]` | **audit skeptic** ($$$$) |

`pi`'s default provider here is **openai-codex / gpt-5.5** — verified with a headless probe. Output:
default `text` mode prints the answer; `--mode json` streams events (parse `text_end`/`agent_end`).
The skill uses text mode and lets a Claude relay agent normalize the answer into the verdict schema.

## The `pior` alias gotcha (important)

`pior` is an **interactive shell alias**, not a binary:

```
pior='pi --provider openrouter --model fusion --api-key "$(cat "$HOME/.config/orcc/key")" \
      --no-context-files --no-skills --no-extensions --append-system-prompt <rails> ...'
```

Aliases **do not exist in scripts / non-interactive shells**, so the skill must call the **expanded
command**, and it **drops the alias's Rails `--append-system-prompt` flags** — those would bias a
mutation-test review. The expansion the skill uses:

```bash
pi --provider openrouter --model fusion --api-key "$(cat "$HOME/.config/orcc/key")" \
   --no-context-files --no-skills --no-extensions -p --no-tools "<prompt>"
```

## Phase-0 detection → `engines` object

The orchestrator detects availability once in Phase 0 and passes an `engines` object to the workflow
(or uses it directly in the Task-dispatch path):

```bash
JUDGE=opus   # prefer opus; if the session can't run it, fall back to fable, then sonnet
command -v pi >/dev/null                                  && CODEX=1
command -v pi >/dev/null && [ -f ~/.config/orcc/key ]     && PIOR=1
```

```jsonc
engines: {
  judge: "opus",          // or "fable" — best Claude judge the session offers
  fixer: "sonnet",
  codex: true,            // pi present
  pior: true,             // pi present AND orcc key present
  claude_skeptic: false   // add a Claude leg to the audit panel too?
}
```

For Claude-model detection specifically: the host `Task` tool is the source of truth for which
`model:` values the session accepts; `claude --model <id> --fallback-model <id>` is the headless
equivalent. Prefer `opus → fable → sonnet`.

## Role → engine matrix

| Phase | Engine(s) | Why |
|---|---|---|
| Triage | best Claude judge: **opus → fable** | judgment-heavy; the strongest single model |
| Fix | **sonnet** | reliable Rust test authoring + compiles; speed |
| **Audit** | **Codex gpt-5.5 + openrouter/fusion** (cross-vendor), optional Claude leg | adversarial review benefits most from vendor diversity |

Audit is the right home for variety: cargo-mutants already proved the *kill*, so the panel only
judges *test quality* (brittle / over-fit / semantically-wrong / vacuous) — exactly where a second
and third independent vendor earns its keep. The gate is advisory: **any** vendor that refutes flags
the finding `suspect` for human review before commit.

## Cost guard

- **openrouter/fusion is expensive.** A trivial Codex probe was ~$0.008; fusion is materially higher.
  It is enabled here by explicit choice (private branch); set `engines.pior = false` to drop it.
- Audit cost ≈ `confirmed_kills × panel_size` model calls. With the default top-3 and a 2-vendor
  panel that's ≤6 external calls per run — bounded, because triage already capped the work at 3.
- The relay agents that shell out to `pi`/`pior` run on **haiku** (cheap) — they only ferry the
  prompt and parse the verdict; the actual judgment is the external model's.

## Fallback ladder (graceful degradation)

1. No `pi` → audit panel falls back to a single **sonnet** skeptic (still useful, no variety).
2. `pi` but no orcc key → **Codex only** panel (drop fusion).
3. No Workflow tool at all → the whole skill runs via **direct Task dispatch** (Claude-only); this
   multi-engine layer is the optional accelerator, never a hard dependency.
