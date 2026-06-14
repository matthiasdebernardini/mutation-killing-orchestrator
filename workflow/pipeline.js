// pipeline.js — optional multi-engine Workflow engine for mutation-killing-orchestrator.
//
// The skill's DEFAULT engine is direct Task/Agent dispatch (works everywhere Claude Code runs).
// This script is the optional accelerator: when the host has the Workflow tool AND the user opted
// in, the orchestrator deploys it to run triage -> fix -> verify -> adversarial-audit as one
// deterministic, resumable pipeline. OPPORTUNISTIC FRONTIER ROUTING — reach for frontier
// intelligence on the judgment-heavy phases when it's available, else fall back gracefully:
//   - triage : best DETECTED frontier judge — fable if present, else opus, else sonnet
//   - fix    : sonnet (mechanical Rust test authoring — not a frontier task)
//   - audit  : FRONTIER, CROSS-VENDOR skeptic panel — Codex gpt-5.5 (via `pi`) + fable +
//              openrouter/fusion (via the expanded `pior` command); falls back to opus if none.
//              cargo-mutants already proved the kill; the panel attacks TEST QUALITY
//              (brittle / over-fit / semantically-wrong / vacuous).
// All frontier engines are DETECTED in Phase 0. fable is temporarily unavailable upstream but is
// auto-used the moment it returns — no code change. See references/ENGINES.md.
//
// Deploy with:
//   Workflow({ scriptPath: "<skill_dir>/workflow/pipeline.js", args: {
//     skill_dir, crate_dir, outcomes_path:"mutants.out/outcomes.json",
//     top_n: 3, blast_mode: "ripgrep", run_mutants: false,
//     engines: { fable:true, codex:true, pior:true, fixer:"sonnet" }  // judge auto-derives: fable->opus
//   }})

export const meta = {
  name: 'mutation-killing-pipeline',
  description: 'Multi-engine mutation-killing: Claude triages + fixes, then a frontier cross-vendor panel (Codex + fable + openrouter/fusion, else opus) adversarially audits each confirmed kill',
  phases: [
    { title: 'Run', detail: 'optional: nextest baseline + cargo mutants (only if outcomes missing)' },
    { title: 'Triage', detail: '1x best detected frontier judge (fable/opus): select-findings.sh -> score -> top-N' },
    { title: 'Fix', detail: 'up to N sonnet fixers in parallel, one killing test per finding' },
    { title: 'Verify', detail: 'verify-rerun.sh: scoped re-run -> per-finding caught/missed' },
    { title: 'Audit', detail: 'frontier cross-vendor panel (Codex + fable + fusion, else opus) attacks each confirmed kill' },
  ],
}

// --- args + defaults ------------------------------------------------------------
const A = args || {}
const SKILL = A.skill_dir || '~/.claude/skills/mutation-killing-orchestrator'
const CRATE = A.crate_dir || '.'
const OUTCOMES = A.outcomes_path || 'mutants.out/outcomes.json'
const TOP_N = A.top_n || 3
const BLAST = A.blast_mode || 'ripgrep'
const RUN_MUTANTS = A.run_mutants === true
const IN = `In ${CRATE} (cd there first)`

// --- engine roster (orchestrator DETECTS availability in Phase 0; see ENGINES.md) ---
// FRONTIER-intelligence engines are reached for on the judgment-heavy phases (triage, audit) WHEN
// present, else the pipeline falls back to opus, then sonnet. All are OPT-IN: the script can't shell
// out to detect, so Phase 0 sets these flags. fable is a first-class frontier engine — temporarily
// banned upstream, but the moment detection sees it again it's used automatically (no code change).
const E = A.engines || {}
const FABLE = E.fable === true             // claude-fable-5 (frontier Claude)
const CODEX = E.codex === true             // Codex gpt-5.5 via `pi` (frontier, cross-vendor)
const PIOR  = E.pior  === true             // openrouter/fusion via expanded pior cmd (frontier; EXPENSIVE)
const JUDGE = E.judge || (FABLE ? 'fable' : 'opus')  // triage judge: best frontier Claude, else opus
const FIXER = E.fixer || 'sonnet'          // fix is mechanical test-authoring — workhorse model
const CODEX_CMD = E.codex_cmd || 'pi -p --no-tools'
// `pior` is an interactive-only shell ALIAS; a script must use the expanded command. We also DROP
// the alias's Rails --append-system-prompt flags — they'd bias a mutation-test review.
const PIOR_CMD = E.pior_cmd || 'pi --provider openrouter --model fusion --api-key "$(cat "$HOME/.config/orcc/key")" --no-context-files --no-skills --no-extensions -p --no-tools'

// Adversarial AUDIT panel: prefer the FRONTIER engines (Codex + fable + fusion) for cross-vendor
// diversity; if NONE are present, the best available Claude (opus) does the audit. Fix stays sonnet.
function skepticPanel() {
  const pool = []
  if (CODEX) pool.push({ kind: 'cli',    cmd: CODEX_CMD, name: 'codex/gpt-5.5' })
  if (FABLE) pool.push({ kind: 'claude', model: 'fable', name: 'fable' })
  if (PIOR)  pool.push({ kind: 'cli',    cmd: PIOR_CMD,  name: 'openrouter/fusion' })
  if (pool.length === 0) pool.push({ kind: 'claude', model: 'opus', name: 'opus' }) // best-Claude fallback
  return pool
}
const slug = s => s.replace(/[^A-Za-z0-9]/g, '')

// --- schemas --------------------------------------------------------------------
const FINDINGS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['top_findings', 'accepted_count', 'deferred_count'],
  properties: {
    top_findings: { type: 'array', items: { type: 'object', additionalProperties: false,
      required: ['id', 'file', 'line', 'function_name', 'playbook_shape', 'op_class', 'impact_score', 'domain', 'claimed_cluster_names'],
      properties: {
        id: { type: 'string' }, file: { type: 'string' }, line: { type: 'integer' },
        function_name: { type: 'string' }, playbook_shape: { type: 'string' },
        op_class: { type: 'string' }, impact_score: { type: 'number' }, domain: { type: 'string' },
        claimed_cluster_names: { type: 'array', items: { type: 'string' } },
      } } },
    accepted_count: { type: 'integer' }, deferred_count: { type: 'integer' },
  },
}
const FIXER_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['finding_id', 'test_file', 'test_fn', 'claimed_killed', 'passes_on_real_code', 'float_check'],
  properties: {
    finding_id: { type: 'string' }, test_file: { type: 'string' }, test_fn: { type: 'string' },
    claimed_killed: { type: 'array', items: { type: 'string' } },
    passes_on_real_code: { type: 'boolean' }, float_check: { type: 'string' },
  },
}
const VERIFY_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['per_finding'],
  properties: {
    per_finding: { type: 'array', items: { type: 'object', additionalProperties: false,
      required: ['finding_id', 'caught', 'status'],
      properties: { finding_id: { type: 'string' }, caught: { type: 'boolean' }, status: { type: 'string' } } } },
    summary: { type: 'string' },
  },
}
const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false, required: ['refuted', 'dimension', 'reason', 'engine'],
  properties: {
    refuted: { type: 'boolean' },
    dimension: { type: 'string', enum: ['brittle', 'over-fit', 'semantically-wrong', 'vacuous', 'sound'] },
    reason: { type: 'string' }, engine: { type: 'string' },
  },
}

// --- Phase 1 (optional): produce outcomes.json ----------------------------------
if (RUN_MUTANTS) {
  phase('Run')
  await agent(`${IN}, this is Phase 0/1 of the mutation-killing skill.
1. Run \`cargo nextest run\` — if RED, stop and report; mutation testing on a red baseline is meaningless.
2. Run \`cargo mutants --test-tool nextest --jobs "$(sysctl -n hw.ncpu)" --timeout 60\` (scope with
   --file/--in-diff if implied). Judge from the summary line, not the exit code.
Confirm ${OUTCOMES} now exists with a >0 .missed count, or report the terminal state (0 missed / flood).`,
    { label: 'run-mutants', phase: 'Run' })
}

// --- Phase 2: TRIAGE (best detected frontier judge: fable -> opus) --------------
phase('Triage')
const triage = await agent(`${IN}. You are the mutation-triage judge (skill: ${SKILL}).
1. Run \`${SKILL}/scripts/select-findings.sh ${OUTCOMES} mutants.out/mko-grouped.json\` (it groups
   survivors, parses op-class, pre-computes cluster size, pre-tags noise). Do NOT re-run jq.
2. Read mutants.out/mko-grouped.json and the rubric at ${SKILL}/references/IMPACT-RUBRIC.md.
3. Score impact = gate x (0.35*silent + 0.30*criticality + 0.20*blast + 0.15*cluster).
   silent = pre-computed max_silent_severity; criticality = domain keyword match (you may Read source);
   blast = ${BLAST} mode; cluster = from kills_per_test; gate x0 -> ACCEPTED with a written argument.
4. Pick a playbook_shape per finding from ${SKILL}/references/PLAYBOOK.md.
5. Rank by impact desc, take the top ${TOP_N}, write findings.json to ${CRATE}, return the schema.
   claimed_cluster_names = the exact .scenario.Mutant.name strings of every mutant in that finding's
   cluster (fixer must kill all; verify matches on these names). Triage is read-only over source.`,
  { model: JUDGE, label: `triage:${JUDGE}`, phase: 'Triage', schema: FINDINGS_SCHEMA })

if (!triage || !triage.top_findings || triage.top_findings.length === 0) {
  log('Triage found no killable findings (0 missed, or all equivalent). Nothing to fix.')
  return { confirmed: [], suspect: [], fake_kills: [], accepted_count: triage?.accepted_count || 0,
    deferred_count: triage?.deferred_count || 0, summary: 'No killable findings.' }
}
log(`Triage [${JUDGE}]: ${triage.top_findings.length} to fix; ${triage.accepted_count} accepted, ${triage.deferred_count} deferred.`)

// --- Phase 3: FIX (N sonnet fixers, parallel, lane-isolated) --------------------
phase('Fix')
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
log(`Fix [${FIXER}]: ${reports.length}/${triage.top_findings.length} fixers returned a green test.`)

// --- Phase 4: VERIFY (1 agent runs the scoped re-run via verify-rerun.sh) --------
phase('Verify')
const claims = { scope: CRATE, per_finding: reports.map(r => ({ finding_id: r.finding_id, claimed_killed: r.claimed_killed })) }
const scopeFiles = [...new Set(triage.top_findings.map(f => f.file))]
const verify = await agent(`${IN}. Phase 4 verification.
1. Write this claims JSON to /tmp/mko-claims.json (bash heredoc; plain > is fine under bash):
   ${JSON.stringify(claims)}
2. Run: \`${SKILL}/scripts/verify-rerun.sh /tmp/mko-claims.json -o verify.json -d mutants-verify.out -- ${scopeFiles.map(f => '--file ' + f).join(' ')}\`
   It runs nextest, does ONE scoped cargo-mutants re-run, writes verify.json, exits non-zero on any
   not-caught finding (a fake-kill) — that is data, not failure.
3. Read verify.json and return per_finding (finding_id, caught, status) verbatim, plus a one-line summary.`,
  { label: 'verify', phase: 'Verify', schema: VERIFY_SCHEMA })

const caughtIds = new Set((verify?.per_finding || []).filter(v => v.caught).map(v => v.finding_id))
const fakeKills = (verify?.per_finding || []).filter(v => !v.caught).map(v => v.finding_id)
if (fakeKills.length) log(`Verify: fake-kills (NOT caught): ${fakeKills.join(', ')} — re-dispatch/escalate per ORCHESTRATION.md.`)
log(`Verify: ${caughtIds.size}/${reports.length} kills confirmed by the scoped re-run.`)

// --- Phase 5: ADVERSARIAL AUDIT (cross-vendor panel attacks each CONFIRMED kill) ---
phase('Audit')
const confirmed = triage.top_findings.filter(f => caughtIds.has(f.id))
const panel = skepticPanel()
log(`Audit panel (per confirmed kill): ${panel.map(p => p.name).join(', ')}`)

function refuteBody(f, rep) {
  return `A killing test was written for finding ${f.id} and cargo-mutants CONFIRMED it kills ${JSON.stringify(f.claimed_cluster_names)}. Kill-status is settled — do NOT re-litigate it. Attack TEST QUALITY only. Read ${CRATE}/${rep ? rep.test_file : 'tests/kill_' + f.id + '.rs'} and the source ${CRATE}/${f.file}. Find ONE concrete reason this test should NOT be committed as-is: brittle (coupled to impl detail; a legit refactor breaks it), over-fit (asserts a value derived from the mutated logic, or only this exact mutant not the behavior), semantically-wrong (catches the mutant but encodes an INCORRECT expected value), or vacuous (passes on real code for the wrong reason). Default to sound (refuted=false) only if you genuinely find no defect.`
}

const audited = await parallel(confirmed.map(f => () => {
  const rep = reports.find(r => r.finding_id === f.id)
  return parallel(panel.map(p => () => {
    if (p.kind === 'cli') {
      const tmp = `/tmp/mko-audit-${f.id}-${slug(p.name)}.txt`
      return agent(`${IN}. Get a SECOND-OPINION code review from ${p.name} (a non-Claude model) and relay it verbatim.
1. Write this instruction to ${tmp}:
---
${refuteBody(f, rep)}
Reply with ONLY a JSON object: {"refuted":bool,"dimension":"brittle|over-fit|semantically-wrong|vacuous|sound","reason":"..."}
---
2. Run exactly: \`${p.cmd} "$(cat ${tmp})"\`   (this routes to ${p.name}; do NOT substitute another engine).
3. Read ${p.name}'s stdout, extract its JSON verdict, return it as the schema with engine="${p.name}".
If the CLI is missing or errors, return refuted=false, dimension="sound", reason="${p.name} unavailable", engine="${p.name}".`,
        { model: 'haiku', label: `audit:${f.id}#${slug(p.name)}`, phase: 'Audit', schema: VERDICT_SCHEMA })
    }
    return agent(`${IN}. You are an audit skeptic (engine ${p.model}). ${refuteBody(f, rep)} Set engine="${p.name}".`,
      { model: p.model, label: `audit:${f.id}#${slug(p.name)}`, phase: 'Audit', schema: VERDICT_SCHEMA })
  })).then(votes => {
    const v = votes.filter(Boolean)
    const suspect = v.some(x => x.refuted) // advisory quality gate: ANY vendor flags -> human review
    return { finding_id: f.id, file: f.file, function_name: f.function_name, impact_score: f.impact_score,
      suspect, verdicts: v.map(x => ({ engine: x.engine, refuted: x.refuted, dimension: x.dimension, reason: x.reason })) }
  })
}))

const confirmedClean = audited.filter(a => a && !a.suspect)
const suspect = audited.filter(a => a && a.suspect)
log(`Audit: ${confirmedClean.length} kills clean, ${suspect.length} flagged suspect for human review.`)

return {
  confirmed: confirmedClean,
  suspect,
  fake_kills: fakeKills,
  accepted_count: triage.accepted_count,
  deferred_count: triage.deferred_count,
  engines_used: { judge: JUDGE, fixer: FIXER, audit_panel: panel.map(p => p.name) },
  summary: `${confirmedClean.length} clean kills, ${suspect.length} suspect, ${fakeKills.length} fake-kills; ${triage.accepted_count} accepted-equivalent, ${triage.deferred_count} deferred. Audit panel: ${panel.map(p => p.name).join(' + ')}.`,
}
