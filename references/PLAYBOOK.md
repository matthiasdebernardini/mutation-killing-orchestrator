# Playbook — the 8 mutant→test shapes

Each shape has a stable `playbook_shape` token (emitted in `findings.json` and consumed by
the fixer). The seed for these recipes is the cargo-mutants skill's table at
`~/.claude/skills/cargo-mutants/SKILL.md` (the "killing-test recipes" section, ~lines
165–172); this file is the **canonical owner** and may extend it. `self-test.sh` runs a
content-drift guard that fails if any of the 8 shape tokens below disappears.

| `playbook_shape` | Mutant signature | Killing-test recipe |
|---|---|---|
| `label-enum` | `replace Enum::as_str -> &'static str with ""`/`"xyzzy"` | One exact-string assert per variant (`assert_eq!(X::V.as_str(), "v")`); the swap replaces the whole match, so one assert kills both stubs. Round-trip via `parse(as_str())` for free coverage. |
| `threshold-le` | `replace < with <=` (or `>` with `>=`) on a threshold | Assert behavior at the **exact boundary value** (e.g. `bmi_category(18.5)`); off-boundary tests can never distinguish these. |
| `threshold-flip` | `replace > with <`/`==` on a threshold | A positive case just **above** the cutoff (25.1 when cutoff is 25.0), paired with the boundary case in one test. |
| `predicate-bool` | `replace && with \|\|` in a predicate | A case where **exactly one conjunct is true**; assert the overall predicate is false. |
| `formula-op` | Operator swaps (`+ - * /`) inside a formula | One **known-value test with tight, hand-computed tolerance** kills every swap on the line at once; test each formula branch (e.g. both Mifflin and Harris–Benedict). |
| `validate-stub` | `replace validate_fn -> Ok(())` | Feed invalid input through the **public callers** and assert `is_err()` — one test per caller's guard. |
| `comparator-key` | Swaps inside a comparator/sort key (`max_by(a.x + a.y …)`) | Construct elements where the **sum-winner differs from the product/difference-winner**; assert an observable downstream result, not the comparator directly. |
| `conversion-stub` | `replace fn -> 0.0 / 1.0 / -1.0` on conversions | Exact-value assert with a non-trivial input (`assert_eq!(mg_to_mcg(2.5), 2500.0)`) — kills the stubs and the `*`→`+`/`/` swaps together. |

## Mapping op-class → likely shape

The triage agent picks `playbook_shape` per finding; this is the usual mapping:

- `arithmetic` on a formula line → `formula-op` (or `conversion-stub` if the fn is a unit conversion).
- `comparison` on a threshold → `threshold-le` (boundary swap) or `threshold-flip` (direction swap).
- `boolean`/`unary` in a predicate → `predicate-bool`.
- `fnvalue` on a validator → `validate-stub`; on an enum label fn → `label-enum`; on a conversion → `conversion-stub`.
- `label` → `label-enum` (or route to `accepted` as `label-noise` if truly cosmetic).

## Float-tolerance discipline (applies to every numeric shape)

Never use a loose range assert to "cover" a numeric line — a `*`→`+` swap can land inside a
wide range and survive. Pin to the hand-computed expected value with a tolerance tighter than
half the expected-vs-mutated gap. The orchestrator supplies that bound (see `ORCHESTRATION.md`
→ "The float bound"); the fixer must use it and report `float_check` in its fixer report.

## Test placement

Each fixer writes to a **distinct per-lane test file** (`tests/kill_F1.rs`, `tests/kill_F2.rs`,
…) so parallel fixers never collide. If a finding can only be tested from inside an existing
in-module `#[cfg(test)]` block shared with another lane, those two fixers run **sequentially**
within the otherwise-parallel batch. Test fns are named
`kill_mutant_<file>_<line>_<op>` for dedup on resume.
