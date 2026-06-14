# Plan 004: Add a GitHub Actions CI workflow that runs the self-test, shellcheck, and JS syntax check on every push

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat e231628..HEAD -- scripts/self-test.sh && ls .github/workflows 2>/dev/null`
> If `.github/workflows/` already contains a CI workflow, treat it as a STOP
> condition (reconcile rather than overwrite).

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (soft: lands best after plans 001 and 002, so CI exercises the unified naming + the new op-class coverage — but it does not require them)
- **Category**: dx
- **Planned at**: commit `e231628`, 2026-06-14

## Why this matters

The repo already ships a thorough `scripts/self-test.sh` (install integrity,
cross-link resolution, drift guards, a JS syntax check, and an end-to-end smoke),
but **nothing runs it automatically**. There is no `.github/` directory. Drift
that the self-test is designed to catch — a broken cross-link, an invalid
`pipeline.js`, a renamed schema counter — only surfaces if a human remembers to
run the script locally. A tiny CI job closes that gap on every push and PR, which
matters most for an in-dev skill whose contract is spread across docs + scripts +
a JS pipeline.

## Current state

- No `.github/` directory exists (confirm: `ls .github 2>/dev/null` → nothing).
- `scripts/self-test.sh` accepts `--quick` (`self-test.sh:22`), which **skips the
  slow `cargo mutants` crate smoke** (`self-test.sh:120-122`) — exactly what CI
  wants, since cargo-mutants is not installed on a stock runner.
- The self-test degrades gracefully when optional deps are absent:
  - companion `cargo-mutants` skill missing → Sections 5/6 print a skip line, no
    failure (`self-test.sh:88-91`, `:95-100`).
  - `cargo`/`cargo-mutants` missing → smoke skipped (already skipped by `--quick`).
  - `node` present → Section 9 runs the `pipeline.js` syntax check
    (`self-test.sh:201-205`); if absent it prints a skip line. CI will install node
    so this check actually runs.
- The script's exit code is `0` iff `FAIL == 0` (`self-test.sh:218-220`).
- The three scripts use `#!/usr/bin/env bash` and `set` flags (the self-test
  enforces this on itself at `:42-46`), so `shellcheck` applies cleanly.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Self-test locally | `bash scripts/self-test.sh --quick` | ends `self-test: N passed, 0 failed`, exit 0 |
| Shellcheck locally (if installed) | `shellcheck --severity=error scripts/*.sh` | no output, exit 0 |
| YAML sanity | `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` | no output, exit 0 |

Run from the repo root. (`shellcheck` may not be installed locally — that is fine;
CI provides it. If it is installed and reports an **error**, STOP and report.)

## Scope

**In scope** (create only this file):
- `.github/workflows/ci.yml`

**Out of scope** (do NOT touch):
- `scripts/self-test.sh` and every other script — CI runs them as-is; do not
  modify them to make CI pass. If the self-test fails on a stock Ubuntu runner,
  that is a finding to report, not to paper over.
- `README.md` — adding a CI badge is a nice-to-have explicitly deferred (see
  Maintenance notes); not part of this plan.

## Git workflow

- Branch: `advisor/004-ci-workflow`
- One commit; suggested message: `ci: run self-test, shellcheck, and JS check on push and PR`
- Do NOT push or open a PR unless instructed. (Note: the workflow only *runs* once
  it reaches GitHub on a branch/PR; locally you verify YAML validity + that the
  commands it invokes pass.)

## Steps

### Step 1: Create the workflow file

Create `.github/workflows/ci.yml` with exactly this content:

```yaml
name: ci

on:
  push:
  pull_request:

jobs:
  self-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '20'

      - name: Verify required tools
        run: |
          jq --version
          node --version
          shellcheck --version

      - name: Shellcheck (errors only)
        run: shellcheck --severity=error scripts/*.sh

      - name: Self-test (quick)
        run: bash scripts/self-test.sh --quick
```

Why these choices (do not paste as comments):
- `ubuntu-latest` ships `jq` and `shellcheck` preinstalled; `setup-node` provides
  `node` so the self-test's `pipeline.js` syntax check (Section 9) actually runs.
- `--quick` skips the cargo-mutants crate smoke, which a stock runner cannot do.
- `shellcheck --severity=error` fails the build only on real errors, not style
  nits — a deliberate, non-noisy starting bar (tighten later; see Maintenance).
- The companion `cargo-mutants` skill is absent on the runner, so the self-test's
  Sections 5/6 self-skip — expected and fine.

### Step 2: Validate the YAML locally

**Verify**: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"`
→ no output, exit 0. (If `python3`/`yaml` is unavailable, instead confirm the file
parses with `node -e "require('fs').readFileSync('.github/workflows/ci.yml','utf8')"`
exit 0 and eyeball indentation against the block above.)

### Step 3: Prove the two commands CI will run actually pass here

**Verify (self-test)**: `bash scripts/self-test.sh --quick` → exit 0, last line
`self-test: N passed, 0 failed`.

**Verify (shellcheck, only if installed)**: `command -v shellcheck && shellcheck --severity=error scripts/*.sh`
→ exit 0, no output. If `shellcheck` is not installed locally, skip this check —
CI will run it; do NOT install anything.

## Test plan

No unit tests. The workflow's own steps are the test: a `verify required tools`
step (fails loudly if the runner image ever drops `jq`/`shellcheck`), a shellcheck
gate, and the self-test gate. Local verification is YAML validity (Step 2) plus
running the invoked commands (Step 3).

## Done criteria

ALL must hold:

- [ ] `.github/workflows/ci.yml` exists and parses as valid YAML (Step 2)
- [ ] `bash scripts/self-test.sh --quick` exits 0 locally
- [ ] If `shellcheck` is installed locally, `shellcheck --severity=error scripts/*.sh` exits 0
- [ ] `git status` shows only the new `.github/workflows/ci.yml` added (no script edits)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `.github/workflows/` already exists with a CI workflow — reconcile, don't clobber.
- `bash scripts/self-test.sh --quick` fails locally — that is a real self-test
  failure to report, not something to fix by editing scripts or weakening the CI step.
- A local `shellcheck --severity=error` run reports an **error** (not a warning) —
  report the finding; do not edit the flagged script under this plan.
- The runner-tool assumptions look wrong for this repo (e.g. the scripts turn out
  to need macOS-only `sysctl`): note that `--quick` avoids the `sysctl` path
  (it lives in the cargo smoke / `verify-rerun.sh`), but if you find a `--quick`
  code path that calls a macOS-only command, STOP and report.

## Maintenance notes

- Deferred follow-ups (not in this plan): a CI badge in `README.md`; tightening
  shellcheck from `--severity=error` to `--severity=warning` once the scripts are
  confirmed warning-clean; adding a separate matrix leg that installs
  `cargo-mutants` and runs the **full** self-test smoke (slow — opt-in / scheduled).
- A reviewer should confirm the workflow triggers (`push`, `pull_request`) match
  the project's branching model and that no secrets are referenced (none are).
- If `scripts/self-test.sh` gains a hard dependency on the companion skill or on
  cargo, this CI job will start failing — keep the `--quick` path runner-portable.
