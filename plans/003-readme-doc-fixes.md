# Plan 003: Fix the two README inaccuracies — brittle self-test count and the dead codegraph link

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e231628..HEAD -- README.md`
> If `README.md` changed since this plan was written, compare the "Current state"
> excerpts against the live file before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `e231628`, 2026-06-14

## Why this matters

Two small but user-facing README defects. First impressions of an install hinge
on the "verify the install" step, and right now it lies:

1. **`README.md:52`** tells the user the install is healthy when they see
   `self-test: 36 passed, 0 failed`. The actual count today is **39** for
   `--quick` (and higher for a full run, and it varies with whether the optional
   `workflow/` layer and the companion `cargo-mutants` skill are present). A
   correct install therefore shows a number that does **not** match the doc,
   making a healthy install look broken. Hardcoding an exact, environment-dependent
   count is the bug; the fix is to stop asserting a specific number.
2. **`README.md:36`** links the word "codegraph" to a bare placeholder
   `https://github.com/` — a dead link that goes nowhere.

## Current state

`README.md:48-53` (the verify-install block):

```markdown
Verify the install:

```bash
~/.claude/skills/mutation-killing-orchestrator/scripts/self-test.sh
# -> self-test: 36 passed, 0 failed
```
```

`README.md:36` (the requirements table row):

```markdown
| [codegraph](https://github.com/) *(optional)* | Blast-radius fan-in. Falls back to `ripgrep` when absent. |
```

Confirmed actual: `bash scripts/self-test.sh --quick` ends with
`self-test: 39 passed, 0 failed` at commit `e231628`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Actual self-test count | `bash scripts/self-test.sh --quick \| tail -1` | `self-test: N passed, 0 failed` (N varies) |
| No stale "36 passed" | `grep -n '36 passed' README.md` | no matches |
| No dead link | `grep -n 'codegraph](https://github.com/)' README.md` | no matches |

Run from the repo root.

## Scope

**In scope** (the only file you should modify):
- `README.md`

**Out of scope** (do NOT touch):
- `scripts/self-test.sh` — do not change what the script prints; the fix is in the
  doc that quotes it.
- Any other table row or link in the README.

## Git workflow

- Branch: `advisor/003-readme-doc-fixes`
- One commit; suggested message: `docs: fix brittle self-test count and dead codegraph link in README`
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Stop asserting a specific self-test count

In `README.md:48-53`, replace the hardcoded expected line so it describes the
*shape* of a passing run, not an exact number. Target:

```bash
~/.claude/skills/mutation-killing-orchestrator/scripts/self-test.sh
# -> ends with: self-test: <N> passed, 0 failed   (N varies by environment; "0 failed" is what matters)
```

The load-bearing signal is `0 failed`; the passed count legitimately varies with
the host (whether the optional `workflow/` layer and companion `cargo-mutants`
skill are installed), so the doc must not pin it.

**Verify**: `grep -n '36 passed' README.md` → no matches; `grep -n '0 failed' README.md` → still present.

### Step 2: Fix the dead codegraph link

In `README.md:36`, remove the placeholder hyperlink, leaving "codegraph" as plain
text (the tool is an optional, environment-local capability with no canonical
public URL to point at — a dead link is worse than no link). Target row:

```markdown
| codegraph *(optional)* | Blast-radius fan-in. Falls back to `ripgrep` when absent. |
```

**Verify**: `grep -n 'codegraph](https://github.com/)' README.md` → no matches;
`grep -n '| codegraph' README.md` → 1 match.

### Step 3: Confirm nothing else in the README references the stale number

**Verify**: `grep -n 'passed, 0 failed' README.md` → exactly one line (the one you
edited in Step 1), and it no longer contains `36`.

## Test plan

No code tests apply (docs only). The three greps in Done criteria are the check.
Optionally run `bash scripts/self-test.sh --quick` and eyeball that the printed
final line is consistent with the new, non-numeric phrasing.

## Done criteria

ALL must hold:

- [ ] `grep -n '36 passed' README.md` → no matches
- [ ] `grep -n 'codegraph](https://github.com/)' README.md` → no matches
- [ ] `grep -n '0 failed' README.md` → still present (the meaningful signal kept)
- [ ] `git status` shows only `README.md` modified
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `README.md:36` or `:52` does not match the "Current state" excerpts (the README
  changed since `e231628`).
- You discover the codegraph tool *does* have a canonical URL documented elsewhere
  in the repo (e.g. in a reference doc) — report it so the link can point there
  instead of being removed.

## Maintenance notes

- If the self-test's check count is ever surfaced in docs again, keep it
  non-numeric or generate it — never hardcode, since it is environment-dependent.
- A reviewer should confirm the requirements table still renders (the codegraph
  row is now plain text in a Markdown table cell, which is valid).
