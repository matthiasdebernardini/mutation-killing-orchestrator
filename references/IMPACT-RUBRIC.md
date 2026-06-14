# Impact rubric

The scoring model the triage agent applies to each merged finding. Every dimension is
measured deterministically from `outcomes.json` (pre-grouped by `select-findings.sh`),
except blast radius (codegraph/rg) and the killability gate (a reasoning judgment).

```
impact = killability_gate × (0.35·silent_severity + 0.30·criticality + 0.20·blast_radius + 0.15·cluster_size)
```

Each weighted dimension is scored **1 / 3 / 5**; the weights sum to **1.00**; the gate
multiplies by **0 or 1**; so `impact ∈ [0, 5.0]`.

| Dimension | Weight | Measured from |
|---|---|---|
| silent_severity | 0.35 | op-class (genre + parsed swap) |
| criticality | 0.30 | `function_name` + file path + `return_type` keyword match |
| blast_radius | 0.20 | codegraph callers (rg fallback) |
| cluster_size | 0.15 | count of raw mutants on the merge key |
| killability_gate | ×0 / ×1 | reachability + observability judgment |

`select-findings.sh` pre-computes `silent_severity` (as `max_silent_severity` per finding)
and `cluster_size` (as `kills_per_test`). The triage agent computes criticality, blast
radius, and the gate, then the weighted score.

## 1. silent_severity (0.35) — op-class derivation

The swap is **NOT** in `.scenario.Mutant.replacement` (that field is the NEW token only,
e.g. `"/"`, `"=="`, `"0"`). Arithmetic, comparison, AND boolean swaps all carry
`genre == "BinaryOperator"`, so genre alone cannot separate them. The original→new swap is
only in `.scenario.Mutant.name`, e.g. `"src/lib.rs:2:7: replace * with / in residual"`.
`select-findings.sh` parses it with `capture("replace (?<a>[^ ]+) with ")` and classifies the
original operator:

| op_class | Original operator | silent_severity | Why |
|---|---|---|---|
| `arithmetic` | `+ - * / %` | **5** | Flips a numeric result with no panic, no compile error — nothing else catches it. |
| `comparison` | `< > <= >= == !=` | 3 | Boundary/invariant flip; usually observable at a boundary value. |
| `boolean` | `&& \|\|` | 3 | Predicate flip in validation logic. |
| `binop-other` | other `BinaryOperator` swaps (bitwise `& \| ^ << >>`) | 3 | A real logic/bit-op flip — not arithmetic-on-a-quantity, but still behavioral. |
| `unary` | `genre == "UnaryOperator"` (e.g. `!`) | 3 | Negation flip; logic inversion. |
| `fnvalue` | `genre == "FnValue"` (whole-function stub, no swap to parse) | 3 | Replaces the body with `Default`/`0`/`Ok(())`; killable by a value assert. |
| `label` | name matches `as_str`/`Display`/`Debug` | 1 | Cosmetic; rarely worth a test. |
| `other` | anything else | 1 | Conservative default. |

A finding's `silent_severity` = the **max** over its members (one known-value test usually
kills every swap on the line, and the highest-severity swap drives impact).

> Panic/crash severity is intentionally absent: a mutation that panics is generally CAUGHT
> by the existing suite, so it is not a survivor in `outcomes.json` in the first place.

## 2. criticality (0.30) — domain keyword match

Match `.scenario.Mutant.function.function_name`, the file path, and
`.scenario.Mutant.function.return_type` against these domains. Highest match wins.

| Score | Domain | Example keywords (substring, case-insensitive) |
|---|---|---|
| **5** | money | `price`, `amount`, `balance`, `residual`, `cost`, `fee`, `total`, `cents`, `payment`, `invoice`, `tax`, `discount`, `refund`, `ledger` |
| **5** | health | `dose`, `dosage`, `mg`, `mcg`, `bmr`, `bmi`, `calorie`, `kcal`, `macro`, `weight`, `bp`, `glucose`, `heart_rate` |
| **5** | identity | `auth`, `token`, `nsec`, `pubkey`, `secret`, `password`, `session`, `permission`, `role`, `verify`, `sign` |
| **5** | data-integrity | `hash`, `checksum`, `merkle`, `consistency`, `invariant`, `dedupe`, `reconcile`, `migrate` |
| 3 | adjacent | helper math feeding the above (`scale`, `ratio`, `convert`, `normalize`, `clamp`) |
| 1 | other | everything else |

Keep the keyword lists in this file; extend per-project as patterns recur.

## 3. blast_radius (0.20) — fan-in

**codegraph mode (default when `.codegraph/` exists):**
- `codegraph_callers` on `function_name` (path-qualify if the name is ambiguous) → count of
  distinct caller symbols.
- `codegraph_node` visibility → if the function is `pub`/public-API, treat as high regardless
  of caller count.

**ripgrep fallback (when `.codegraph/` is absent):**
- `rg -w '<function_name>\s*\(' <crate>/src` minus the defining file, count matches.

| Score | Condition |
|---|---|
| 5 | ≥10 callers **or** public API |
| 3 | 3–9 callers |
| 1 | 1–2 callers |

Record `blast_radius_mode` (`codegraph`\|`ripgrep`) and the raw `blast_radius_callers` count
in `findings.json`.

## 4. cluster_size (0.15) — kills-per-test

`select-findings.sh` sets `kills_per_test` = the number of raw mutants sharing the **merge
key** (see Canonical keys). One known-value test typically kills the whole cluster.

| Score | kills_per_test |
|---|---|
| 5 | ≥8 |
| 3 | 4–7 |
| 1 | 1–3 |

## 5. killability_gate (×0 / ×1)

`×0` (→ route to `accepted`, do NOT spend a test) when no input both **reaches** the mutated
line and **observes** a different result. The triage agent writes the argument. Signatures:

| accepted `reason` | Signature |
|---|---|
| `guarded-threshold` | `trials > 0 → trials >= 0` where an earlier guard guarantees `trials >= 3`; the swap is unobservable. |
| `float-never-equals` | `wilson > 0.4 → wilson >= 0.4` where the float can never equal `0.4` exactly (measure-zero boundary). |
| `proof-harness` | Kani/proof-only code, not exercised by runtime tests. |
| `label-noise` | `Display`/`as_str` label or lookup mutants with no behavioral effect. |
| `trait-plumbing` | Boilerplate trait impls with no observable behavior. |

These five spellings are the **canonical `accepted[].reason` taxonomy** — the triage agent uses
them in the gate and in `findings.json` `accepted[]`.

> **Path-noise hints are separate.** `select-findings.sh` additionally pre-tags whole findings
> with a `noise_reason` of `proof-harness` (kani), `bench`, `example`, `build-script`, or
> `label-noise` from the file path / op-class. Of these, `proof-harness` and `label-noise`
> overlap the taxonomy above and belong in `accepted[]`; `bench`/`example`/`build-script` are
> pure **drops** — the triage agent omits them from `findings.json` entirely rather than
> recording them as accepted equivalents.

## 6. Canonical keys (one definition, used everywhere)

- **Raw de-dup key** (de-duplicate identical cargo-mutants rows only):
  `(file, function_name, line, genre, replacement)` — the 5-tuple. Never the count basis.
- **Merge key** (defines a "finding"; the count basis for `cluster_size`/`kills_per_test`):
  `(file, function_name, line)` — the 3-tuple. Collapses `FnValue` stubs and operator swaps
  on the same line into one finding. Verified example (21-mutant fixture): this grouping
  yields `{residual:line 2 → 5, scale:line 5 → 7, in_band:line 8 → 9}`.

The JSON field is named **`function_name`** (nested at
`.scenario.Mutant.function.function_name`). Use that single token everywhere.

## 7. Tie-break ladder (deterministic top selection)

drop noise → apply gate → score → **sort by impact desc**, then:

1. higher `kills_per_test`
2. higher `blast_radius_callers`
3. lower construction cost (fewer distinct op-classes / simpler test)
4. lexicographic `file:line`

This is a total order ⇒ reproducible selection. Cut = **top 3** by default (`--top N`
override). Actual count = `min(cap, killable survivors)`; `top_findings` length is `1..N`
(never 0). Survivors below the cut → `deferred`.

## 8. The float-tolerance trap

A range assert like `assert!(w > 0.43 && w < 0.45)` let a `z*z → z+z` mutant survive because
the mutated value (`0.4364`) still fell inside the range. When a numeric mutant survives a
test that *looks* like it covers the line, compute the mutated value and tighten the tolerance
until it falls outside; pin to the hand-computed expected value
(`(w - 0.438494).abs() < 5e-4`), never widen "to be safe". The orchestrator-supplied float
bound (see `ORCHESTRATION.md`) automates this for each numeric finding.
