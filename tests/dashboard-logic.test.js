#!/usr/bin/env node
'use strict';
//
// Regression tests for tools/dashboard/app.js's client-side status logic.
//
// The kit's only 3 dashboard tests (tests/run.sh, search "dashboard") check
// that GENERATED HTML contains expected static strings/structure — none of
// them ever execute app.js's logic against a crafted ledger. That is exactly
// how two real bugs in computeStatus()/buildExecutions() shipped invisibly:
// a same-round fail-then-corrected-to-pass tripped the top-level status to
// "Failed" forever (anyFail never un-set), and a gate that genuinely passed
// in an earlier round rendered in a later round as "should have reviewed
// this, but didn't" (rounds did not carry forward). Both are fixed in
// computeStatus() by resolving each gate through a single governing-entry
// rule that mirrors tools/ledger.sh's gate_passed_round / gate_latest_outcome
// (see cmd_compliance in ledger.sh). These tests exist so neither regresses
// invisibly again.
//
// No framework — same "no dependencies" bar tests/run.sh's own header sets
// for the rest of the kit. Plain assert + process.exit, run via `node` from
// tests/run.sh (which checks for `node` the same way it already checks for
// `python3`/`python`: graceful, loud skip if absent, never a silent one).
//
'use strict';
const assert = require('assert');
const path = require('path');

// app.js expects PIPELINE and LEDGERS as bare globals — in the generated
// dashboard HTML these are `const`s declared by dashboard.sh immediately
// above the inlined app.js source, in the same <script> tag. Reproduced here
// by setting them as Node globals before require(). app.js's own
// `module.exports` guard (see the bottom of that file) and the `typeof
// document !== "undefined"` guard around its boot() call are the ONLY
// changes made to app.js to make this possible — no rendering logic moved.
function freshPipeline() {
  return {
    matrix: {
      G1: { budgetMin: 10, T4: 'M' },
      G2: { budgetMin: 10, T4: 'M' }
    },
    gates: {
      G1: { persona: 'Scout' },
      G2: { persona: 'Peer' }
    }
  };
}

function load() {
  const p = require.resolve(path.join(__dirname, '..', 'tools', 'dashboard', 'app.js'));
  delete require.cache[p]; // each test gets a fresh module-level `records` array
  // A render test that throws before its own `delete global.document` leaves the
  // stub installed; the next load() then inherits it and a single failure
  // cascades into every test after it, masking the real cause (G5 Proof,
  // 2026-09-03). Clear the shared globals here so each test starts clean.
  delete global.document;
  global.PIPELINE = freshPipeline();
  global.LEDGERS = [];
  return require(p);
}

function gateRec(fields) {
  return Object.assign({
    type: 'gate', change: 'c', round: 1, gate: 'G1', tier: 'T4',
    outcome: 'pass', findings: 0, minutes: 5, date: '2026-01-01', confidence: 'fresh'
  }, fields);
}

let failures = 0;
function test(name, fn) {
  try { fn(); console.log('  PASS  ' + name); }
  catch (e) { failures++; console.log('  FAIL  ' + name); console.log('        ' + (e && e.message || e)); }
}

// ---------------------------------------------------------------- bug 1
test('same-round fail-then-pass does not trip anyFail (app.js computeStatus)', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c1', round: 1, gate: 'G1', outcome: 'fail', findings: 1 })),
    JSON.stringify(gateRec({ change: 'c1', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c1', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c1'; })[0];
  assert.ok(cg, 'change c1 was recorded');
  const ex = cg.rounds[0];
  const st = app.computeStatus(cg, ex, true);
  assert.strictEqual(st.gates.G1.outcome, 'pass', 'G1 resolves to the corrected pass, not the earlier fail');
  assert.strictEqual(st.status, 'Succeeded', 'a same-round correction must not leave the change Failed');
});

// G4/G5 r12 (blocking): "after" is the position in the ledger, like compliance. A fail logged with --round
// forgotten lands in the round-1 bucket, which sorts BEFORE the round-2 bucket holding the pass it must void.
test('a fail logged later with a lower round still voids an earlier higher-round pass', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c3', round: 1, gate: 'G2', outcome: 'pass', date: '2026-01-01' })),
    JSON.stringify(gateRec({ change: 'c3', round: 2, gate: 'G1', outcome: 'pass', date: '2026-01-02' })),
    JSON.stringify(gateRec({ change: 'c3', round: 1, gate: 'G1', outcome: 'fail', findings: 1, date: '2026-01-03' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c3'; })[0];
  const latest = cg.rounds[cg.rounds.length - 1];
  const st = app.computeStatus(cg, latest, true);
  assert.strictEqual(st.gates.G1.outcome, 'fail', 'the later fail governs, as in compliance');
});

// G1 r13: the pass that governs is the one at the HIGHEST ledger position, not the last visited in round order.
// round-2 pass, round-2 fail, then a round-1 pass logged last (--round forgotten on the re-run): the re-run passed.
test('a pass logged last at a lower round clears an earlier higher-round fail', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c4', round: 1, gate: 'G2', outcome: 'pass', date: '2026-01-01' })),
    JSON.stringify(gateRec({ change: 'c4', round: 2, gate: 'G1', outcome: 'pass', date: '2026-01-02' })),
    JSON.stringify(gateRec({ change: 'c4', round: 2, gate: 'G1', outcome: 'fail', findings: 1, date: '2026-01-03' })),
    JSON.stringify(gateRec({ change: 'c4', round: 1, gate: 'G1', outcome: 'pass', date: '2026-01-04' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c4'; })[0];
  const latest = cg.rounds[cg.rounds.length - 1];
  const st = app.computeStatus(cg, latest, true);
  assert.strictEqual(st.gates.G1.outcome, 'pass', 'the pass logged last governs, as in compliance');
});

// G5 r14: the FAIL that governs is the one at the highest ledger position too. round-2 fail, then a
// round-1 pass (re-run, --round forgotten), then a round-1 fail logged LAST: the gate is failing.
// Rounds are visited in DATE order, so the round-1 bucket (dated earlier) is walked first and the round-2
// fail last: without the position rule that last-visited fail shadowed the one logged last.
test('a fail logged last at a lower round governs over an earlier higher-round fail and a pass', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c5', round: 2, gate: 'G1', outcome: 'fail', findings: 1, date: '2026-01-05' })),
    JSON.stringify(gateRec({ change: 'c5', round: 1, gate: 'G1', outcome: 'pass', date: '2026-01-04' })),
    JSON.stringify(gateRec({ change: 'c5', round: 1, gate: 'G1', outcome: 'fail', findings: 2, date: '2026-01-04' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c5'; })[0];
  const latest = cg.rounds[cg.rounds.length - 1];
  const st = app.computeStatus(cg, latest, true);
  assert.strictEqual(st.gates.G1.outcome, 'fail', 'the open fail is shown as failing');
  assert.strictEqual(st.gates.G1.findings, 2, 'and it is the LAST fail by position that is reported');
});

// G5 r15: a gate logged BEFORE the first route belongs to lineage 1 (not a stray "earlier lineage 0" group).
test('a gate logged before the first route is lineage 1, never lineage 0', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c6', round: 1, gate: 'G1', outcome: 'fail', findings: 1, date: '2026-01-01' })),
    JSON.stringify({ type: 'route', change: 'c6', round: 1, base: 'aaaaaaa', predicted: 'T2', actual: 'T2', date: '2026-01-02' }),
    JSON.stringify({ type: 'route', change: 'c6', round: 1, base: 'bbbbbbb', predicted: 'T2', actual: 'T2', restart: true, date: '2026-01-03' })
  ] }]);
  const names = app.buildExecutions('p').map(function (g) { return g.change; });
  assert.ok(names.indexOf('c6') !== -1, 'the current lineage is listed');
  assert.ok(names.indexOf('c6 (earlier lineage 1)') !== -1, 'the earlier lineage is lineage 1');
  assert.ok(names.indexOf('c6 (earlier lineage 0)') === -1, 'there is no lineage 0');
});

// G5 r15: a change named after an Object.prototype method with length >= 2 must not read as having starts.
test('a change named __defineGetter__ is not split into a fake earlier lineage', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: '__defineGetter__', round: 1, gate: 'G1', outcome: 'pass', date: '2026-01-01' }))
  ] }]);
  const names = app.buildExecutions('p').map(function (g) { return g.change; });
  assert.deepStrictEqual(names, ['__defineGetter__']);
});

// G4 r16: a repeat firing's restart marker starts a lineage even when it is the ONLY round-1 route (the first
// firing was kept at round 2): what came before it is the earlier lineage, as in compliance.
test('a marked repeat firing that is the only round-1 route splits the change', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify({ type: 'route', change: 'c7', round: 2, base: 'aaaaaaa', predicted: 'T4', actual: 'T4', date: '2026-01-01' }),
    JSON.stringify({ type: 'route', change: 'c7', round: 2, base: 'aaaaaaa', predicted: 'T4', actual: 'T4', action: 'prod-deploy', evidence: 'u1', date: '2026-01-02' }),
    JSON.stringify(gateRec({ change: 'c7', round: 2, gate: 'G1', outcome: 'pass', date: '2026-01-03' })),
    JSON.stringify({ type: 'route', change: 'c7', round: 1, base: 'aaaaaaa', predicted: 'T4', actual: 'T4', action: 'prod-deploy', evidence: 'u2', restart: true, date: '2026-01-04' })
  ] }]);
  const groups = app.buildExecutions('p');
  const names = groups.map(function (g) { return g.change; });
  assert.ok(names.indexOf('c7 (earlier lineage 1)') !== -1, 'the first event is its own earlier lineage');
  const cur = groups.filter(function (g) { return g.change === 'c7'; })[0];
  assert.ok(cur && cur.rounds.every(function (r) { return r.gates.length === 0; }), 'its gate does not count for the new event');
});

// G5 r17: a gate logged before the ONLY round-1 route (not marked) is part of one lineage, not an earlier one.
test('a gate logged before an unmarked first route does not split the change', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c8', round: 1, gate: 'G1', outcome: 'pass', date: '2026-01-01' })),
    JSON.stringify({ type: 'route', change: 'c8', round: 1, base: 'aaaaaaa', predicted: 'T2', actual: 'T2', date: '2026-01-02' })
  ] }]);
  const names = app.buildExecutions('p').map(function (g) { return g.change; });
  assert.deepStrictEqual(names, ['c8']);
});

// G4/G5 r17: with the first firing kept at round 2 and TWO marked repeat firings after it, every event is its
// own lineage (the first start being a marker splits off what precedes it whatever the number of markers).
test('two marked repeat firings after a round-2 first firing give three lineages', function () {
  const app = load();
  const rt = function (round, ev, extra) {
    return JSON.stringify(Object.assign({ type: 'route', change: 'c9', round: round, base: 'aaaaaaa', predicted: 'T4', actual: 'T4', action: 'd', evidence: ev, date: '2026-01-01' }, extra || {}));
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    rt(2, 'u1'),
    JSON.stringify(gateRec({ change: 'c9', round: 2, gate: 'G4', outcome: 'pass', date: '2026-01-02' })),
    rt(1, 'u2', { restart: true }),
    JSON.stringify(gateRec({ change: 'c9', round: 1, gate: 'G4', outcome: 'pass', date: '2026-01-03' })),
    rt(1, 'u3', { restart: true })
  ] }]);
  const names = app.buildExecutions('p').map(function (g) { return g.change; }).sort();
  assert.deepStrictEqual(names, ['c9', 'c9 (earlier lineage 1)', 'c9 (earlier lineage 2)']);
});

// G4 r17: a route with no base never starts a lineage, even marked restart.
test('a baseless marked route does not start a lineage', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify({ type: 'route', change: 'c10', round: 1, base: 'aaaaaaa', predicted: 'T4', actual: 'T4', date: '2026-01-01' }),
    JSON.stringify(gateRec({ change: 'c10', round: 1, gate: 'G4', outcome: 'pass', date: '2026-01-02' })),
    JSON.stringify({ type: 'route', change: 'c10', round: 1, predicted: 'T1', actual: 'T1', restart: true, date: '2026-01-03' })
  ] }]);
  const names = app.buildExecutions('p').map(function (g) { return g.change; });
  assert.deepStrictEqual(names, ['c10']);
});

// G5 r18: a same-base round-1 re-run AFTER a restart is not a new start (the `!seen` clause): the gate logged
// between the restart and the re-run stays in the current lineage.
test('a same-base re-run after a restart does not open another lineage', function () {
  const app = load();
  const rt = function (base, extra) {
    return JSON.stringify(Object.assign({ type: 'route', change: 'c11', round: 1, base: base, predicted: 'T2', actual: 'T2', date: '2026-01-01' }, extra || {}));
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    rt('aaaaaaa'),
    JSON.stringify(gateRec({ change: 'c11', round: 1, gate: 'G1', outcome: 'pass', date: '2026-01-02' })),
    rt('bbbbbbb', { restart: true }),
    JSON.stringify(gateRec({ change: 'c11', round: 1, gate: 'G1', outcome: 'pass', date: '2026-01-03' })),
    rt('bbbbbbb')
  ] }]);
  const groups = app.buildExecutions('p');
  const names = groups.map(function (g) { return g.change; }).sort();
  assert.deepStrictEqual(names, ['c11', 'c11 (earlier lineage 1)']);
  const cur = groups.filter(function (g) { return g.change === 'c11'; })[0];
  assert.strictEqual(cur.rounds.reduce(function (n, r) { return n + r.gates.length; }, 0), 1, 'the gate logged after the restart is current');
});

// G7 r13: change names come from the ledger. A name that is also an Object.prototype member must not throw.
test('change names such as constructor and __proto__ do not break the dashboard', function () {
  const app = load();
  ['constructor', 'toString', 'hasOwnProperty', '__proto__'].forEach(function (name, i) {
    app.ingest([{ path: 'l' + i, project: 'p' + i, lines: [
      JSON.stringify({ type: 'route', change: name, round: 1, base: 'abc1234', predicted: 'T2', actual: 'T2', date: '2026-01-01' }),
      JSON.stringify(gateRec({ change: name, round: 1, gate: 'G1', outcome: 'pass' }))
    ] }]);
    const groups = app.buildExecutions('p' + i);
    assert.ok(Array.isArray(groups), 'buildExecutions survives the change name ' + name);
    // ... and the change is still THERE: on a plain object a name like __proto__ silently vanishes
    assert.ok(groups.some(function (g) { return g.change === name; }), 'the change ' + name + ' is listed');
  });
});

// ---------------------------------------------------------------- bug 2
test('a gate that passed in round 1 carries forward as a stale pass in round 2', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c2', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c2', round: 1, gate: 'G2', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c2', round: 2, gate: 'G2', outcome: 'pass', date: '2026-01-02' }))
    // G1 is NOT re-run in round 2 — it should still count, visibly dated.
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c2'; })[0];
  const round2 = cg.rounds.filter(function (r) { return r.round === 2; })[0];
  const st = app.computeStatus(cg, round2, true);
  assert.strictEqual(st.missing.indexOf('G1'), -1, 'G1 must not show as missing — it passed round 1');
  assert.ok(st.gates.G1, 'G1 has a resolved entry in round 2 status');
  assert.strictEqual(st.gates.G1.outcome, 'pass');
  assert.strictEqual(st.gates.G1._staleFromRound, 1, 'the carried-forward entry is marked with the round it actually passed at');
  assert.strictEqual(st.status, 'Succeeded', "round 2 is fully satisfied once G1's round-1 pass carries forward");
});

// A fail with no subsequent pass must keep failing forward across rounds —
// the self-contradiction the design review traced: a summary line claiming
// "nothing blocking was found" while an earlier round's blocking finding is,
// in fact, still unresolved.
test('a fail with no later pass keeps the change Failed in a later round', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c3', round: 1, gate: 'G1', outcome: 'fail', findings: 1 })),
    JSON.stringify(gateRec({ change: 'c3', round: 1, gate: 'G2', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c3', round: 2, gate: 'G2', outcome: 'pass', date: '2026-01-02' }))
    // G1 never re-run — its round-1 FAIL must still govern round 2.
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c3'; })[0];
  const round2 = cg.rounds.filter(function (r) { return r.round === 2; })[0];
  const st = app.computeStatus(cg, round2, true);
  assert.strictEqual(st.gates.G1.outcome, 'fail', "G1's unresolved round-1 fail must still govern");
  assert.strictEqual(st.status, 'Failed', 'a change with an unresolved fail is not Succeeded just because a later round did not touch that gate');
});

// E1 mirror: ledger.sh compliance stopped letting an older pass hide a LATER fail or
// skip. The dashboard says it mirrors compliance, so it must not show "Succeeded"
// for the same ledger compliance exits 1 on.
test('a later-round fail overrides an earlier pass in a round that did not re-run the gate', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c3b', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c3b', round: 2, gate: 'G1', outcome: 'fail', findings: 1, date: '2026-01-02' })),
    JSON.stringify(gateRec({ change: 'c3b', round: 3, gate: 'G2', outcome: 'pass', date: '2026-01-03' }))
    // round 3 does not re-run G1: its round-2 FAIL must still govern, not the round-1 pass.
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c3b'; })[0];
  const round3 = cg.rounds.filter(function (r) { return r.round === 3; })[0];
  const st = app.computeStatus(cg, round3, true);
  assert.strictEqual(st.gates.G1.outcome, 'fail', 'the later fail governs over the round-1 pass');
  assert.strictEqual(st.status, 'Failed');
});

test('a later skipped does NOT override an earlier pass (an exception record is not a failure)', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c3c', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c3c', round: 2, gate: 'G1', outcome: 'skipped', date: '2026-01-02' })),
    JSON.stringify(gateRec({ change: 'c3c', round: 3, gate: 'G2', outcome: 'pass', date: '2026-01-03' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c3c'; })[0];
  const round3 = cg.rounds.filter(function (r) { return r.round === 3; })[0];
  const st = app.computeStatus(cg, round3, true);
  assert.strictEqual(st.gates.G1.outcome, 'pass', 'a skip logged after a real pass must not revoke it');
});

// E1, round 4: a `skipped` logged AFTER a fail must not bring the older pass back (it is what the
// pre-push hook's override advice logs), and a `skipped` after a PASS in the SAME round must not
// replace it either -- compliance does neither, so the dashboard must not.
test('pass, then fail, then skipped: the fail still governs', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c3d', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c3d', round: 2, gate: 'G1', outcome: 'fail', findings: 1, date: '2026-01-02' })),
    JSON.stringify(gateRec({ change: 'c3d', round: 3, gate: 'G1', outcome: 'skipped', date: '2026-01-03' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c3d'; })[0];
  const round3 = cg.rounds.filter(function (r) { return r.round === 3; })[0];
  const st = app.computeStatus(cg, round3, true);
  assert.strictEqual(st.gates.G1.outcome, 'fail', 'a skip after a fail must not revive the round-1 pass');
});

test('pass then skipped in the same round: the pass governs', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c3e', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c3e', round: 1, gate: 'G1', outcome: 'skipped', date: '2026-01-01' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c3e'; })[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.strictEqual(st.gates.G1.outcome, 'pass', 'an exception record after a real pass must not replace it');
});

// ---------------------------------------------------------------- bug 3
// The Overview tab's headline used to key off gate OUTCOME ("did any gate's
// current governing entry fail?"), not finding SEVERITY. ledger.sh does not
// force outcome to "fail" when a finding is logged blocking (core/04-
// ledger.md documents that as a convention, not a code-enforced rule) — so a
// gate that found a blocking issue and got fixed within the same run can log
// outcome "pass" while its finding_details still carries the blocking entry.
// That gate reads as a plain pass, failN stays 0, and the old headline said
// "nothing blocking was found" one clause before "Show the numbers" listed
// "1 blocking, ..." for the same change — the self-contradiction this file's
// bug-2 fix already closed for cross-round fails, still open for this case.
test('a blocking finding fixed within the same gate run is not reported as "nothing blocking was found"', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({
      change: 'c4', round: 1, gate: 'G1', outcome: 'pass',
      finding_details: [{ id: 'c4-r1-G1-1', severity: 'blocking', location: 'src/x.js:1', claim: 'found and fixed within this run' }]
    })),
    JSON.stringify(gateRec({ change: 'c4', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c4'; })[0];
  const sum = app.changeSummary(cg);
  assert.strictEqual(sum.failN, 0, 'no gate is currently failing');
  assert.strictEqual(sum.bySev.blocking, 1, 'the blocking finding is still counted');
  assert.ok(sum.lead.indexOf('nothing blocking was found') === -1,
    'headline must not claim nothing blocking was found when a blocking finding was recorded: ' + sum.lead);
  assert.ok(/blocking/.test(sum.lead), 'headline must mention the blocking finding: ' + sum.lead);
});

// A change with a genuinely clean record (no blocking findings, ever) must
// still get the reassuring "nothing blocking was found" headline — the fix
// above must not make every change look suspicious.
test('a genuinely clean change still reads as "nothing blocking was found"', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c5', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c5', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c5'; })[0];
  const sum = app.changeSummary(cg);
  assert.strictEqual(sum.bySev.blocking, 0);
  assert.ok(sum.lead.indexOf('nothing blocking was found') !== -1, 'clean change should say nothing blocking was found: ' + sum.lead);
});

// ---------------------------------------------------------------- bug 4
// G8 dogfooding (real product, no diff/source given) found a second instance
// of bug 3's exact contradiction in a DIFFERENT function this repo's fix for
// bug 3 never touched: friendlyGateLine(), the per-reviewer row in "Who
// reviewed it". Same root cause — "nothing blocking" keyed off run.findings
// alone, not finding_details severity — just one level down from the
// page-level headline changeSummary() already fixed.
test('a reviewer row that resolved a blocking finding within its own run says so, not "nothing blocking" alone', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({
      change: 'c6', round: 1, gate: 'G1', outcome: 'pass', findings: 1,
      finding_details: [{ id: 'c6-r1-G1-1', severity: 'blocking', location: 'src/x.js:1', claim: 'found and fixed within this run' }]
    })),
    JSON.stringify(gateRec({ change: 'c6', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c6'; })[0];
  const ex = cg.rounds[0];
  const st = app.computeStatus(cg, ex, true);
  const line = app.friendlyGateLine('G1', st);
  assert.ok(/blocking issue/.test(line.sentence), 'per-reviewer row must name the blocking finding, not just say "nothing blocking": ' + line.sentence);
  assert.strictEqual(line.icon, '✅', 'the gate did resolve to a pass, so the icon should still be the checkmark: ' + line.icon);
});

// A currently-failing reviewer's headline used to report only the blocking
// count, silently dropping any additional non-blocking findings from the
// same run — a reader had to open Details to learn there was more than one
// note. G8 found this too, on real ledger data.
test('a failing reviewer row mentions additional non-blocking findings, not just the blocking count', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({
      change: 'c8', round: 1, gate: 'G1', outcome: 'fail', findings: 2,
      finding_details: [
        { id: 'c8-r1-G1-1', severity: 'blocking', location: 'src/x.js:1', claim: 'the real problem' },
        { id: 'c8-r1-G1-2', severity: 'minor', location: 'src/y.js:2', claim: 'a smaller note' }
      ]
    })),
    JSON.stringify(gateRec({ change: 'c8', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c8'; })[0];
  const ex = cg.rounds[0];
  const st = app.computeStatus(cg, ex, true);
  const line = app.friendlyGateLine('G1', st);
  assert.ok(/1 blocking problem/.test(line.sentence), 'must still lead with the blocking count: ' + line.sentence);
  assert.ok(/1 other note/.test(line.sentence), 'must also surface the additional non-blocking finding, not silently drop it: ' + line.sentence);
});

// A reviewer row with a genuinely clean pass (no blocking finding ever
// logged) must still read as reassuring — the fix above must not make every
// passing gate look suspicious.
test('a reviewer row with a genuinely clean pass still reads as reassuring', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c9', round: 1, gate: 'G1', outcome: 'pass', findings: 2 })),
    JSON.stringify(gateRec({ change: 'c9', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c9'; })[0];
  const ex = cg.rounds[0];
  const st = app.computeStatus(cg, ex, true);
  const line = app.friendlyGateLine('G1', st);
  assert.ok(/nothing blocking/.test(line.sentence), 'a genuinely clean pass with only non-blocking notes should still read as reassuring: ' + line.sentence);
});

// ---------------------------------------------------------------- timestamps + STAR narrative
//
// Two real, non-agent users looked at a generated dashboard and reported: (1)
// no timestamp anywhere — verdict and round count alone can't tell "yesterday"
// from "three months ago" — and (2) the Overview tab reads as broken, not as
// an honest gap, when a reason or a G1 note was never logged ("Reason not
// recorded" backed by a disclosure with nothing behind it). Both fixes below;
// see app.js's friendlyDate/friendlyIntent/friendlySituation and the rail's
// exec-date line.

function routeRec(fields) {
  return Object.assign({
    type: 'route', change: 'c', round: 1, date: '2026-01-01',
    reason: 'Feature', verdict: 'match', predicted: 'T1', actual: 'T1'
  }, fields);
}

// Built from the real clock, not a fixed fixture date, because friendlyDate()
// itself measures against Date.now() — a hardcoded "5 days ago" fixture would
// silently go stale (and start asserting the wrong bucket) the day this file
// is next read. Date.UTC throughout, matching friendlyDate()'s own UTC-only
// arithmetic, so this helper cannot disagree with the code under test over a
// timezone.
function isoDaysAgo(n) {
  var now = new Date();
  var t = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) - n * 86400000;
  var d = new Date(t);
  var mm = String(d.getUTCMonth() + 1).padStart(2, '0');
  var dd = String(d.getUTCDate()).padStart(2, '0');
  return d.getUTCFullYear() + '-' + mm + '-' + dd;
}

test('friendlyDate labels today and yesterday in words, not "0 days ago" / "1 days ago"', function () {
  const app = load();
  assert.strictEqual(app.friendlyDate(isoDaysAgo(0)), isoDaysAgo(0) + ' (today)');
  assert.strictEqual(app.friendlyDate(isoDaysAgo(1)), isoDaysAgo(1) + ' (yesterday)');
});

test('friendlyDate counts N days ago for anything older, on top of the raw ISO date', function () {
  const app = load();
  assert.strictEqual(app.friendlyDate(isoDaysAgo(5)), isoDaysAgo(5) + ' (5 days ago)');
});

test('friendlyDate shows a future-dated entry as the raw date, not a nonsensical negative "days ago"', function () {
  const app = load();
  const future = isoDaysAgo(-3);
  assert.strictEqual(app.friendlyDate(future), future, 'clock skew or a hand-built fixture — the date itself is still honest, a countdown is not');
});

test('friendlyDate shows an unparsable value verbatim instead of hiding it', function () {
  const app = load();
  assert.strictEqual(app.friendlyDate('not-a-date'), 'not-a-date');
  assert.strictEqual(app.friendlyDate(null), null);
});

// tools/ledger.sh writes a full UTC instant ("2026-08-14T17:53:03Z") for
// every new gate/route/escape record now, alongside the day-only
// ("2026-08-14") shape every pre-existing line still has and always will —
// see ledger.sh's header. Same real-clock construction as isoDaysAgo above,
// for the same reason: a fixed fixture goes stale the day this file is next
// read.
function isoDateTimeDaysAgo(n, hh, mm) {
  return isoDaysAgo(n) + 'T' + hh + ':' + mm + ':00Z';
}

test('friendlyDate shows a new-format timestamp with time of day, not a raw ISO string with T/Z', function () {
  const app = load();
  const iso = isoDateTimeDaysAgo(0, '17', '53');
  const rendered = app.friendlyDate(iso);
  assert.strictEqual(rendered, isoDaysAgo(0) + ' 17:53 UTC (today)');
  assert.strictEqual(/\d{2}T\d{2}|Z(\s|$)/.test(rendered), false, 'must not leak the raw ISO T/Z separators to a non-technical reader: ' + rendered);
});

test('friendlyDate ages a new-format timestamp the same way it ages a day-only record', function () {
  const app = load();
  const iso = isoDateTimeDaysAgo(3, '09', '05');
  assert.strictEqual(app.friendlyDate(iso), isoDaysAgo(3) + ' 09:05 UTC (3 days ago)');
});

test('friendlyDate never invents a time of day for an old, day-only record', function () {
  const app = load();
  const rendered = app.friendlyDate(isoDaysAgo(2));
  assert.strictEqual(rendered, isoDaysAgo(2) + ' (2 days ago)');
  assert.strictEqual(/\d\d:\d\d/.test(rendered), false, 'a day-only record must never render a fabricated clock time: ' + rendered);
});

test('a day-only record and a same-day timestamped record sort correctly relative to each other', function () {
  // buildExecutions() takes the max of ex.date across every record in a
  // round via plain string comparison (app.js lines 147-148) — this pins
  // that a full-instant value, which extends a day-only value with more
  // characters in the same left-to-right ISO order, always compares greater
  // than the bare day it shares, so the more precise record wins the max.
  const app = load();
  const day = isoDaysAgo(0);
  const dayTime = isoDateTimeDaysAgo(0, '08', '00');
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c20', round: 1, gate: 'G1', outcome: 'pass', date: day })),
    JSON.stringify(gateRec({ change: 'c20', round: 1, gate: 'G2', outcome: 'pass', date: dayTime }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c20'; })[0];
  const ex = cg.rounds[0];
  assert.strictEqual(ex.date, dayTime, 'the timestamped record should win the max-date comparison over the bare day it shares: ' + ex.date);
});

test('friendlyIntent explains a missing reason as a gap, not as "Reason not recorded"', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c10', round: 1, gate: 'G1', outcome: 'pass' }))
    // No route record and no context annotation — whyThisRan() resolves to null.
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c10'; })[0];
  const html = app.friendlyIntent(cg);
  assert.ok(html.indexOf('Reason not recorded') === -1,
    'the Overview tab must not reuse the Technical tab\'s terse chip fallback verbatim: ' + html);
  assert.ok(/still stands on its own/.test(html), 'must read as an honest gap, not a broken page: ' + html);
});

test('friendlyIntent states a logged reason as a full sentence, not a bare word', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'c11', round: 1, reason: 'Hardening' })),
    JSON.stringify(gateRec({ change: 'c11', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c11'; })[0];
  const html = app.friendlyIntent(cg);
  assert.ok(/The reason given: <b>Hardening<\/b>/.test(html), 'expected a full sentence naming the logged reason: ' + html);
});

test('friendlyIntent falls back to G1\'s note when no route reason was logged', function () {
  // whyThisRan() used to only ever resolve a route --reason (rarely set — see
  // tools/reconcile.sh's REASON env var, documented nowhere a user reading the
  // pipeline docs would find it) or a `type:"context"` ledger record that no
  // tool has ever emitted (grep every ledger.sh `emit(` call site: gate,
  // route, escape, assumption — no context). G1's note is the field the
  // mandatory-at-T3+ Intent gate already collects for exactly this question,
  // and friendlySituation() (below) already reads it — this pins whyThisRan()
  // reading it too, so "Why this happened" doesn't degrade to "not recorded"
  // for every change that followed the documented workflow without a
  // route --reason.
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c13', round: 1, gate: 'G1', outcome: 'pass', note: 'Requested by support to stop silent drops.' }))
    // No route record — the only path left to a "why" is G1's note.
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c13'; })[0];
  const html = app.friendlyIntent(cg);
  assert.ok(/The reason given: <b>Requested by support to stop silent drops\.<\/b>/.test(html),
    'expected the G1 note to surface as the reason: ' + html);
});

test('friendlyIntent still reports no reason when G1 ran but left no note', function () {
  // A G1 gate record with no `note` field must not accidentally satisfy the
  // fallback (e.g. via a falsy-but-defined empty string coerced true) — this
  // is the same fixture the "explains a missing reason as a gap" test above
  // uses, kept separate so a future change to the G1 fallback can't silently
  // make an empty note render as a reason without failing here.
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c14', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c14'; })[0];
  const html = app.friendlyIntent(cg);
  assert.ok(/still stands on its own/.test(html), 'a noteless G1 must still read as an honest gap: ' + html);
});

test('friendlySituation reinforces the date of the ROUND being viewed, not just the change\'s latest round', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c12', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(10) })),
    JSON.stringify(gateRec({ change: 'c12', round: 2, gate: 'G2', outcome: 'pass', date: isoDaysAgo(1) }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c12'; })[0];
  const round1 = cg.rounds.filter(function (r) { return r.round === 1; })[0];
  const round2 = cg.rounds.filter(function (r) { return r.round === 2; })[0];
  const html1 = app.friendlySituation(cg, round1);
  const html2 = app.friendlySituation(cg, round2);
  assert.ok(html1.indexOf('10 days ago') !== -1, 'round 1 must show round 1\'s own date: ' + html1);
  assert.ok(html2.indexOf('yesterday') !== -1, 'round 2 must show round 2\'s own date, not round 1\'s: ' + html2);
});

test('friendlySituation shows the time of day for a round logged with a new-format timestamp', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c21', round: 1, gate: 'G1', outcome: 'pass', date: isoDateTimeDaysAgo(0, '17', '53') }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c21'; })[0];
  const round1 = cg.rounds[0];
  const html = app.friendlySituation(cg, round1);
  assert.ok(html.indexOf('17:53 UTC') !== -1, 'a timestamped round should show its time of day: ' + html);
  assert.ok(html.indexOf('T17:53') === -1, 'must not leak the raw ISO T shape into the lead line: ' + html);
});

test('friendlySituation explains a missing G1 note as a gap, without a dead disclosure behind it', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c13', round: 1, gate: 'G2', outcome: 'skipped' }))
    // No G1 record at all for this change.
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c13'; })[0];
  const html = app.friendlySituation(cg, cg.rounds[0]);
  assert.strictEqual(html.indexOf('<details>'), -1, 'must not render a details toggle with nothing behind it');
  assert.ok(/still accurate/.test(html), 'must read as an honest gap, not a broken page: ' + html);
});

// ----------------------------------------------------------------- coverage
//
// Coverage is the ONE panel whose data is not derived from the ledger — it is
// git-derived and baked in at generation time. That makes grepping generated
// HTML for it especially worthless as proof (it shows only that a string was
// embedded), and it makes the stale case real: a live refetch can pull a ledger
// newer than the git facts baked beside it. These execute the actual render
// against crafted models.
function covEl() { return { className: '', innerHTML: '' }; }

function renderCovWith(coverage, ledgerLines) {
  const app = load();
  global.PIPELINE.coverage = coverage;
  global.PIPELINE.generated = '2026-08-15T00:00:00Z';
  const el = covEl();
  global.document = { getElementById: function (id) { return id === 'coverage' ? el : null; } };
  app.ingest([{ path: 'l', project: 'p', lines: ledgerLines || [] }]);
  app.renderCoverage();
  delete global.document;
  return el;
}

test('coverage panel reports unrouted T4 work and names the anchor', function () {
  const el = renderCovWith({
    anchor: 'abc1234', anchorClaimed: 'abc1234', commits: 2, scanned: 2,
    truncated: false, highest: 4,
    unrouted: [{ tier: 4, text: 'def5678 touched a trust boundary' }], neverRun: []
  });
  assert.ok(/bad/.test(el.className), 'T4 unrouted work should read as bad: ' + el.className);
  assert.ok(/2 commit/.test(el.innerHTML), 'must surface the total commits since the anchor: ' + el.innerHTML);
  assert.ok(/1 (commit|touching)/.test(el.innerHTML), 'must surface how many crossed the gated-surface line: ' + el.innerHTML);
  assert.ok(el.innerHTML.indexOf('abc1234') !== -1, 'must name the anchor it counted from');
  assert.ok(el.innerHTML.indexOf('def5678') !== -1, 'must list the unrouted commit');
});

test('coverage panel says all routed when there is nothing outstanding', function () {
  const el = renderCovWith({
    anchor: 'abc1234', anchorClaimed: 'abc1234', commits: 0, scanned: 0,
    truncated: false, highest: 0, unrouted: [], neverRun: []
  });
  assert.ok(/ok/.test(el.className), el.className);
  assert.ok(/All work routed/.test(el.innerHTML), el.innerHTML);
});

// "Not computed" and "clean" must never look the same — that ambiguity is the
// entire failure this panel exists to remove.
test('coverage panel distinguishes not-computed from clean', function () {
  const el = renderCovWith(null);
  assert.ok(/muted/.test(el.className), el.className);
  assert.ok(/not computed/i.test(el.innerHTML), el.innerHTML);
  assert.strictEqual(/All work routed/.test(el.innerHTML), false,
    'an uncomputed panel must never claim the pipeline is clean');
});

// A ledger may name a commit this clone has never seen. Reporting "0 since"
// there is the best-looking possible output and a lie.
test('coverage panel does not claim clean when the anchor is not in this repo', function () {
  const el = renderCovWith({
    anchor: '', anchorClaimed: 'deadbee', commits: 5, scanned: 5,
    truncated: false, highest: 3,
    unrouted: [{ tier: 3, text: 'aaa1111 shared surface' }], neverRun: []
  });
  assert.ok(el.innerHTML.indexOf('deadbee') !== -1, 'must name the anchor it could not resolve');
  assert.ok(/not a commit in this repository/.test(el.innerHTML), el.innerHTML);
});

test('coverage panel names gates that have never run', function () {
  const el = renderCovWith({
    anchor: 'abc1234', anchorClaimed: 'abc1234', commits: 0, scanned: 0,
    truncated: false, highest: 0, unrouted: [], neverRun: ['G2', 'G3']
  });
  assert.ok(/Never run/.test(el.innerHTML), el.innerHTML);
  assert.ok(el.innerHTML.indexOf('G2') !== -1 && el.innerHTML.indexOf('G3') !== -1, el.innerHTML);
});

// The live-mode honesty case: app.js refetches the ledger, but the git facts
// beside it cannot refresh in a browser. Say so rather than show a stale count.
test('coverage panel marks itself stale when the loaded ledger has moved past the baked anchor', function () {
  const el = renderCovWith({
    anchor: 'abc1234', anchorClaimed: 'abc1234', commits: 2, scanned: 2,
    truncated: false, highest: 4,
    unrouted: [{ tier: 4, text: 'def5678 trust boundary' }], neverRun: []
  }, [JSON.stringify(gateRec({ change: 'newer', commit: 'zzz9999' }))]);
  assert.ok(/out of date/.test(el.innerHTML),
    'a ledger newer than the baked anchor must be reported as stale: ' + el.innerHTML);
});

// G4 r11 (blocking): status.sh/coverage_anchor ignore a skipped or n/a gate row; the staleness check must too,
// or the panel says "regenerate" about a row that regenerating can never fold in.
test('coverage panel ignores a skipped or n/a gate row when judging staleness', function () {
  const el = renderCovWith({
    anchor: 'abc1234', anchorClaimed: 'abc1234', commits: 1, scanned: 1,
    truncated: false, highest: 4,
    unrouted: [{ tier: 4, text: 'def5678 trust boundary' }], neverRun: []
  }, [JSON.stringify(gateRec({ change: 'x', commit: 'abc1234' })),
      JSON.stringify(gateRec({ change: 'x', commit: 'zzz9999', outcome: 'skipped' })),
      JSON.stringify(gateRec({ change: 'y', commit: 'yyy8888', outcome: 'n/a' }))]);
  assert.strictEqual(/out of date/.test(el.innerHTML), false,
    'a skipped / n/a row must not make the panel stale: ' + el.innerHTML);
});

test('coverage panel does not say "not a commit in this repository" for gated commits that exist but are not reachable', function () {
  const el = renderCovWith({
    anchor: '', anchorClaimed: 'abc1234', anchorInRepo: true, commits: 4, scanned: 4,
    truncated: false, highest: 3,
    unrouted: [{ tier: 3, text: 'aaa1111 shared surface' }], neverRun: []
  });
  assert.strictEqual(/not a commit in this repository/.test(el.innerHTML), false, el.innerHTML);
  assert.ok(/none of them is reachable/.test(el.innerHTML), 'must explain why there is no anchor: ' + el.innerHTML);
});

// G4 r13 (blocking): two gated lines merged bake the anchor as "a, b"; comparing ONE sha with that joined
// string made the panel say "out of date" after every such merge. Membership over all of them instead.
test('coverage panel with several anchors is stale only when the newest gate is none of them', function () {
  const cov = {
    anchor: 'aaaaaaa1111, bbbbbbb2222', anchorClaimed: 'bbbbbbb2222', commits: 1, scanned: 1,
    truncated: false, highest: 0, unrouted: [], neverRun: []
  };
  const inList = renderCovWith(cov, [JSON.stringify(gateRec({ change: 'a', commit: 'aaaaaaa1111' })),
                                     JSON.stringify(gateRec({ change: 'b', commit: 'bbbbbbb2222' }))]);
  assert.strictEqual(/out of date/.test(inList.innerHTML), false,
    'a newest gate that IS one of the anchors is not stale: ' + inList.innerHTML);
  assert.ok(/commits? \(merged lines, each gated\)|reviewed commits/.test(inList.innerHTML),
    'several anchors are described in the plural: ' + inList.innerHTML);
  const moved = renderCovWith(cov, [JSON.stringify(gateRec({ change: 'a', commit: 'aaaaaaa1111' })),
                                    JSON.stringify(gateRec({ change: 'c', commit: 'ccccccc3333' }))]);
  assert.ok(/out of date/.test(moved.innerHTML),
    'a newest gate that is none of the anchors is stale: ' + moved.innerHTML);
});

test('coverage panel stays quiet about staleness when the ledger still matches the anchor', function () {
  const el = renderCovWith({
    anchor: 'zzz9999', anchorClaimed: 'zzz9999', commits: 0, scanned: 0,
    truncated: false, highest: 0, unrouted: [], neverRun: []
  }, [JSON.stringify(gateRec({ change: 'same', commit: 'zzz9999' }))]);
  assert.strictEqual(/out of date/.test(el.innerHTML), false,
    'an unmoved ledger must not be reported as stale: ' + el.innerHTML);
});

// The undercount case: the pre-push hook regenerates when the LEDGER moves, so
// commits landing with no gate logged leave the snapshot behind — exactly the
// situation the panel exists for. It must never read as a live number.
test('coverage panel always names the generation basis, even when it looks clean', function () {
  const el = renderCovWith({
    anchor: 'abc1234', anchorClaimed: 'abc1234', commits: 0, scanned: 0,
    truncated: false, highest: 0, unrouted: [], neverRun: []
  });
  assert.ok(/Counted when this page was generated/.test(el.innerHTML), el.innerHTML);
  assert.ok(/status\.sh/.test(el.innerHTML),
    'must point at the command that is always current: ' + el.innerHTML);
});

// A commit subject is attacker-controlled in a repo with untrusted
// contributors, and lands in innerHTML here.
test('coverage panel escapes a commit subject rather than injecting it as markup', function () {
  const el = renderCovWith({
    anchor: 'abc1234', anchorClaimed: 'abc1234', commits: 1, scanned: 1,
    truncated: false, highest: 4,
    unrouted: [{ tier: 4, text: 'aaa1111 <img src=x onerror=alert(1)>' }], neverRun: []
  });
  assert.strictEqual(el.innerHTML.indexOf('<img'), -1,
    'a crafted commit subject must not reach the DOM as a tag: ' + el.innerHTML);
  assert.ok(el.innerHTML.indexOf('&lt;img') !== -1, 'it should be escaped and still visible');
});

// ---------------------------------------------------------------- bug 5
// topFinding() sorts findings by SEV_RANK ascending so the worst (blocking,
// rank 0) is picked first — but `SEV_RANK[sev] || 9` treats rank 0 as falsy
// and silently substitutes 9 (worse than every real rank), so a blocking
// finding mixed with any other severity lost to a minor/info one. Found by
// executing topFinding() against real ledger data (product-intelligence-
// extension's G8 round 2 on catalog-extraction: 3 blocking + 2 minor), where
// the dashboard showed a minor finding as "what happened here" and hid the
// blocking ones — the opposite of this function's own header comment.
test('topFinding() picks a blocking finding over a minor one, even when blocking is not first in the array', function () {
  const app = load();
  const details = [
    { severity: 'info', claim: 'a' },
    { severity: 'minor', claim: 'b' },
    { severity: 'blocking', claim: 'the real problem' },
    { severity: 'minor', claim: 'c' }
  ];
  const top = app.topFinding(details);
  assert.strictEqual(top.severity, 'blocking', 'blocking (rank 0) must outrank minor/info, not lose to them: got ' + top.severity);
  assert.strictEqual(top.claim, 'the real problem');
});

// ---------------------------------------------------------------- loop history
// A gate that re-runs across several rounds (G6/G7 re-litigating the same
// diff is a routine real-world pattern, not an edge case) used to be
// completely invisible as a loop: "Who reviewed it" only ever showed the
// current governing pass, so a page-level headline like "16 blocking
// findings found and resolved" had no visible source — a reader could not
// find where the other findings went. gateOccurrences() + the loop note in
// friendlyGateLine() close that gap.
test('gateOccurrences returns every raw entry for a gate across all rounds, oldest first', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c10', round: 1, gate: 'G1', outcome: 'fail', findings: 1 })),
    JSON.stringify(gateRec({ change: 'c10', round: 1, gate: 'G2', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c10', round: 2, gate: 'G1', outcome: 'pass', date: '2026-01-02' })),
    JSON.stringify(gateRec({ change: 'c10', round: 2, gate: 'G2', outcome: 'pass', date: '2026-01-02' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c10'; })[0];
  const occ = app.gateOccurrences(cg, 'G1');
  assert.strictEqual(occ.length, 2, 'G1 ran twice across this change');
  assert.strictEqual(occ[0].run.outcome, 'fail');
  assert.strictEqual(occ[1].run.outcome, 'pass');
});

test('friendlyGateLine names the loop count when a gate ran more than once, and stays silent for a gate that only carried forward', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    // G1 is the one actually being re-reviewed round over round (a loop).
    JSON.stringify(gateRec({ change: 'c11', round: 1, gate: 'G1', outcome: 'fail', findings: 1 })),
    // G2 passes once in round 1 and is never logged again — it carries
    // forward into round 2 as a stale PASS*, which must NOT count as a loop:
    // gateOccurrences counts logged entries, not governance carry-forward.
    JSON.stringify(gateRec({ change: 'c11', round: 1, gate: 'G2', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c11', round: 2, gate: 'G1', outcome: 'pass', date: '2026-01-02' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c11'; })[0];
  const round2 = cg.rounds.filter(function (r) { return r.round === 2; })[0];
  const st = app.computeStatus(cg, round2, true);

  const g1Line = app.friendlyGateLine('G1', st, cg);
  assert.ok(/Checked 2 times/.test(g1Line.sentence), 'a gate that ran twice must say so: ' + g1Line.sentence);
  assert.ok(g1Line.loop && g1Line.loop.length === 2, 'loop history must be attached when the gate looped');

  const g2Line = app.friendlyGateLine('G2', st, cg);
  assert.ok(!/Checked/.test(g2Line.sentence), 'a gate that only carried forward (never re-run) must not claim a loop: ' + g2Line.sentence);
  assert.strictEqual(g2Line.loop, null, 'no loop history for a gate that was logged only once');

  const g1LineNoCg = app.friendlyGateLine('G1', st);
  assert.ok(!/Checked/.test(g1LineNoCg.sentence), 'omitting cg must not crash or fabricate a loop mention: ' + g1LineNoCg.sentence);
});

test('loopHistoryText lists one line per occurrence, oldest first, using the top-severity finding', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({
      change: 'c12', round: 1, gate: 'G1', outcome: 'fail', findings: 1,
      finding_details: [{ id: 'x1', severity: 'blocking', claim: 'first pass problem' }]
    })),
    JSON.stringify(gateRec({ change: 'c12', round: 1, gate: 'G2', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c12', round: 2, gate: 'G1', outcome: 'pass', date: '2026-01-02' })),
    JSON.stringify(gateRec({ change: 'c12', round: 2, gate: 'G2', outcome: 'pass', date: '2026-01-02' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c12'; })[0];
  const occ = app.gateOccurrences(cg, 'G1');
  const text = app.loopHistoryText(occ);
  const lines = text.split('\n');
  assert.strictEqual(lines.length, 2);
  assert.ok(/Round 1 \(fail\)/.test(lines[0]) && /first pass problem/.test(lines[0]), lines[0]);
  assert.ok(/Round 2 \(pass\)/.test(lines[1]), lines[1]);
});

// ================================================================ P0 review fixes
//
// From the 2026-09-01 four-persona dashboard review. Each test fails against
// the pre-fix logic and passes against the fix — see the review doc's P0
// table for the failure scenario each one locks down.

// P0-1 — rounds ordered by DATE, not round number. A real ledger carries
// non-sequential round numbers (concurrent sessions leaking a ROUND= var,
// re-used --round). Ordering by the number let changeSummary() call a stale
// high-numbered round "the final round" while a fresh failing gate sat above
// it, and the page headlined "nothing blocking was found" over a fail.
test('rounds sort by date; the newest-by-date round is "latest" even when its number is lower', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c40', round: 3, gate: 'G1', outcome: 'pass', date: isoDaysAgo(20) })),
    JSON.stringify(gateRec({ change: 'c40', round: 3, gate: 'G2', outcome: 'pass', date: isoDaysAgo(20) })),
    JSON.stringify(gateRec({ change: 'c40', round: 1, gate: 'G1', outcome: 'fail', findings: 1, date: isoDaysAgo(2),
      finding_details: [{ id: 'x', severity: 'blocking', location: 'a:1', claim: 'regressed' }] }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c40'; })[0];
  assert.strictEqual(cg.rounds[0].round, 3, 'the older event (by date) sorts first regardless of its higher number');
  assert.strictEqual(cg.rounds[cg.rounds.length - 1].round, 1, 'the newer event sorts last');
  assert.strictEqual(cg.latest, cg.rounds[cg.rounds.length - 1], 'latest is the newest by date, not the highest number');
  assert.strictEqual(cg.roundsSequential, false, 'round numbers {1,3} are flagged as non-sequential');
  const sum = app.changeSummary(cg);
  assert.ok(/found a problem/.test(sum.lead),
    'the headline must reflect the newest event (a failing gate), not the highest-numbered round: ' + sum.lead);
  assert.ok(sum.lead.indexOf('nothing blocking was found') === -1, sum.lead);
});

// Even when the numbers ARE 1..N, if a "round 2" was logged before its
// "round 1" the sequence reads backwards — flag it too, so the rail shows
// review-position instead of a confusing round order.
test('rounds numbered 1..N but logged out of date order are flagged non-sequential', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c46', round: 2, gate: 'G1', outcome: 'pass', date: isoDaysAgo(10) })),
    JSON.stringify(gateRec({ change: 'c46', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(3) }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c46'; })[0];
  assert.strictEqual(cg.rounds[0].round, 2, 'the earlier-dated record sorts first even though it is "round 2"');
  assert.strictEqual(cg.roundsSequential, false, 'numbers are {1,2} but out of chronological order — flagged');
});

// P0-2 / P0-3 — a required gate whose only record is "skipped" (or "n/a") is
// the ABSENCE of a verdict, not a pass. ledger.sh:26 says so; the dashboard
// used to render six skipped mandated gates as ✅ Success.
test('a required gate logged only as "skipped" is counted as missing, not satisfied', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c41', round: 1, gate: 'G1', outcome: 'skipped' })),
    JSON.stringify(gateRec({ change: 'c41', round: 1, gate: 'G2', outcome: 'skipped' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c41'; })[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.notStrictEqual(st.status, 'Succeeded', 'all-skipped mandated gates must not read as Success: ' + st.status);
  assert.ok(st.missing.indexOf('G1') !== -1 && st.missing.indexOf('G2') !== -1, 'both skipped gates are missing a verdict');
  assert.strictEqual(app.outcomeClass('G1', st), 'skipped', 'a skipped gate gets its own class, not the pass class');
});

test('a required gate logged only as "n/a" is not counted as a pass either', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c42', round: 1, gate: 'G1', outcome: 'n/a', note: 'does not fire here' })),
    JSON.stringify(gateRec({ change: 'c42', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c42'; })[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.ok(st.missing.indexOf('G1') !== -1, 'an n/a on a mandated gate is still a gap');
  assert.strictEqual(app.outcomeClass('G1', st), 'na');
});

// P0-4 — friendlyGateLine must not describe an n/a run as "checked and found
// nothing wrong". It did not check.
test('friendlyGateLine does not report an n/a run as a clean pass', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c43', round: 1, gate: 'G1', outcome: 'n/a', note: 'card does not fire here' })),
    JSON.stringify(gateRec({ change: 'c43', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c43'; })[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  const line = app.friendlyGateLine('G1', st);
  assert.ok(!/found nothing wrong|checked closely/.test(line.sentence),
    'an n/a run must not read as a completed clean review: ' + line.sentence);
  assert.ok(/not applicable|weigh in/i.test(line.sentence), 'it should say the review was not applicable: ' + line.sentence);
});

// P0-6 — a change with only route records (no gate has run) must not headline
// "Reviewed by 0 expert checks — nothing blocking was found".
test('changeSummary does not reassure about a change no gate has reviewed', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'c44', round: 1, verdict: 'match' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c44'; })[0];
  const sum = app.changeSummary(cg);
  assert.strictEqual(sum.totalGates, 0);
  assert.ok(/no gate has reviewed this/i.test(sum.lead),
    'zero gate runs must not render as "nothing blocking was found": ' + sum.lead);
});

// P0-7 — commits landing that no gate was MANDATED for must not read as
// "✅ All work routed" (which is a green light). status.sh says "Nothing
// above T2 — no gate is mandated"; the shared-library panel must agree.
test('coverage does not claim "All work routed" when commits landed below the gated-surface line', function () {
  const el = renderCovWith({
    anchor: 'abc1234', anchorClaimed: 'abc1234', commits: 3, scanned: 3,
    truncated: false, highest: 1, unrouted: [], neverRun: []
  });
  assert.strictEqual(/All work routed/.test(el.innerHTML), false,
    'commits since the anchor must not read as "all routed" just because none crossed T3: ' + el.innerHTML);
  assert.ok(/no gate is mandated/.test(el.innerHTML), 'should mirror status.sh wording: ' + el.innerHTML);
  assert.ok(/3 commit/.test(el.innerHTML), el.innerHTML);
});

test('coverage still says "All work routed" only when nothing at all landed since the anchor', function () {
  const el = renderCovWith({
    anchor: 'abc1234', anchorClaimed: 'abc1234', commits: 0, scanned: 0,
    truncated: false, highest: 0, unrouted: [], neverRun: []
  });
  assert.ok(/All work routed/.test(el.innerHTML), el.innerHTML);
  assert.ok(/ok/.test(el.className), el.className);
});

// P0-8 — every route record for a (change, round) is kept. A later "match"
// reconcile of a round must not overwrite that round's earlier "under"
// verdict — the miss the router exists to catch.
test('a later "match" reconcile does not hide a round\'s earlier "under" verdict', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'c45', round: 1, verdict: 'under', predicted: 'T1', actual: 'T4', date: '2026-01-01' })),
    JSON.stringify(gateRec({ change: 'c45', round: 1, gate: 'G1', outcome: 'pass', date: '2026-01-02' })),
    JSON.stringify(routeRec({ change: 'c45', round: 1, verdict: 'match', predicted: 'T4', actual: 'T4', date: '2026-01-03' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c45'; })[0];
  const ex = cg.rounds[0];
  assert.strictEqual(ex.routes.length, 2, 'both route records for the round are kept, not just the last');
  assert.strictEqual(ex.route.verdict, 'under', 'the governing route surfaces the under-classification');
  const st = app.computeStatus(cg, ex, true);
  assert.strictEqual(st.underClassified, true, 'computeStatus flags the under even after a later match reconcile');
});

test('pickRoute prefers an "under" verdict, then "over", then the most recent record', function () {
  const app = load();
  assert.strictEqual(app.pickRoute([{ verdict: 'match' }, { verdict: 'under' }, { verdict: 'match' }]).verdict, 'under');
  assert.strictEqual(app.pickRoute([{ verdict: 'match' }, { verdict: 'over' }]).verdict, 'over');
  assert.strictEqual(app.pickRoute([{ verdict: 'match', id: 1 }, { verdict: 'match', id: 2 }]).id, 2);
  assert.strictEqual(app.pickRoute([]), null);
});

// ================================================================ G4 · 2026-09-01
//
// Ripple-gate findings — regressions the P0 fixes introduced. Each fails
// against 97e3006 and passes against the fix.

// G4-B1 — pickRoute's "under wins" must not feed the effective tier. A round
// reconciled under->T3 then match->T4 still requires the T4 gates. (actualTier
// resolves by RECENCY, not maximum — see the c82 test below for the mirror;
// here recency and maximum happen to agree.)
test('actualTier follows the most recent reconcile, not pickRoute\'s "under" pick', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify({ type: 'route', change: 'c50', round: 1, date: '2026-01-01', verdict: 'under', predicted: 'T1', actual: 'T3' }),
    JSON.stringify({ type: 'route', change: 'c50', round: 1, date: '2026-01-02', verdict: 'match', predicted: 'T4', actual: 'T4' }),
    JSON.stringify(gateRec({ change: 'c50', round: 1, gate: 'G1', outcome: 'pass', date: '2026-01-02' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c50'; })[0];
  const ex = cg.rounds[0];
  assert.strictEqual(ex.route.verdict, 'under', 'the governing route still surfaces the under-classification');
  assert.strictEqual(app.actualTier(ex), 'T4', 'but the effective tier is the later "match" reconcile, T4');
});

// G4-B2 — an n/a on a CONDITIONAL matrix cell with a reason on record is
// honoured (matches ledger.sh cmd_compliance); an n/a without a reason, or on
// an unconditional cell, is still a gap.
test('computeStatus honours an n/a on a conditional cell with a reason, like ledger.sh does', function () {
  const app = load();
  global.PIPELINE = {
    matrix: { G1: { T4: 'M' }, G2: { T4: 'M⁵' } },   // G2's cell carries a footnote marker
    gates:  { G1: { persona: 'Scout' }, G2: { persona: 'Dogfood' } }
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c51', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c51', round: 1, gate: 'G2', outcome: 'n/a', note: 'Axis C is Invisible here — card does not fire' }))
  ] }]);
  let cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c51'; })[0];
  let st = app.computeStatus(cg, cg.rounds[0], true);
  assert.strictEqual(st.missing.indexOf('G2'), -1, 'a reasoned n/a on a conditional cell is not missing');
  assert.strictEqual(st.status, 'Succeeded');

  // same cell, no reason -> still a gap
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c52', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c52', round: 1, gate: 'G2', outcome: 'n/a' }))
  ] }]);
  cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c52'; })[0];
  st = app.computeStatus(cg, cg.rounds[0], true);
  assert.ok(st.missing.indexOf('G2') !== -1, 'a bare n/a with no reason is still a gap');
});

// ================================================================ G7 · 2026-09-01
//
// Threat-gate findings against c47f380. Each of these fails against that commit
// and passes against the fix — see security-reports/2026-09-01-dashboard-p0-
// review-fixes.md for the reproduction each one pins.

// G7-1 — a ledger reference that leaves the page's own directory is refused
// before it becomes a fetch. dashboard.sh's _relpath emitted "//host/x" from a
// path with a doubled slash, and live mode then loaded a DIFFERENT ORIGIN's
// response and rendered it as this project's gate record.
test('a ledger fetch reference that leaves the page origin or directory is refused', function () {
  const app = load();
  const base = 'http://victim.example/proj/.pipeline/dashboard.html';
  assert.strictEqual(app.ledgerRefIsSafe('ledger.jsonl', base), true, 'the normal case still fetches');
  assert.strictEqual(app.ledgerRefIsSafe('../ledger.jsonl', base), true, 'a climb inside the origin is fine');
  assert.strictEqual(app.ledgerRefIsSafe('//evil.example.com/ledger.jsonl', base), false, 'protocol-relative → another origin');
  assert.strictEqual(app.ledgerRefIsSafe('/ledger.jsonl', base), false, 'server-absolute → another project on a shared host');
  assert.strictEqual(app.ledgerRefIsSafe('http://evil.example.com/x', base), false, 'an absolute URL is not a ledger path');
  assert.strictEqual(app.ledgerRefIsSafe('data:,{}', base), false, 'fetch() resolves data: — the reference would be the payload');
  assert.strictEqual(app.ledgerRefIsSafe('', base), false);
  assert.strictEqual(app.ledgerRefIsSafe(null, base), false);
});

// G7-2 — a round number is ledger data, and this page accepts a ledger by
// drag-and-drop and (since fetchPath) over the network. Ordering rounds by date
// removed the `.map(Number)` that used to make a non-numeric round throw, so the
// raw value now reaches the rail; every render of it must be escaped.
test('a non-numeric round from a crafted ledger is escaped, not injected as markup', function () {
  const app = load();
  const PAY = '<img src=x onerror=alert(1)>';
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c47', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(4) })),
    JSON.stringify(gateRec({ change: 'c47', round: PAY, gate: 'G1', outcome: 'pass', date: isoDaysAgo(2) }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c47'; })[0];
  assert.ok(cg, 'the crafted ledger still ingests — the fix is escaping, not dropping the record');

  const railList = { innerHTML: '', addEventListener: function () {}, querySelectorAll: function () { return []; } };
  global.document = {
    getElementById: function (id) { return id === 'rail-list' ? railList : null; },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  // renderRail writes the rail and then drives panels that need a fuller DOM;
  // the rail HTML — the sink under test — is already written by then.
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }
  delete global.document;

  assert.strictEqual(railList.innerHTML.indexOf(PAY), -1,
    'the raw payload must never reach rail innerHTML: ' + railList.innerHTML);
  assert.ok(railList.innerHTML.indexOf('&lt;img') !== -1,
    'and it must still be SHOWN, escaped, not dropped: ' + railList.innerHTML);
});

// ================================================================ G6 · 2026-09-02
//
// Peer-gate findings against 515836f. The P0 pass taught computeStatus,
// outcomeClass, stateLines and friendlyGateLine that a skip is not a verdict —
// but left the two surfaces that PHRASE that verdict for a non-technical
// reader still reading `st.required` and `run.outcome` alone.

// G6-1 — the page's plain-English headline. computeStatus already refuses to
// call an all-skipped round Succeeded (see "a required gate logged only as
// 'skipped'" above), but changeSummary's lead still fell through to
// "Reviewed by N expert checks — nothing blocking was found": a review that
// did not happen found nothing, which is not the same claim, and it is the
// most prominent sentence on the Overview tab.
test('the headline does not say "nothing blocking was found" when no mandated gate returned a verdict', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c60', round: 1, gate: 'G1', outcome: 'skipped' })),
    JSON.stringify(gateRec({ change: 'c60', round: 1, gate: 'G2', outcome: 'skipped' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c60'; })[0];
  const sum = app.changeSummary(cg);
  assert.strictEqual(/nothing blocking was found/.test(sum.lead), false,
    'two skipped mandated gates must not read as a clean review: ' + sum.lead);
  assert.ok(/no verdict/.test(sum.lead), 'it should name the gap instead: ' + sum.lead);
  // and the clean case still reads clean
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c61', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c61', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const clean = app.changeSummary(app.buildExecutions('p').filter(function (c) { return c.change === 'c61'; })[0]);
  assert.ok(/nothing blocking was found/.test(clean.lead), clean.lead);
});

// G6-2 — the mirror of "computeStatus honours an n/a on a conditional cell
// with a reason". computeStatus counts that n/a as satisfied (missing is
// empty, status Succeeded) while friendlyGateLine still told the reader it
// "needs a reason on record" — with the reason sitting on the record. The two
// sentences appear on the same tab.
test('an n/a compliance honours is not also reported as a gap', function () {
  const app = load();
  global.PIPELINE = {
    matrix: { G1: { T4: 'M' }, G2: { T4: 'M⁵' } },   // G2's cell carries a footnote marker
    gates:  { G1: { persona: 'Scout' }, G2: { persona: 'Dogfood' } }
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c62', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c62', round: 1, gate: 'G2', outcome: 'n/a', note: 'Axis C is Invisible here' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c62'; })[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.strictEqual(st.missing.indexOf('G2'), -1, 'precondition: computeStatus honours this n/a');
  const line = app.friendlyGateLine('G2', st, cg);
  assert.strictEqual(/needs a reason on record/.test(line.sentence), false,
    'the reason IS on record — the page must not contradict its own status: ' + line.sentence);

  // an n/a on an UNCONDITIONAL mandated cell is still a gap, and still says so
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c63', round: 1, gate: 'G1', outcome: 'n/a', note: 'felt unnecessary' })),
    JSON.stringify(gateRec({ change: 'c63', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const cg2 = app.buildExecutions('p').filter(function (c) { return c.change === 'c63'; })[0];
  const st2 = app.computeStatus(cg2, cg2.rounds[0], true);
  assert.ok(st2.missing.indexOf('G1') !== -1, 'precondition: an n/a on an unconditional M is a gap');
  assert.ok(/needs a reason on record/.test(app.friendlyGateLine('G1', st2, cg2).sentence),
    'and that one must still be called out');
});

// ================================================================ G7 · round 2 · 2026-09-02
//
// The round-1 G7 pass swept `.round` — the field it happened to find — and
// stopped. `tokens` (the field P1-7 put in the drawer where `minutes` used to
// be), `severity` and `findings` are the same thing: raw ledger values,
// uncoerced between JSON.parse and a raw-string innerHTML sink, in a page that
// accepts a ledger by drag-and-drop and (since fetchPath) over the network.
test('crafted tokens/severity/findings are escaped in the drawer, not injected as markup', function () {
  const app = load();
  // renderDrawer renders the whole gate card before it reaches the sink under
  // test, so the stub PIPELINE needs the card fields it reads. All constants —
  // none of them is the value being tested.
  global.PIPELINE.spine = [];
  global.PIPELINE.gates.G1 = {
    id: 'G1', name: 'Scout', persona: 'Scout', question: 'q', input: 'the diff',
    withhold: '—', context: 'fresh', owns: 'o', does_not_own: 'd',
    output: 'out', passes_when: 'p', fails_when: 'f', escalate_to: 'e'
  };
  const TOK_PAY = '<img src=x onerror=alert(1)>';
  const SEV_ATTR = 'blocking" onmouseover="alert(2)';
  const SEV_TAG = '<svg onload=alert(3)>';
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({
      change: 'c70', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(1),
      tokens: TOK_PAY, findings: 2,
      finding_details: [
        { severity: SEV_ATTR, location: 'a.js:1', claim: 'one' },
        { severity: SEV_TAG, location: 'b.js:2', claim: 'two' }
      ]
    }))
  ] }]);

  const inner = { innerHTML: '' };
  const drawer = { className: '', querySelector: function () { return inner; } };
  global.document = {
    getElementById: function (id) { return id === 'drawer' ? drawer : null; },
    querySelectorAll: function () { return []; }
  };
  app._selectExec('p', 'c70', 1, 'G1');
  // renderDrawer writes the panel and only then wires its close button, which
  // needs an element this shim does not have; the sink under test is already
  // written by that point. Same pattern as the renderRail test above.
  try { app.renderDrawer(); } catch (e) { /* close-button wiring only */ }
  delete global.document;

  assert.strictEqual(inner.innerHTML.indexOf(TOK_PAY), -1,
    'a crafted "tokens" must not reach drawer innerHTML raw: ' + inner.innerHTML);
  assert.strictEqual(inner.innerHTML.indexOf(SEV_TAG), -1,
    'a crafted "severity" must not reach drawer innerHTML raw: ' + inner.innerHTML);
  assert.strictEqual(inner.innerHTML.indexOf('class="finding blocking" onmouseover='), -1,
    'and must not break out of the class attribute: ' + inner.innerHTML);
  assert.ok(inner.innerHTML.indexOf('&lt;img') !== -1,
    'the tokens value is still SHOWN, escaped, not dropped: ' + inner.innerHTML);
  assert.ok(inner.innerHTML.indexOf('&lt;svg') !== -1,
    'the severity value is still SHOWN, escaped, not dropped: ' + inner.innerHTML);
});

// ================================================================ G4/G8 round 2 · 2026-09-02

// G8-blocking — the drawer headline and the graph box must not disagree about
// the same gate/round. A round with a fail then a same-round pass for one gate:
// computeStatus governs it as the pass; the drawer used to headline the FIRST
// raw entry (the fail).
test('renderDrawer shows the governing (last) entry for a gate, not the first', function () {
  const app = load();
  global.PIPELINE.spine = [];
  global.PIPELINE.gates.G1 = {
    id: 'G1', name: 'Scout', persona: 'Scout', question: 'q', input: 'i', withhold: '—',
    context: 'c', owns: 'o', does_not_own: 'd', output: 'out', passes_when: 'p', fails_when: 'f', escalate_to: 'e'
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c80', round: 1, gate: 'G1', outcome: 'fail', findings: 3, date: '2026-01-01' })),
    JSON.stringify(gateRec({ change: 'c80', round: 1, gate: 'G1', outcome: 'pass', findings: 0, date: '2026-01-01' }))
  ] }]);
  const inner = { innerHTML: '' };
  const drawer = { className: '', querySelector: function () { return inner; } };
  global.document = { getElementById: function (id) { return id === 'drawer' ? drawer : null; }, querySelectorAll: function () { return []; } };
  app._selectExec('p', 'c80', 1, 'G1');
  try { app.renderDrawer(); } catch (e) { /* close-button wiring only */ }
  delete global.document;
  assert.ok(/outcome<\/span><b>pass<\/b>/.test(inner.innerHTML),
    'the drawer must headline the governing pass, not the superseded fail: ' + inner.innerHTML.slice(0, 400));
});

// G6/G8 — a stray entry logged into an early round's bucket long after the fact
// must not drag that round past a later one that finished first.
test('rounds order by when they started, not by a straggler entry logged later', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    // round 1: a real pass on the 1st
    JSON.stringify(gateRec({ change: 'c81', round: 1, gate: 'G1', outcome: 'pass', date: '2026-03-01T09:00:00Z' })),
    JSON.stringify(gateRec({ change: 'c81', round: 1, gate: 'G2', outcome: 'pass', date: '2026-03-01T09:00:00Z' })),
    // round 2: a real pass on the 2nd
    JSON.stringify(gateRec({ change: 'c81', round: 2, gate: 'G1', outcome: 'pass', date: '2026-03-02T09:00:00Z' })),
    // ...then a skip logged BACK INTO round 1 on the 5th, to note something
    JSON.stringify(gateRec({ change: 'c81', round: 1, gate: 'G2', outcome: 'skipped', date: '2026-03-05T09:00:00Z' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c81'; })[0];
  assert.strictEqual(cg.rounds[0].round, 1, 'round 1 started first and still sorts first');
  assert.strictEqual(cg.rounds[cg.rounds.length - 1].round, 2, 'round 2 is latest — the straggler in round 1 does not move it');
  assert.strictEqual(cg.latest.round, 2);
});

// G4 minor — actualTier follows recency, not maximum: a route corrected DOWN
// is reachable (the ledger is append-only, so a max rule would pin the old one
// forever). The P0-8 case (under->T3 then match->T4) still resolves T4.
test('actualTier uses the most recent route, so a correction downward takes effect', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify({ type: 'route', change: 'c82', round: 1, date: '2026-01-01', verdict: 'match', predicted: 'T4', actual: 'T4' }),
    JSON.stringify({ type: 'route', change: 'c82', round: 1, date: '2026-01-02', verdict: 'over', predicted: 'T4', actual: 'T2' }),
    JSON.stringify(gateRec({ change: 'c82', round: 1, gate: 'G1', outcome: 'pass', date: '2026-01-02' }))
  ] }]);
  const ex = app.buildExecutions('p').filter(function (c) { return c.change === 'c82'; })[0].rounds[0];
  assert.strictEqual(app.actualTier(ex), 'T2', 'the later "over" correction to T2 wins over the earlier T4');
});

// G4 minor — cellIsConditional matches matrix.sh's residual-strip, so a 6th
// footnote does not silently diverge the dashboard from ledger.sh compliance.
test('cellIsConditional treats any leftover marker as conditional, not just the five that exist today', function () {
  const app = load();
  global.PIPELINE = { matrix: { G1: { T4: 'M' }, G2: { T4: 'M⁶' }, G3: { T4: 'M (hard)' } }, gates: { G1: { persona: 'a' }, G2: { persona: 'b' }, G3: { persona: 'c' } } };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c83', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c83', round: 1, gate: 'G2', outcome: 'n/a', note: 'sixth footnote applies' })),
    JSON.stringify(gateRec({ change: 'c83', round: 1, gate: 'G3', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c83'; })[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.strictEqual(st.missing.indexOf('G2'), -1, 'M⁶ is a conditional cell; a reasoned n/a on it is honoured');
});

// G8 round 3 — the rail's per-round date must be the round's START (the key
// rows are sorted by), not its latest entry, or a round whose bucket caught a
// late straggler shows a newer date than the round listed below it.
test('the rail shows a round by its start date, so the dates never contradict the row order', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c95', round: 1, gate: 'G1', outcome: 'pass', date: '2026-05-01T09:00:00Z' })),
    JSON.stringify(gateRec({ change: 'c95', round: 2, gate: 'G1', outcome: 'pass', date: '2026-05-02T09:00:00Z' })),
    // straggler back into round 1, dated AFTER round 2
    JSON.stringify(gateRec({ change: 'c95', round: 1, gate: 'G2', outcome: 'skipped', date: '2026-05-09T09:00:00Z' }))
  ] }]);
  const railList = { innerHTML: '', addEventListener: function () {}, querySelectorAll: function () { return []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? railList : null; }, querySelectorAll: function () { return []; } };
  app._selectProject('p');
  try { app.renderRail(); } catch (e) { /* downstream panels */ }
  delete global.document;
  const i1 = railList.innerHTML.indexOf('2026-05-01');
  const i2 = railList.innerHTML.indexOf('2026-05-02');
  assert.ok(i1 !== -1 && i2 !== -1, 'both start dates render: ' + railList.innerHTML);
  assert.ok(i1 < i2, 'round 1 (started 05-01) is shown above round 2 (started 05-02), dates in order');
  assert.strictEqual(railList.innerHTML.indexOf('2026-05-09'), -1, 'the straggler date is not what the round shows');
});

// G8 round 6 — "last commit reviewed" is the NEWEST commit a gate in the final
// round looked at, not gates[0]'s: ledger-append order is not always round
// order (a re-logged entry), so gates[0] can name an older commit.
test('renderOutput reports the newest commit reviewed in the final round, not the first-logged', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c97', round: 1, gate: 'G2', outcome: 'pass', commit: 'newer99', date: '2026-06-02T10:00:00Z' })),
    JSON.stringify(gateRec({ change: 'c97', round: 1, gate: 'G1', outcome: 'pass', commit: 'older11', date: '2026-06-01T10:00:00Z' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c97'; })[0];
  const html = app.renderOutput(cg);
  assert.ok(html.indexOf('newer99') !== -1, 'shows the later-dated gate\'s commit: ' + html);
  assert.strictEqual(html.indexOf('older11'), -1, 'not the first-logged gate\'s: ' + html);
});

// G8 round 5 — the rail row and the "What was being reviewed" panel must date
// a round the same way (its START), or a round whose entries straddle midnight
// UTC shows "yesterday" in the rail and "today" in the panel.
test('friendlySituation dates a round by its start, matching the rail row', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c96', round: 1, gate: 'G1', outcome: 'pass', date: '2026-04-10T23:40:00Z' })),
    JSON.stringify(gateRec({ change: 'c96', round: 1, gate: 'G2', outcome: 'pass', date: '2026-04-11T00:20:00Z' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c96'; })[0];
  const html = app.friendlySituation(cg, cg.rounds[0]);
  assert.ok(html.indexOf('2026-04-10') !== -1, 'the panel dates the round by its first entry (04-10), like the rail: ' + html);
  assert.strictEqual(html.indexOf('2026-04-11'), -1, 'not by its last activity (04-11)');
});

// G8 round 4 — the footer legend's lead word must track the header pill. It is
// static HTML reading "Snapshot." at generation; over http once a fetch lands
// the page is genuinely live, and having both on screen contradicted.
test('the footer legend switches from "Snapshot" to "Live" when live mode succeeds', function () {
  const app = load();
  const pill = { textContent: '', className: '' };
  const legend = { innerHTML: '<b>Snapshot.</b> Regenerate with ...' };
  global.document = { getElementById: function (id) {
    return id === 'live-status' ? pill : (id === 'legend-mode' ? legend : null);
  } };
  app.renderLiveStatus();
  assert.ok(/Snapshot\./.test(legend.innerHTML), 'starts on Snapshot: ' + legend.innerHTML);
  app._setLiveSucceeded(true);
  app.renderLiveStatus();
  assert.ok(/<b>Live\.<\/b>/.test(legend.innerHTML), 'switches to Live once a fetch lands: ' + legend.innerHTML);
  assert.strictEqual(/<b>Snapshot\.<\/b>/.test(legend.innerHTML), false, 'and drops the Snapshot lead');
  delete global.document;
});

// ================================================================ G6 round 3 · 2026-09-02
// The mirror of bug 1: a gate that PASSED then FAILED in the same round. The
// fail is the later fact, so the graph box, the drawer and changeSummary must
// all read it as a fail — the round-2 drawer fix taught only the fail->pass
// direction, leaving pass->fail still governed by "any pass in the round wins".
test('a same-round pass-then-fail governs as a fail everywhere, not a stale pass', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c90', round: 1, gate: 'G1', outcome: 'pass', findings: 0, date: '2026-01-01T09:00:00Z' })),
    JSON.stringify(gateRec({ change: 'c90', round: 1, gate: 'G1', outcome: 'fail', findings: 2, date: '2026-01-01T15:00:00Z' })),
    JSON.stringify(gateRec({ change: 'c90', round: 1, gate: 'G2', outcome: 'pass', date: '2026-01-01T09:00:00Z' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c90'; })[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.strictEqual(st.gates.G1.outcome, 'fail', 'the later fail governs, not the earlier pass');
  assert.strictEqual(st.status, 'Failed');
  const sum = app.changeSummary(cg);
  assert.ok(/found a problem/.test(sum.lead), 'the headline reflects the fail: ' + sum.lead);
});

// ...and the original fail-then-pass correction still resolves to a pass —
// the fix must not swing the other way.
test('a same-round fail-then-pass still governs as the corrected pass', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c91', round: 1, gate: 'G1', outcome: 'fail', findings: 2, date: '2026-01-01T09:00:00Z' })),
    JSON.stringify(gateRec({ change: 'c91', round: 1, gate: 'G1', outcome: 'pass', findings: 0, date: '2026-01-01T15:00:00Z' })),
    JSON.stringify(gateRec({ change: 'c91', round: 1, gate: 'G2', outcome: 'pass', date: '2026-01-01T09:00:00Z' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'c91'; })[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.strictEqual(st.gates.G1.outcome, 'pass');
  assert.strictEqual(st.status, 'Succeeded');
});

// ---------------------------------------------------------------- P1-5: branch-name pseudo-changes
//
// reconcile.sh defaults --change to the current branch name, so a run on a
// trunk branch with no CHANGE= set writes route records named "master". Those
// collect reconciles from many unrelated changes and never get gates — the
// rail used to render one as a change where every mandated gate "should have
// reviewed this, but didn't". ledger.sh now refuses these at write time; this
// is the read-side guard for ledgers written before that.

test('a branch-named group with only route records is tagged a routing artifact', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'master', round: 1, date: '2026-01-01' })),
    JSON.stringify(routeRec({ change: 'master', round: 1, date: '2026-01-05' })),
    JSON.stringify(gateRec({ change: 'real-change', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }]);
  const all = app.buildExecutions('p');
  const master = all.filter(function (c) { return c.change === 'master'; })[0];
  const real = all.filter(function (c) { return c.change === 'real-change'; })[0];
  assert.strictEqual(master.isRoutingArtifact, true, '"master" with no gates is an artifact');
  assert.strictEqual(real.isRoutingArtifact, false, 'a real change is not');
  // artifacts sort AFTER real changes regardless of date
  assert.ok(all.indexOf(real) < all.indexOf(master), 'the artifact sorts last');
});

// Not just "master" — the whole changeIsBranchy list must drive the read-side
// guard, or a legacy ledger's `development` / `dev` / `trunk` pseudo-changes
// still render as gate-skippers (G5 Proof: the app.js list was untested).
test('every changeIsBranchy name drives the routing-artifact tag', function () {
  ['main', 'develop', 'development', 'dev', 'trunk', 'HEAD', 'unknown'].forEach(function (name) {
    const app = load();
    app.ingest([{ path: 'l', project: 'p', lines: [
      JSON.stringify(routeRec({ change: name, round: 1 }))
    ] }]);
    const cg = app.buildExecutions('p').filter(function (c) { return c.change === name; })[0];
    assert.strictEqual(cg.isRoutingArtifact, true, name + ' with no gates must be a routing artifact');
  });
});

test('a branch-named group WITH a gate record is a real change, not an artifact', function () {
  const app = load();
  // branch-per-change workflow: the branch is named for the change, gates land under it
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'main', round: 1 })),
    JSON.stringify(gateRec({ change: 'main', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'main'; })[0];
  assert.strictEqual(cg.isRoutingArtifact, false, 'a branch name with real gates is a real change');
});

test('a branch-named group with a declared --action route is NOT an artifact', function () {
  const app = load();
  // a store publish happens from the trunk; reconcile.sh names the record for
  // the action, but an old ledger could still carry change:"master" here. An
  // --action route is a deliberate declared event, not a stray reconcile.
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'master', round: 1, action: 'store-publish', evidence: 'https://x', predicted: 'T4', actual: 'T4' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'master'; })[0];
  assert.strictEqual(cg.isRoutingArtifact, false, 'a declared action route is a real event');
});

test('routing artifacts are excluded from computeProjectMetrics.changeCount', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'master', round: 1 })),
    JSON.stringify(gateRec({ change: 'c-a', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'c-b', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }]);
  assert.strictEqual(app.computeProjectMetrics('p').changeCount, 2, 'only c-a and c-b count');
});

// The whole point of the guard is the RENDER: a routing artifact must not get a
// verdict pill or a selectable exec row (which is what would carry the gate-gap
// warning once opened), and the real change beside it must be unaffected.
test('renderRail shows a routing artifact muted, with no verdict row', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'master', round: 1, predicted: 'T4', actual: 'T4' })),
    JSON.stringify(routeRec({ change: 'master', round: 1, predicted: 'T4', actual: 'T4' })),
    JSON.stringify(gateRec({ change: 'real-one', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }]);
  const railList = { innerHTML: '', addEventListener: function () {}, querySelectorAll: function () { return []; } };
  global.document = {
    getElementById: function (id) { return id === 'rail-list' ? railList : null; },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }
  delete global.document;
  const h = railList.innerHTML;
  assert.ok(/routing-artifact/.test(h), 'the artifact row carries its muted class');
  assert.ok(/2 stray reconcile records/.test(h), 'explained, counting both route records');
  // an exec-row (data-change="…") is the selectable unit that opens the gate
  // graph + status lines. The artifact produces none for itself; the real
  // change does, with its verdict pill.
  assert.strictEqual(/data-change="master"/.test(h), false, 'the artifact is not a selectable exec row');
  assert.ok(/data-change="real-one"/.test(h), 'the real change still renders as an exec row');
  assert.ok(/verdict-pill/.test(h), 'and keeps its verdict pill (the artifact has none)');
  // the artifact sorts last, so everything before the routing-artifact div is
  // the real change and nothing after it carries a verdict.
  assert.strictEqual(/verdict-pill/.test((h.split('routing-artifact')[1]) || ''), false,
    'no verdict pill anywhere in or after the artifact block');
});

// ================================================================ P1 readability pass · 2026-09-03
//
// The remaining items from §7 of the 2026-09-01 four-persona review. Each is a
// piece of ledger data the page ingested and then dropped, or a check the kit's
// own docs retired that app.js still shipped.

// ---- P1-6 · confidence:"self" / "high" are self-checks, not independent ----
//
// core/04-ledger.md's vocabulary is `fresh` or `low`. Two real ledgers carry
// `self` and `high` (both meaning "the author graded their own work"); the page
// rendered them as full-confidence independent passes and counted them in
// NEITHER stat bucket. isIndependent() keys on the one trustworthy value.
test('isIndependent is true only for "fresh"', function () {
  const app = load();
  assert.strictEqual(app.isIndependent('fresh'), true);
  ['low', 'self', 'high', '', undefined, 'anything'].forEach(function (v) {
    assert.strictEqual(app.isIndependent(v), false, JSON.stringify(v) + ' is not an independent review');
  });
});

test('a self/high confidence run counts as a self-check, not a fresh run', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c-conf', round: 1, gate: 'G1', outcome: 'pass', confidence: 'fresh' })),
    JSON.stringify(gateRec({ change: 'c-conf', round: 1, gate: 'G2', outcome: 'pass', confidence: 'high' })),
    JSON.stringify(gateRec({ change: 'c-conf', round: 1, gate: 'G1', outcome: 'pass', confidence: 'self', round: 2, date: '2026-01-02' }))
  ] }]);
  const m = app.computeProjectMetrics('p');
  assert.strictEqual(m.freshRuns, 1, 'only the confidence:"fresh" run is a fresh run');
  assert.strictEqual(m.selfCheckRuns, 2, 'the "high" and "self" runs are self-checks');
});

test('outcomeClass hatches a non-fresh pass the same as a low-confidence one', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c-cc', round: 1, gate: 'G1', outcome: 'pass', confidence: 'self' })),
    JSON.stringify(gateRec({ change: 'c-cc', round: 1, gate: 'G2', outcome: 'pass', confidence: 'fresh' }))
  ] }]);
  const cg = app.buildExecutions('p')[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.ok(/\blow\b/.test(app.outcomeClass('G1', st)), 'the self-check pass is marked low: ' + app.outcomeClass('G1', st));
  assert.strictEqual(/\blow\b/.test(app.outcomeClass('G2', st)), false, 'the fresh pass is not');
});

// ---- P1-7 · minutes budget retired, tokens shown ----
test('computeProjectMetrics reports tokens and drops the minutes-overrun count', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c-tok', round: 1, gate: 'G1', outcome: 'fail', findings: 2, tokens: 100000, minutes: 999 })),
    JSON.stringify(gateRec({ change: 'c-tok', round: 1, gate: 'G2', outcome: 'pass', tokens: 40000, minutes: 999 }))
  ] }]);
  const m = app.computeProjectMetrics('p');
  assert.strictEqual(m.totalTokens, 140000);
  assert.strictEqual(m.tokensPerFinding, 70000, '140000 tokens / 2 findings');
  assert.strictEqual('overrunCount' in m, false, 'the minutes-based overrun count is gone');
});

test('computeStatus no longer carries an "overran" flag', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c-ov', round: 1, gate: 'G1', outcome: 'pass', minutes: 9999 }))
  ] }]);
  const cg = app.buildExecutions('p')[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.strictEqual('overran' in st, false);
});

test('the drawer shows tokens, not "minutes vs budget"', function () {
  const app = load();
  global.PIPELINE.spine = [];
  global.PIPELINE.gates.G1 = {
    id: 'G1', name: 'Scout', persona: 'Scout', question: 'q', input: 'i', withhold: '—',
    context: 'c', owns: 'o', does_not_own: 'd', output: 'out', passes_when: 'p', fails_when: 'f', escalate_to: 'e'
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'c-dr', round: 1, gate: 'G1', outcome: 'pass', tokens: 123456, minutes: 7 }))
  ] }]);
  const inner = { innerHTML: '' };
  const drawer = { className: '', querySelector: function () { return inner; } };
  global.document = { getElementById: function (id) { return id === 'drawer' ? drawer : null; }, querySelectorAll: function () { return []; } };
  app._selectExec('p', 'c-dr', 1, 'G1');
  try { app.renderDrawer(); } catch (e) { /* close-button wiring only */ }
  delete global.document;
  assert.strictEqual(/minutes vs budget/.test(inner.innerHTML), false, 'the retired minutes row is gone');
  assert.strictEqual(/budget-bar/.test(inner.innerHTML), false, 'and its progress bar');
  assert.ok(/<span>tokens<\/span><b>123,456<\/b>/.test(inner.innerHTML), 'tokens shown, grouped: ' + inner.innerHTML);
});

// ---- P1-2 · the page-level summary bar ----
test('railSummary counts changes by latest-round status, excluding routing artifacts', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    // a failing change
    JSON.stringify(gateRec({ change: 'f1', round: 1, gate: 'G1', outcome: 'fail', findings: 1 })),
    // a succeeded change
    JSON.stringify(gateRec({ change: 's1', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 's1', round: 1, gate: 'G2', outcome: 'pass' })),
    // a running change (mandated gate with no verdict, latest round)
    JSON.stringify(gateRec({ change: 'r1', round: 1, gate: 'G1', outcome: 'pass' })),
    // a routing artifact — must not count
    JSON.stringify(routeRec({ change: 'master', round: 1 })),
    // an escape naming f1
    JSON.stringify({ type: 'escape', change: 'f1', found_by: 'user', severity: 'high', date: '2026-01-02' })
  ] }]);
  const sm = app.railSummary('p');
  assert.strictEqual(sm.by.total, 3, 'three real changes, master excluded');
  assert.strictEqual(sm.by.Failed, 1);
  assert.strictEqual(sm.by.Running, 1);
  assert.strictEqual(sm.escapeChangeCount, 1);
  assert.strictEqual(sm.escapeChanges.f1, true);
});

test('a rail filter narrows the rail to the matching changes', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'fails-here', round: 1, gate: 'G1', outcome: 'fail', findings: 1 })),
    JSON.stringify(gateRec({ change: 'passes-here', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'passes-here', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const stub = function () { return { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } }; };
  const railList = stub(); const railHead = stub();
  global.document = {
    getElementById: function (id) { return id === 'rail-list' ? railList : (id === 'rail-project-head' ? railHead : null); },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  app._setRailFilter('failing');
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }
  app._setRailFilter(null);
  delete global.document;
  assert.ok(/data-change="fails-here"/.test(railList.innerHTML), 'the failing change is shown');
  assert.strictEqual(/data-change="passes-here"/.test(railList.innerHTML), false, 'the passing one is filtered out');
  assert.ok(/rail-summary/.test(railHead.innerHTML), 'the summary bar renders into the rail head');
  assert.ok(/rail-metrics/.test(railHead.innerHTML), 'and the P1-1 metrics panel');
});

// ---- P1-3 · escape and assumption records ----
test('friendlyEscapes surfaces an escape record for the change that caused it', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'leaky', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify({ type: 'escape', change: 'leaky', found_by: 'monitoring', severity: 'high', note: 'null deref in prod', date: '2026-02-01' })
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'leaky'; })[0];
  const html = app.friendlyEscapes(cg);
  assert.ok(/escaped|escape|after review/i.test(html), 'names it as an escape: ' + html);
  assert.ok(/monitoring/.test(html) && /null deref in prod/.test(html), 'shows who found it and the note');
  // a change with no escape record gets nothing
  const clean = app.buildExecutions('p');
  assert.strictEqual(app.friendlyEscapes({ project: 'p', change: 'nope', rounds: [] }), '');
});

test('friendlyAssumptions lists assumptions and flags a still-defaulted one', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'assumed-things', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify({ type: 'assumption', change: 'assumed-things', round: 1, assumed: 'the cache TTL is 60s', basis: '', resolution: 'defaulted', date: '2026-02-01' }),
    JSON.stringify({ type: 'assumption', change: 'assumed-things', round: 1, assumed: 'the API is idempotent', basis: 'docs say so', resolution: 'verified', date: '2026-02-01' })
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'assumed-things'; })[0];
  const html = app.friendlyAssumptions(cg);
  assert.ok(/the cache TTL is 60s/.test(html) && /the API is idempotent/.test(html), 'both assumptions listed');
  assert.ok(/record-warn/.test(html), 'the defaulted one is flagged');
  assert.ok(/unconfirmed/.test(html), 'and the section says so up top');
});

test('a still-defaulted assumption cleared by a later "asked" record is no longer flagged', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'resolved-assume', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify({ type: 'assumption', change: 'resolved-assume', round: 1, assumed: 'X is Y', basis: '', resolution: 'defaulted', date: '2026-02-01' }),
    JSON.stringify({ type: 'assumption', change: 'resolved-assume', round: 2, assumed: 'X is Y', basis: '', resolution: 'asked', date: '2026-02-02' })
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'resolved-assume'; })[0];
  const html = app.friendlyAssumptions(cg);
  assert.strictEqual(/record-warn/.test(html), false, 'the later "asked" record governs — nothing is flagged');
  assert.strictEqual(/unconfirmed/.test(html), false);
});

test('renderOverviewTab includes the escape and assumption sections', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'ov', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'ov', round: 1, gate: 'G2', outcome: 'pass' })),
    JSON.stringify({ type: 'escape', change: 'ov', found_by: 'user', severity: 'high', date: '2026-02-02' }),
    JSON.stringify({ type: 'assumption', change: 'ov', round: 1, assumed: 'the thing', basis: '', resolution: 'defaulted', date: '2026-02-01' })
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'ov'; })[0];
  const html = app.renderOverviewTab({ ex: cg.rounds[0], cg: cg, isLatest: true });
  assert.ok(/escape-section/.test(html), 'the escape section is on the tab');
  assert.ok(/What was assumed/.test(html), 'and the assumptions section');
});

test('renderRail badges a change whose defect escaped', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'buggy-change', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify({ type: 'escape', change: 'buggy-change', found_by: 'user', severity: 'high', date: '2026-02-02' })
  ] }]);
  const railList = { innerHTML: '', addEventListener: function () {}, querySelectorAll: function () { return []; } };
  global.document = {
    getElementById: function (id) { return id === 'rail-list' ? railList : null; },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }
  delete global.document;
  assert.ok(/escape-badge/.test(railList.innerHTML), 'the rail row carries the escaped-defect badge');
});

// ---- P1-9 · elapsed time in the result block ----
test('changeSpanText spells out rounds and the day span', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'span3', round: 1, gate: 'G1', outcome: 'pass', date: '2026-03-01T09:00:00Z' })),
    JSON.stringify(gateRec({ change: 'span3', round: 2, gate: 'G1', outcome: 'pass', date: '2026-03-03T09:00:00Z' })),
    JSON.stringify(gateRec({ change: 'span3', round: 3, gate: 'G1', outcome: 'pass', date: '2026-03-04T09:00:00Z' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'span3'; })[0];
  assert.strictEqual(app.changeSpanText(cg), '3 rounds over 3 days (2026-03-01 → 2026-03-04)');
});

test('changeSpanText handles a single-day, single-round change', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'oneday', round: 1, gate: 'G1', outcome: 'pass', date: '2026-03-01T09:00:00Z' })),
    JSON.stringify(gateRec({ change: 'oneday', round: 1, gate: 'G2', outcome: 'pass', date: '2026-03-01T18:00:00Z' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'oneday'; })[0];
  assert.strictEqual(app.changeSpanText(cg), '1 round on 2026-03-01');
});

test('renderOutput uses the span text, not a bare round count', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'ro', round: 1, gate: 'G1', outcome: 'pass', date: '2026-03-01T09:00:00Z' })),
    JSON.stringify(gateRec({ change: 'ro', round: 2, gate: 'G1', outcome: 'pass', date: '2026-03-05T09:00:00Z' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'ro'; })[0];
  assert.ok(/over 4 days \(2026-03-01 → 2026-03-05\)/.test(app.renderOutput(cg)), app.renderOutput(cg));
});

// ---- P1-8 · the generated-at stamp escalates as it ages ----
test('ageDays counts whole days and returns null for a future or garbage date', function () {
  const app = load();
  assert.strictEqual(app.ageDays(isoDaysAgo(0)), 0);
  assert.strictEqual(app.ageDays(isoDaysAgo(5)), 5);
  assert.strictEqual(app.ageDays(isoDateTimeDaysAgo(3, '09', '05')), 3);
  assert.strictEqual(app.ageDays(isoDaysAgo(-2)), null, 'future-dated → null, not a negative age to escalate on');
  assert.strictEqual(app.ageDays('not-a-date'), null);
  assert.strictEqual(app.ageDays(undefined), null);
});

// ================================================================ G5 Proof round 1 · 2026-09-03
//
// Coverage gaps the first pass left: pieces of NEW code whose only assertion
// was the name of the container they render into, so the function could return
// "" and every test still passed. Each was mutation-verified by G5.

test('projectMetricsHtml renders every leading metric, not just its container', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'm1', round: 1, gate: 'G1', outcome: 'fail', findings: 3, tokens: 90000, confidence: 'fresh' })),
    JSON.stringify(gateRec({ change: 'm1', round: 1, gate: 'G2', outcome: 'pass', tokens: 30000, confidence: 'self' })),
    JSON.stringify(routeRec({ change: 'm1', round: 1, verdict: 'under' })),
    JSON.stringify(routeRec({ change: 'm1', round: 2, verdict: 'match', date: '2026-01-02' })),
    JSON.stringify(routeRec({ change: 'm1', round: 3, verdict: 'match', date: '2026-01-03' })),
    JSON.stringify(routeRec({ change: 'm1', round: 4, verdict: 'match', date: '2026-01-04' })),
    JSON.stringify({ type: 'escape', change: 'm1', found_by: 'user', severity: 'high', date: '2026-01-03' })
  ] }]);
  const html = app.projectMetricsHtml(app.computeProjectMetrics('p'));
  assert.ok(/Reconcile miss rate: 25%/.test(html), 'miss rate, as a percentage: ' + html);
  assert.ok(/Challenge rate/.test(html), 'challenge rate line present: ' + html);
  assert.ok(/Escape rate: 25% \(1 escaped\)/.test(html), '1 escape / (1 + 3 findings): ' + html);
  assert.ok(/1 self-check run\(s\)/.test(html), 'the non-fresh run is called out (P1-6): ' + html);
  assert.ok(/Tokens: 120,000/.test(html), 'total tokens, grouped (P1-7): ' + html);
  assert.ok(/40,000 per finding/.test(html), '120000 / 3 findings: ' + html);
});

test('projectMetricsHtml says "not enough data" rather than fabricating a 0%', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'm2', round: 1, gate: 'G1', outcome: 'pass', tokens: 0 }))
  ] }]);
  const html = app.projectMetricsHtml(app.computeProjectMetrics('p'));
  assert.ok(/Reconcile miss rate: not enough data yet/.test(html), 'no routes -> no rate: ' + html);
  assert.ok(/Escape rate: not enough data yet/.test(html));
  assert.ok(/Tokens: none recorded/.test(html), 'tokens:0 -> "none recorded", never "Tokens: 0": ' + html);
  assert.strictEqual(/self-check run/.test(html), false, 'all-fresh -> no self-check line');
});

test('the rail summary bar hides empty buckets and marks the active filter', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'sb-fail', round: 1, gate: 'G1', outcome: 'fail', findings: 1 })),
    JSON.stringify(gateRec({ change: 'sb-run', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }]);
  const stub = function () { return { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } }; };
  const railList = stub(); const railHead = stub();
  global.document = {
    getElementById: function (id) { return id === 'rail-list' ? railList : (id === 'rail-project-head' ? railHead : null); },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  app._setRailFilter('failing');
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }
  app._setRailFilter(null);
  delete global.document;
  const h = railHead.innerHTML;
  assert.ok(/data-f="">2 changes</.test(h), 'the always-present total segment clears the filter: ' + h);
  assert.ok(/data-f="failing"[^>]*>1 failed</.test(h), 'a non-empty bucket gets a segment: ' + h);
  assert.strictEqual(/data-f="escapes"/.test(h), false, 'an EMPTY bucket gets no segment at all: ' + h);
  assert.ok(/class="seg fail active"[^>]*data-f="failing"/.test(h), 'the active filter is marked: ' + h);
  assert.strictEqual(/class="seg active"[^>]*data-f=""/.test(h), false, 'and the total segment is not, while a filter is on');
});

test('a filter that matches nothing shows the empty-filter row, not a blank rail', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'nothing-fails', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }]);
  const railList = { innerHTML: '', addEventListener: function () {}, querySelectorAll: function () { return []; } };
  const railHead = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = {
    getElementById: function (id) { return id === 'rail-list' ? railList : (id === 'rail-project-head' ? railHead : null); },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  app._setRailFilter('failing');
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }
  app._setRailFilter(null);
  delete global.document;
  assert.ok(/rail-empty-filter/.test(railList.innerHTML), 'the empty state explains why the rail is empty: ' + railList.innerHTML);
  assert.ok(/class="rail-clear"[^>]*>Show all/i.test(railList.innerHTML), 'and offers a way out (clears text + status filter)');
});

test('the escapes filter keeps a routing artifact an escape happens to name', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'master', round: 1 })),
    JSON.stringify(gateRec({ change: 'real-change', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify({ type: 'escape', change: 'master', found_by: 'user', severity: 'high', date: '2026-02-02' })
  ] }]);
  const railList = { innerHTML: '', addEventListener: function () {}, querySelectorAll: function () { return []; } };
  const railHead = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = {
    getElementById: function (id) { return id === 'rail-list' ? railList : (id === 'rail-project-head' ? railHead : null); },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  app._setRailFilter('escapes');
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }
  app._setRailFilter(null);
  delete global.document;
  assert.ok(/routing-artifact/.test(railList.innerHTML), 'the named artifact is kept, not silently dropped: ' + railList.innerHTML);
  assert.strictEqual(/data-change="real-change"/.test(railList.innerHTML), false, 'and the unnamed real change is filtered out');
});

test('escape and assumption records do not leak across projects', function () {
  const app = load();
  app.ingest([
    { path: 'a', project: 'pa', lines: [
      JSON.stringify(gateRec({ change: 'shared-name', round: 1, gate: 'G1', outcome: 'pass' }))
    ] },
    { path: 'b', project: 'pb', lines: [
      JSON.stringify(gateRec({ change: 'shared-name', round: 1, gate: 'G1', outcome: 'pass' })),
      JSON.stringify({ type: 'escape', change: 'shared-name', found_by: 'pb-monitoring', severity: 'high', date: '2026-02-02' }),
      JSON.stringify({ type: 'assumption', change: 'shared-name', round: 1, assumed: 'pb assumed this', basis: '', resolution: 'defaulted', date: '2026-02-01' })
    ] }
  ]);
  const a = app.buildExecutions('pa').filter(function (c) { return c.change === 'shared-name'; })[0];
  const b = app.buildExecutions('pb').filter(function (c) { return c.change === 'shared-name'; })[0];
  assert.strictEqual(app.friendlyEscapes(a), '', "project A's change has no escape of its own");
  assert.strictEqual(app.friendlyAssumptions(a), '', 'nor an assumption');
  assert.ok(/pb-monitoring/.test(app.friendlyEscapes(b)), "project B's escape still shows on project B");
  assert.ok(/pb assumed this/.test(app.friendlyAssumptions(b)));
});

test('the generated stamp escalates amber past 3 days and red past 14', function () {
  const app = load();
  assert.strictEqual(app.staleClass(isoDaysAgo(0)), '');
  assert.strictEqual(app.staleClass(isoDaysAgo(3)), '', 'exactly 3 days is still fresh');
  assert.strictEqual(app.staleClass(isoDaysAgo(4)), 'stale');
  assert.strictEqual(app.staleClass(isoDaysAgo(14)), 'stale', 'exactly 14 is amber, not red');
  assert.strictEqual(app.staleClass(isoDaysAgo(15)), 'stale-bad');
  assert.strictEqual(app.staleClass(isoDaysAgo(-2)), '', 'a future stamp is clock skew, not staleness');
  assert.strictEqual(app.staleClass('garbage'), '');
});

test('fmtInt groups from the right and is safe on 0/null', function () {
  const app = load();
  assert.strictEqual(app.fmtInt(0), '0');
  assert.strictEqual(app.fmtInt(null), '0');
  assert.strictEqual(app.fmtInt(undefined), '0');
  assert.strictEqual(app.fmtInt(999), '999');
  assert.strictEqual(app.fmtInt(1000), '1,000');
  assert.strictEqual(app.fmtInt(1234567), '1,234,567');
});

// Same category as the G7 passes of 2026-09-01 (`.round`) and 2026-09-02
// (`minutes`/`severity`): friendlyEscapes/friendlyAssumptions interpolate
// ledger fields into an innerHTML string, in a page that takes a ledger by
// drag-and-drop and over the network. Every escapeHtml() call in them could be
// deleted individually with the suite green until this test.
test('crafted escape and assumption fields are escaped, not injected as markup', function () {
  const app = load();
  const PAY = '<img src=x onerror=alert(1)>';
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'xss', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify({ type: 'escape', change: 'xss', found_by: PAY, severity: PAY, note: PAY, date: '2026-02-02' }),
    JSON.stringify({ type: 'assumption', change: 'xss', round: 1, assumed: PAY, basis: PAY, resolution: PAY, date: '2026-02-01' })
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'xss'; })[0];
  [['friendlyEscapes', app.friendlyEscapes(cg)], ['friendlyAssumptions', app.friendlyAssumptions(cg)]]
    .forEach(function (pair) {
      assert.strictEqual(pair[1].indexOf(PAY), -1, pair[0] + ' must not emit a crafted field raw: ' + pair[1]);
      assert.ok(pair[1].indexOf('&lt;img') !== -1, pair[0] + ' still SHOWS the value, escaped: ' + pair[1]);
    });
  const tab = app.renderOverviewTab({ ex: cg.rounds[0], cg: cg, isLatest: true });
  assert.strictEqual(tab.indexOf(PAY), -1, 'nor via renderOverviewTab: ' + tab);
});

// G6 Peer round 1: railSummary/friendlyAssumptions keyed plain objects by
// ledger change / assumption text — Object.prototype members read truthy and
// `__proto__` does not become an own key.
test('a change or assumption named like an Object.prototype member is handled', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'constructor', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'real', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify({ type: 'assumption', change: 'real', round: 1, assumed: '__proto__', basis: '', resolution: 'defaulted', date: '2026-02-01' }),
    JSON.stringify({ type: 'assumption', change: 'real', round: 1, assumed: 'toString', basis: '', resolution: 'defaulted', date: '2026-02-01' })
  ] }]);
  const sm = app.railSummary('p');
  assert.strictEqual(!!sm.escapeChanges['constructor'], false, 'no escape record -> no phantom escaped-change');
  assert.strictEqual(sm.escapeChangeCount, 0);
  const real = app.buildExecutions('p').filter(function (c) { return c.change === 'real'; })[0];
  const html = app.friendlyAssumptions(real);
  assert.ok(/__proto__/.test(html), 'a __proto__-named assumption is still listed, not dropped: ' + html);
  assert.ok(/toString/.test(html));
});

// ================================================================ G6 Peer round 2 · 2026-09-03
//
// isIndependent() alone treated a skipped/n-a record — which ledger.sh
// auto-stamps confidence:"low" precisely because it has no review to grade — as
// a self-check by the author. isSelfCheck() is the guard: a run only counts as
// a self-check if it produced a verdict AND was not independent.

test('a skipped or n/a run is not a self-check, whatever its confidence', function () {
  const app = load();
  assert.strictEqual(app.isSelfCheck({ outcome: 'pass', confidence: 'low' }), true);
  assert.strictEqual(app.isSelfCheck({ outcome: 'fail', confidence: 'same-session' }), true);
  assert.strictEqual(app.isSelfCheck({ outcome: 'pass', confidence: 'fresh' }), false, 'a fresh pass is an independent review');
  assert.strictEqual(app.isSelfCheck({ outcome: 'skipped', confidence: 'low' }), false, 'a skip has no review to be a self-check of');
  assert.strictEqual(app.isSelfCheck({ outcome: 'n/a', confidence: 'low' }), false);
});

test('a skipped gate does not get the self-check caveat and is not counted as one', function () {
  const app = load();
  global.PIPELINE = {
    matrix: { G1: { T4: 'M' }, G2: { T4: 'M' } },
    gates:  { G1: { persona: 'Scout' }, G2: { persona: 'Peer' } }
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'sk', round: 1, gate: 'G1', outcome: 'skipped', confidence: 'low' })),
    JSON.stringify(gateRec({ change: 'sk', round: 1, gate: 'G2', outcome: 'pass', confidence: 'fresh' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'sk'; })[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  const line = app.friendlyGateLine('G1', st, cg);
  assert.strictEqual(/self-check by the author/.test(line.sentence), false,
    'a gate that did not run is not "a self-check by the author": ' + line.sentence);
  assert.strictEqual(app.computeProjectMetrics('p').selfCheckRuns, 0, 'and it is not in the self-check total');
});

test('tokensPerFinding coerces the finding count, not just the token sum', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    // findings as a STRING — a ledger this page did not write can carry it so
    JSON.stringify(gateRec({ change: 'tp', round: 1, gate: 'G1', outcome: 'fail', findings: '2', tokens: 120000 }))
  ] }]);
  const m = app.computeProjectMetrics('p');
  assert.strictEqual(m.totalFindings, 2, 'string "2" is coerced, not concatenated');
  assert.strictEqual(m.tokensPerFinding, 60000, '120000 / 2, not 120000 / "2"-as-something-else');
});

test('changeSpanText shows the endpoints but no day count when a date is malformed', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'junk', round: 1, gate: 'G1', outcome: 'pass', date: '2026-03-01T09:00:00Z' })),
    JSON.stringify(gateRec({ change: 'junk', round: 2, gate: 'G1', outcome: 'pass', date: 'whenever-i' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'junk'; })[0];
  const txt = app.changeSpanText(cg);
  assert.strictEqual(/NaN/.test(txt), false, 'no fabricated "NaN days": ' + txt);
  assert.ok(/2026-03-01/.test(txt) && /whenever-i/.test(txt), 'the endpoints are still shown: ' + txt);
});

test('fmtInt groups only the integer part', function () {
  const app = load();
  assert.strictEqual(app.fmtInt(1234.5678), '1,234.5678');
  assert.strictEqual(app.fmtInt(-1234567), '-1,234,567');
});

test('an empty ledger shows no summary bar or metrics panel above the drop hint', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [] }]);
  const stub = function () { return { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } }; };
  const railList = stub(); const railHead = stub();
  global.document = {
    getElementById: function (id) { return id === 'rail-list' ? railList : (id === 'rail-project-head' ? railHead : null); },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }
  delete global.document;
  assert.strictEqual(/rail-summary/.test(railHead.innerHTML), false, 'no "0 changes" bar on an empty ledger: ' + railHead.innerHTML);
  assert.strictEqual(/rail-metrics/.test(railHead.innerHTML), false, 'no "not enough data yet" panel either');
  assert.ok(/No gate or route records found/.test(railList.innerHTML), 'just the drop hint');
});

// ================================================================ G5/G6 round 3 · 2026-09-03
//
// G6 round 3: computeProjectMetrics' `fresh` filter is isSelfCheck's mirror and
// must carry the same isVerdict guard — a {skipped, fresh} record (one exists
// in this repo's ledger) otherwise counts as a fresh run and skews the
// challenge-rate denominator.
test('a skipped record stamped confidence:"fresh" is not counted as a fresh run', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'fr', round: 1, gate: 'G1', outcome: 'pass', confidence: 'fresh', challenged_premise: true })),
    JSON.stringify(gateRec({ change: 'fr', round: 1, gate: 'G2', outcome: 'skipped', confidence: 'fresh' }))
  ] }]);
  const m = app.computeProjectMetrics('p');
  assert.strictEqual(m.freshRuns, 1, 'only the pass is a fresh run; the skip has no review');
  assert.strictEqual(m.challengeRate, 1, '1 challenge / 1 fresh run = 100%, not 50%');
});

// G5 round 3: two surviving mutations in the P1-2 filter — the click-handler
// toggle logic and the "running" railKeep arm — reached only through the real
// handler / a non-"failing" filter.

test('wireRailFilters toggles the active segment off on a second click (not a bare assign)', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'f1', round: 1, gate: 'G1', outcome: 'fail', findings: 1 })),
    JSON.stringify(gateRec({ change: 'p1', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'p1', round: 1, gate: 'G2', outcome: 'pass' }))
  ] }]);
  const handlers = {};
  function segBtn(f) {
    return {
      getAttribute: function (k) { return k === 'data-f' ? f : null; },
      addEventListener: function (evt, fn) { if (evt === 'click') handlers[f] = fn; }
    };
  }
  const segs = [segBtn('failing'), segBtn('')];
  function railStub() {
    return {
      innerHTML: '', addEventListener: function () {},
      querySelector: function () { return null; },
      querySelectorAll: function (sel) { return sel === '.seg' ? segs : []; }
    };
  }
  const railList = railStub(); const railHead = railStub();
  global.document = {
    getElementById: function (id) {
      return id === 'rail-list' ? railList : (id === 'rail-project-head' ? railHead : null);
    },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  app._setRailFilter(null);
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }

  handlers['failing']();
  assert.ok(/data-change="f1"/.test(railList.innerHTML), 'one click narrows to failing: ' + railList.innerHTML);
  assert.strictEqual(/data-change="p1"/.test(railList.innerHTML), false, 'the passing change is filtered out');

  handlers['failing']();
  assert.ok(/data-change="p1"/.test(railList.innerHTML),
    'a second click on the active segment clears the filter — the passing change returns: ' + railList.innerHTML);

  app._setRailFilter(null);
  delete global.document;
});

test('the "running" rail filter keeps in-progress changes and drops failed ones', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'still-running', round: 1, gate: 'G1', outcome: 'pass' })),
    JSON.stringify(gateRec({ change: 'has-failed', round: 1, gate: 'G1', outcome: 'fail', findings: 1 }))
  ] }]);
  const railList = { innerHTML: '', addEventListener: function () {}, querySelectorAll: function () { return []; } };
  const railHead = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = {
    getElementById: function (id) {
      return id === 'rail-list' ? railList : (id === 'rail-project-head' ? railHead : null);
    },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  app._setRailFilter('running');
  try { app.renderRail(); } catch (e) { /* downstream panels only */ }
  app._setRailFilter(null);
  delete global.document;
  assert.ok(/data-change="still-running"/.test(railList.innerHTML),
    'the in-progress change is kept by the "running" filter: ' + railList.innerHTML);
  assert.strictEqual(/data-change="has-failed"/.test(railList.innerHTML), false,
    'the failed change is not — "running" must match Running, not another status');
});

// ================================================================ P2 polish · 2026-09-04
//
// stateLines() feeds the SVG gate box, which no test executes. The P2 pass
// changed 4 of its return strings; the "(self-check)" suffix in particular is a
// P1-6 cross-surface invariant — the box, the legend, the drawer and the rail
// metric must all use one word for it (G5 Proof).
test('stateLines labels a self-check pass "(self-check)", never "(low-confidence)"', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'sl', round: 1, gate: 'G1', outcome: 'pass', confidence: 'same-session' })),
    JSON.stringify(gateRec({ change: 'sl', round: 1, gate: 'G2', outcome: 'pass', confidence: 'fresh' }))
  ] }]);
  const cg = app.buildExecutions('p')[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);
  assert.ok(/\(self-check\)/.test(app.stateLines('G1', st).status), 'the self-check box: ' + app.stateLines('G1', st).status);
  assert.strictEqual(/low-confidence/.test(app.stateLines('G1', st).status), false);
  assert.strictEqual(/self-check/.test(app.stateLines('G2', st).status), false, 'a fresh pass is not a self-check');
});

test('stateLines shows "—" for a gate not required at this tier, not the word SKIPPED', function () {
  const app = load();
  global.PIPELINE = {
    matrix: { G1: { T1: 'M', T3: 'M' }, G2: { T1: '—', T3: 'R²' } },
    gates:  { G1: { persona: 'a' }, G2: { persona: 'b' } }
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'nr', round: 1, gate: 'G1', outcome: 'pass', tier: 'T1' }))
  ] }]);
  const cg = app.buildExecutions('p')[0];
  const st = app.computeStatus(cg, cg.rounds[0], true);   // tier resolves to T1
  const g2 = app.stateLines('G2', st);
  assert.strictEqual(g2.status, '—', 'a "—" cell reads as "—": ' + g2.status);
  assert.strictEqual(/SKIPPED/.test(g2.status), false);
});

// ================================================================ P2-5 · keyboard a11y · 2026-09-04
//
// The rail rows and the graph nodes were mouse-only: no role, no tabindex, no
// key handler, and not one focus style in app.css. These pin the keyboard
// contract so a later edit that drops it fails loudly here rather than
// silently on a screen reader. (G5 Proof.)

test('keyActivate fires fn on Enter and Space (and prevents default), not on other keys', function () {
  const app = load();
  let calls = 0;
  const h = app.keyActivate(function () { calls++; });

  let prevented = 0;
  const ev = function (key) { return { key: key, preventDefault: function () { prevented++; } }; };

  h(ev('Enter'));
  assert.strictEqual(calls, 1, 'Enter activates');
  h(ev(' '));
  assert.strictEqual(calls, 2, 'Space activates');
  assert.strictEqual(prevented, 2, 'both Enter and Space preventDefault — Space would otherwise scroll');

  h(ev('Tab'));
  h(ev('a'));
  h(ev('ArrowDown'));
  assert.strictEqual(calls, 2, 'no other key activates');
});

test('renderRail marks every exec-row as a keyboard-activatable button', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'kb1', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(3) })),
    JSON.stringify(gateRec({ change: 'kb1', round: 2, gate: 'G1', outcome: 'fail', date: isoDaysAgo(1) }))
  ] }]);

  const railList = { innerHTML: '', addEventListener: function () {}, querySelectorAll: function () { return []; } };
  global.document = {
    getElementById: function (id) { return id === 'rail-list' ? railList : null; },
    querySelectorAll: function () { return []; }
  };
  app._selectExec('p', 'kb1', 2, null);   // round 2 selected before the rail builds
  try { app.renderRail(); } catch (e) { /* downstream panels need a fuller DOM */ }
  delete global.document;

  const rows = railList.innerHTML.match(/<div class="exec-row[^"]*"[^>]*>/g) || [];
  assert.ok(rows.length >= 2, 'both rounds rendered as rows: ' + railList.innerHTML);
  rows.forEach(function (tag) {
    assert.ok(/role="button"/.test(tag), 'row is a button: ' + tag);
    assert.ok(/tabindex="(0|-1)"/.test(tag), 'row carries a roving tabindex: ' + tag);
    assert.ok(/aria-pressed="(true|false)"/.test(tag), 'row reports pressed state: ' + tag);
    assert.ok(/aria-label="[^"]+"/.test(tag), 'row has an accessible name: ' + tag);
  });
  // P2-8 roving tabindex: exactly one row is the tab stop, and it is the selected one
  const tabbable = rows.filter(function (t) { return /tabindex="0"/.test(t); });
  assert.strictEqual(tabbable.length, 1, 'exactly one tab stop: ' + railList.innerHTML);
  assert.ok(/data-round="2"/.test(tabbable[0]), 'the tab stop is the selected row: ' + tabbable[0]);
  const r1 = rows.filter(function (t) { return /data-round="1"/.test(t); })[0];
  const r2 = rows.filter(function (t) { return /data-round="2"/.test(t); })[0];
  assert.ok(/aria-pressed="true"/.test(r2), 'the selected row reports pressed: ' + r2);
  assert.ok(/aria-pressed="false"/.test(r1), 'an unselected row does not: ' + r1);
  assert.ok(/tabindex="-1"/.test(r1), 'the unselected row is not a tab stop: ' + r1);
});

test('renderDrawer close control is a real <button>, not a mouse-only <span>', function () {
  const app = load();
  global.PIPELINE.spine = [];
  global.PIPELINE.gates.G1 = {
    id: 'G1', name: 'Scout', persona: 'Scout', question: 'q', input: 'the diff',
    withhold: '—', context: 'fresh', owns: 'o', does_not_own: 'd',
    output: 'out', passes_when: 'p', fails_when: 'f', escalate_to: 'e'
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'kb2', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(1) }))
  ] }]);
  const inner = { innerHTML: '' };
  const drawer = { className: '', querySelector: function () { return inner; } };
  global.document = {
    getElementById: function (id) { return id === 'drawer' ? drawer : null; },
    querySelectorAll: function () { return []; }
  };
  app._selectExec('p', 'kb2', 1, 'G1');
  try { app.renderDrawer(); } catch (e) { /* close-button wiring needs the real element */ }
  delete global.document;

  assert.ok(/<button[^>]*id="drawer-close"/.test(inner.innerHTML), 'close is a <button>: ' + inner.innerHTML);
  assert.ok(/aria-label="[^"]+"/.test(inner.innerHTML.match(/<button[^>]*id="drawer-close"[^>]*>/)[0]),
    'the close button is labelled');
  assert.strictEqual(/<span class="close"/.test(inner.innerHTML), false, 'not the old <span>');
});

// Round 6, G8 Dogfood: trapDrawerTab keeps focus in the open drawer, so it must
// carry dialog semantics for AT rather than being a bare region a screen-reader
// cursor can wander behind. Set while open, removed on close.
test('renderDrawer marks the open drawer as a modal dialog, and clears it on close', function () {
  const app = load();
  global.PIPELINE.spine = [];
  global.PIPELINE.gates.G1 = {
    id: 'G1', name: 'Scout', persona: 'Scout', question: 'q', input: 'the diff',
    withhold: '—', context: 'fresh', owns: 'o', does_not_own: 'd',
    output: 'out', passes_when: 'p', fails_when: 'f', escalate_to: 'e'
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'kb2', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(1) }))
  ] }]);
  var attrs = {};
  const inner = { innerHTML: '' };
  const drawer = {
    className: '', querySelector: function () { return inner; },
    setAttribute: function (k, v) { attrs[k] = v; },
    removeAttribute: function (k) { delete attrs[k]; }
  };
  global.document = { getElementById: function (id) { return id === 'drawer' ? drawer : null; },
    querySelectorAll: function () { return []; } };

  app._selectExec('p', 'kb2', 1, 'G1');
  try { app.renderDrawer(); } catch (e) {}
  assert.strictEqual(attrs.role, 'dialog', 'open: role=dialog');
  assert.strictEqual(attrs['aria-modal'], 'true', 'open: aria-modal=true');

  // now close it — _selectExec's 4th arg (gateId) null clears selectedState
  app._selectExec('p', 'kb2', 1, null);
  try { app.renderDrawer(); } catch (e) {}
  assert.strictEqual(attrs.role, undefined, 'closed: role removed');
  assert.strictEqual(attrs['aria-modal'], undefined, 'closed: aria-modal removed');
  delete global.document;
});

test('renderTechnicalTab marks every graph node as a keyboard-activatable button with a name', function () {
  const app = load();
  global.PIPELINE = {
    matrix: { G1: { T4: 'M' }, G2: { T4: 'M' } },
    gates: {
      G1: { id: 'G1', name: 'Intent', persona: 'PM', question: 'q' },
      G2: { id: 'G2', name: 'Proof', persona: 'SDET', question: 'q' }
    },
    spine: [
      { id: 'BUILD', name: 'Build', sub: 'the change', kind: 'task' },
      { id: 'VERIFY', name: 'Verify', sub: 'blind', kind: 'phase' }
    ],
    phases: { VERIFY: 'G1 G2' }
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'kb3', round: 1, gate: 'G1', outcome: 'pass', tier: 'T4', date: isoDaysAgo(2) })),
    JSON.stringify(gateRec({ change: 'kb3', round: 1, gate: 'G2', outcome: 'fail', tier: 'T4', date: isoDaysAgo(2) }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'kb3'; })[0];
  const ex = cg.rounds[0];
  const found = { ex: ex, cg: cg, isLatest: ex === cg.latest, hasNextRound: false };

  function fakeNode(tag) {
    return {
      tagName: tag, _attrs: {}, _kids: [], _listeners: {},
      setAttribute: function (k, v) { this._attrs[k] = String(v); },
      getAttribute: function (k) { return Object.prototype.hasOwnProperty.call(this._attrs, k) ? this._attrs[k] : null; },
      appendChild: function (c) { this._kids.push(c); return c; },
      insertAdjacentHTML: function () {},
      addEventListener: function (ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); },
      set textContent(v) { this._text = v; },
      get textContent() { return this._text; }
    };
  }
  const svghost = fakeNode('div');
  const container = { innerHTML: '', insertAdjacentHTML: function (pos, h) { this.innerHTML += h; } };
  global.document = {
    createElementNS: function (ns, tag) { return fakeNode(tag); },
    getElementById: function (id) { return id === 'svghost' ? svghost : null; }
  };
  try { app.renderTechnicalTab(container, found); } catch (e) { /* renderOutput runs last and needs more DOM */ }
  delete global.document;

  const svg = svghost._kids[0];
  assert.ok(svg, 'the svg was appended to #svghost');
  const states = svg._kids.filter(function (n) { return n.tagName === 'g' && /(^|\s)state(\s|$)/.test(n._attrs.class || ''); });
  assert.ok(states.length >= 3, 'a node per placed state (BUILD + G1 + G2): ' + states.length);
  states.forEach(function (g) {
    assert.strictEqual(g.getAttribute('role'), 'button', 'node ' + g._attrs['data-id'] + ' is a button');
    assert.strictEqual(g.getAttribute('tabindex'), '0', 'node ' + g._attrs['data-id'] + ' is tabbable');
    assert.ok((g.getAttribute('aria-label') || '').length > 0, 'node ' + g._attrs['data-id'] + ' has an accessible name');
    assert.ok((g._listeners.keydown || []).length > 0, 'node ' + g._attrs['data-id'] + ' has a key handler');
  });
  // a gate node names its current status in the label; a failed one says so
  const g2 = states.filter(function (g) { return g._attrs['data-id'] === 'G2'; })[0];
  assert.ok(/G2/.test(g2.getAttribute('aria-label')) && /FAIL/i.test(g2.getAttribute('aria-label')),
    'the failed gate names itself and its status: ' + g2.getAttribute('aria-label'));
  // no node is "selected" here (selectedState null) — the class stays bare "state"
  states.forEach(function (g) {
    assert.strictEqual(/\bselected\b/.test(g._attrs.class || ''), false, 'no spurious selected class');
  });
});

// Round 4, G3 Craft: the open node carries a `selected` class so CSS can drop
// the focus ring on it (its own accent <rect> is already the indicator) — the
// two rings stacked as visual noise otherwise.
test('renderTechnicalTab marks the open node "selected", and only that one', function () {
  const app = load();
  global.PIPELINE = {
    matrix: { G1: { T4: 'M' }, G2: { T4: 'M' } },
    gates: { G1: { id: 'G1', name: 'Intent', persona: 'PM', question: 'q' },
             G2: { id: 'G2', name: 'Proof', persona: 'SDET', question: 'q' } },
    spine: [ { id: 'BUILD', name: 'Build', sub: 'x', kind: 'task' },
             { id: 'VERIFY', name: 'Verify', sub: 'y', kind: 'phase' } ],
    phases: { VERIFY: 'G1 G2' }
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'kb', round: 1, gate: 'G1', outcome: 'pass', tier: 'T4', date: isoDaysAgo(2) })),
    JSON.stringify(gateRec({ change: 'kb', round: 1, gate: 'G2', outcome: 'pass', tier: 'T4', date: isoDaysAgo(2) }))
  ] }]);
  app._selectExec('p', 'kb', 1, 'G2');   // drawer open on G2
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'kb'; })[0];
  const ex = cg.rounds[0];
  const svghost = { _kids: [], appendChild: function (c) { this._kids.push(c); } };
  function fakeNode(tag) {
    return { tagName: tag, _attrs: {}, _kids: [], _listeners: {},
      setAttribute: function (k, v) { this._attrs[k] = String(v); },
      getAttribute: function (k) { return Object.prototype.hasOwnProperty.call(this._attrs, k) ? this._attrs[k] : null; },
      appendChild: function (c) { this._kids.push(c); return c; }, insertAdjacentHTML: function () {},
      addEventListener: function () {}, set textContent(v) { this._t = v; }, get textContent() { return this._t; } };
  }
  global.document = { createElementNS: function (ns, t) { return fakeNode(t); },
    getElementById: function (id) { return id === 'svghost' ? svghost : null; } };
  try { app.renderTechnicalTab({ innerHTML: '', insertAdjacentHTML: function () {} },
    { ex: ex, cg: cg, isLatest: true, hasNextRound: false }); } catch (e) {}
  delete global.document;

  const states = (svghost._kids[0] ? svghost._kids[0]._kids : [])
    .filter(function (n) { return n.tagName === 'g' && /(^|\s)state(\s|$)/.test(n._attrs.class || ''); });
  const selected = states.filter(function (g) { return /\bselected\b/.test(g._attrs.class || ''); });
  assert.strictEqual(selected.length, 1, 'exactly one node is selected');
  assert.strictEqual(selected[0]._attrs['data-id'], 'G2', 'and it is the open one');
});

// Round 2, G6 Peer: the multi-project overview's cards were the click target
// this pass first missed — a bare <div> with a listener, the exact shape the
// change removes everywhere else.
test('renderProjectsOverview marks every project card as a keyboard-activatable button', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'alpha', lines: [
    JSON.stringify(gateRec({ change: 'a1', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }, { path: 'l2', project: 'beta', lines: [
    JSON.stringify(gateRec({ change: 'b1', round: 1, gate: 'G1', outcome: 'pass' }))
  ] }]);
  const wrap = { innerHTML: '', querySelectorAll: function () { return []; } };
  global.document = { getElementById: function (id) { return id === 'graphwrap' ? wrap : null; } };
  try { app.renderProjectsOverview(app.listProjects()); } catch (e) { /* wiring loop only */ }
  delete global.document;

  const cards = wrap.innerHTML.match(/<div class="project-card"[^>]*>/g) || [];
  assert.ok(cards.length === 2, 'a card per project: ' + wrap.innerHTML);
  cards.forEach(function (tag) {
    assert.ok(/role="button"/.test(tag), 'card is a button: ' + tag);
    assert.ok(/tabindex="0"/.test(tag), 'card is tabbable: ' + tag);
    assert.ok(/aria-label="[^"]+"/.test(tag), 'card has an accessible name: ' + tag);
  });
});

// Round 2, G4 Ripple: focus is restored by a stable identity computed from the
// live element, not an enumerated per-caller list. captureFocus() -> a string
// key; restoreFocus() re-finds that control in the rebuilt DOM.
test('captureFocus / restoreFocus round-trip a rail row by its data-* identity', function () {
  const app = load();
  const row = {
    id: '', getAttribute: function (n) { return ({ 'data-change': 'c<x>', 'data-round': '2' })[n] || null; },
    matches: function (s) { return s === '.exec-row'; }
  };
  global.document = { body: {}, activeElement: row };
  const key = app.captureFocus();
  delete global.document;
  assert.strictEqual(key, 'rail\u0000c<x>\u00002', 'key is kind + raw data-* (no escaping, it never touches HTML): ' + key);

  // rebuilt DOM: two rows, only the second matches
  let focused = null;
  const mk = function (chg, rnd) {
    return { getAttribute: function (n) { return ({ 'data-change': chg, 'data-round': rnd })[n]; },
             focus: function () { focused = this; } };
  };
  const want = mk('c<x>', '2'), other = mk('c<x>', '1');
  global.document = { getElementById: function () { return null; },
    querySelectorAll: function (s) { return s === '#rail-list .exec-row' ? [other, want] : []; } };
  app.restoreFocus(key);
  delete global.document;
  assert.strictEqual(focused, want, 'restoreFocus focuses the row whose data-* match, not the other');
});

test('captureFocus ignores <body> and unknown elements, restoreFocus no-ops on a vanished target', function () {
  const app = load();
  const body = {};
  global.document = { body: body, activeElement: body };
  assert.strictEqual(app.captureFocus(), null, '<body> is not a focus target');
  global.document = { body: body, activeElement: { matches: function () { return false; }, id: '' } };
  assert.strictEqual(app.captureFocus(), null, 'an element matching no known control returns null');
  delete global.document;
  // a key whose target is gone: no throw, no focus
  global.document = { getElementById: function () { return null; }, querySelectorAll: function () { return []; } };
  assert.doesNotThrow(function () { app.restoreFocus('state\u0000G9'); });
  delete global.document;
});

// Round 7, G6 Peer: a view-transition control (the "← All projects" back link,
// a project card) is gone after the render it triggers, so restoreFocus must
// land somewhere real rather than drop to <body> (WCAG 2.4.3).
test('captureFocus recognises the back-link; restoreFocus lands on a view after a transition', function () {
  const app = load();
  const backLink = { id: 'back-to-projects', matches: function (s) { return s === '.back-link'; }, getAttribute: function () { return null; } };
  global.document = { body: {}, activeElement: backLink };
  assert.strictEqual(app.captureFocus(), 'backlink', 'the back link captures');
  delete global.document;

  let focused = null;
  const card = { focus: function () { focused = 'card'; } };
  global.document = { getElementById: function () { return null; },
    querySelector: function (s) { return s === '.project-card' ? card : null; } };
  app.restoreFocus('backlink');
  assert.strictEqual(focused, 'card', 'back to fleet -> first project card');
  delete global.document;

  focused = null;
  let regionAttrs = {};
  const region = { setAttribute: function (k, v) { regionAttrs[k] = v; }, focus: function () { focused = 'region'; } };
  global.document = { getElementById: function (id) { return id === 'center' ? region : null; },
    querySelector: function () { return null; } };
  app.restoreFocus('backlink');
  assert.strictEqual(focused, 'region', 'no cards -> the main region');
  assert.strictEqual(regionAttrs.tabindex, '-1', 'the region is made programmatically focusable');
  delete global.document;

  focused = null;
  const row = { focus: function () { focused = 'row'; }, getAttribute: function () { return null; } };
  global.document = { getElementById: function () { return null; },
    querySelector: function (s) { return s === '#rail-list .exec-row' ? row : null; },
    querySelectorAll: function () { return []; } };
  app.restoreFocus('project' + String.fromCharCode(0) + 'alpha');
  assert.strictEqual(focused, 'row', 'into a project -> the first (auto-selected) rail row');
  delete global.document;
});

// P2-5 criterion (drawer focus management): a keyboard open moves focus INTO
// the drawer; closing it — the close button OR Esc — returns focus to the
// g.state node that opened it. captureFocus()/restoreFocus() are the shared
// mechanism on both legs; the rail round-trip above exercises the ".exec-row"
// key, these pin the two drawer-transition keys the design's `pendingFocus`
// override rides on ("#drawer-close" on open, "state\0<id>" on close).
// (G5 Proof, 2026-09-04 — added at the gate: round 2 shipped with only the
// rail key exercised, and design.md's "Silent failure" note overstated the
// coverage of the Esc / close-button path.)
var NUL = '\u0000';

test('captureFocus recognises a focused graph node and the drawer close button', function () {
  const app = load();
  const gnode = {
    id: '', matches: function (s) { return s === 'g.state'; },
    getAttribute: function (n) { return n === 'data-id' ? 'G2' : null; }
  };
  global.document = { body: {}, activeElement: gnode };
  assert.strictEqual(app.captureFocus(), 'state' + NUL + 'G2', 'a focused gate node captures as state\\0<id>');
  delete global.document;

  const closeBtn = { id: 'drawer-close', matches: function () { return false; }, getAttribute: function () { return null; } };
  global.document = { body: {}, activeElement: closeBtn };
  assert.strictEqual(app.captureFocus(), '#drawer-close', 'the drawer close button captures by its id');
  delete global.document;
});

test('restoreFocus returns focus to the g.state node that opened the drawer (close leg)', function () {
  const app = load();
  let focused = null;
  const mk = function (id) {
    return { getAttribute: function (n) { return n === 'data-id' ? id : null; },
             focus: function () { focused = this; } };
  };
  const want = mk('G2'), other = mk('G1');
  global.document = {
    getElementById: function () { return null; },
    querySelectorAll: function (s) { return s === '#svghost g.state' ? [other, want] : []; }
  };
  app.restoreFocus('state' + NUL + 'G2');
  delete global.document;
  assert.strictEqual(focused, want, 'the node whose data-id matches the opener is focused, not a sibling');
});

test('restoreFocus moves focus onto the drawer close button on a keyboard open (open leg)', function () {
  const app = load();
  let focused = null;
  const btn = { focus: function () { focused = this; } };
  global.document = {
    getElementById: function (id) { return id === 'drawer-close' ? btn : null; },
    querySelectorAll: function () { return []; }
  };
  app.restoreFocus('#drawer-close');
  delete global.document;
  assert.strictEqual(focused, btn, 'a keyboard open lands focus on the close button, inside the drawer');
});

// G5 Proof round 2 (blocking): round 2 shipped with the drawer focus-transition
// WIRING untested — a node's keydown vs click, closeDrawer(), the Esc handler.
// The captureFocus/restoreFocus primitives above are exercised; these pin the
// code that INVOKES them, which is where criterion 5 actually lives.

// A fake SVG DOM that records attributes and listeners, enough to run
// renderTechnicalTab far enough to wire every g.state node.
function techTabFakeDoc(svghost) {
  function fakeNode(tag) {
    return {
      tagName: tag, _attrs: {}, _kids: [], _listeners: {},
      setAttribute: function (k, v) { this._attrs[k] = String(v); },
      getAttribute: function (k) { return Object.prototype.hasOwnProperty.call(this._attrs, k) ? this._attrs[k] : null; },
      appendChild: function (c) { this._kids.push(c); return c; },
      insertAdjacentHTML: function () {},
      addEventListener: function (ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); },
      set textContent(v) { this._text = v; }, get textContent() { return this._text; }
    };
  }
  return {
    createElementNS: function (ns, tag) { return fakeNode(tag); },
    getElementById: function (id) { return id === 'svghost' ? svghost : null; },
    _fakeNode: fakeNode
  };
}
function renderTechTabAndGetNodes(app) {
  global.PIPELINE = {
    matrix: { G1: { T4: 'M' }, G2: { T4: 'M' } },
    gates: { G1: { id: 'G1', name: 'Intent', persona: 'PM', question: 'q' },
             G2: { id: 'G2', name: 'Proof', persona: 'SDET', question: 'q' } },
    spine: [ { id: 'BUILD', name: 'Build', sub: 'x', kind: 'task' },
             { id: 'VERIFY', name: 'Verify', sub: 'y', kind: 'phase' } ],
    phases: { VERIFY: 'G1 G2' }
  };
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'kb', round: 1, gate: 'G1', outcome: 'pass', tier: 'T4', date: isoDaysAgo(2) })),
    JSON.stringify(gateRec({ change: 'kb', round: 1, gate: 'G2', outcome: 'pass', tier: 'T4', date: isoDaysAgo(2) }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'kb'; })[0];
  const ex = cg.rounds[0];
  const svghost = { _kids: [], appendChild: function (c) { this._kids.push(c); } };
  global.document = techTabFakeDoc(svghost);
  try { app.renderTechnicalTab({ innerHTML: '', insertAdjacentHTML: function () {} },
    { ex: ex, cg: cg, isLatest: true, hasNextRound: false }); } catch (e) { /* renderOutput last */ }
  const svg = svghost._kids[0];
  const nodes = {};
  (svg ? svg._kids : []).filter(function (n) { return n.tagName === 'g' && /(^|\s)state(\s|$)/.test(n._attrs.class || ''); })
    .forEach(function (n) { nodes[n._attrs['data-id']] = n; });
  delete global.document;
  return nodes;
}

test('a graph node opened by KEYDOWN records the keyboard-open focus intent', function () {
  const app = load();
  const nodes = renderTechTabAndGetNodes(app);
  assert.ok(nodes.G2 && nodes.G2._listeners.keydown, 'G2 has a keydown listener');
  try { nodes.G2._listeners.keydown[0]({ key: 'Enter', preventDefault: function () {} }); } catch (e) { /* renderAll needs a full DOM */ }
  const f = app._peekFocus();
  assert.strictEqual(f.selectedState, 'G2', 'the drawer opens on G2');
  assert.strictEqual(f.drawerReturnId, 'G2', 'and remembers G2 as the node to return focus to');
  assert.strictEqual(app.drawerCloseFocus(), 'state\u0000G2', 'so closing will send focus back to G2');
});

test('a graph node opened by CLICK (mouse) records no keyboard-open focus intent', function () {
  const app = load();
  const nodes = renderTechTabAndGetNodes(app);
  assert.ok(nodes.G1 && nodes.G1._listeners.click, 'G1 has a click listener');
  try { nodes.G1._listeners.click[0](); } catch (e) { /* renderAll needs a full DOM */ }
  const f = app._peekFocus();
  assert.strictEqual(f.selectedState, 'G1', 'the drawer opens on G1');
  assert.strictEqual(f.drawerReturnId, null, 'a mouse open does not pin a return node');
  assert.strictEqual(app.drawerCloseFocus(), null, 'so closing does not yank a mouse user');
});

test('closeDrawer clears the drawer and, after a keyboard open, targets the opening node', function () {
  const app = load();
  const nodes = renderTechTabAndGetNodes(app);
  try { nodes.G2._listeners.keydown[0]({ key: ' ', preventDefault: function () {} }); } catch (e) {}
  assert.strictEqual(app.drawerCloseFocus(), 'state\u0000G2', 'precondition: keyboard-opened on G2');
  try { app.closeDrawer(); } catch (e) { /* renderAll needs a full DOM */ }
  const f = app._peekFocus();
  assert.strictEqual(f.selectedState, null, 'the drawer is closed');
  assert.strictEqual(f.drawerReturnId, null, 'the return node is consumed');
  // restoreFocus('state\u0000G2') focusing that node is proven by the "close leg" test above.
});

test('handleEscKey closes the drawer only when a gate is open, and never throws idle', function () {
  const app = load();
  assert.doesNotThrow(function () { app.handleEscKey({ key: 'Escape' }); }, 'idle: no gate open, no-op');
  assert.doesNotThrow(function () { app.handleEscKey({ key: 'a' }); }, 'a non-Escape key is ignored');

  const app2 = load();
  app2._selectExec('p', 'c', 1, 'G7');   // a gate drawer is open
  try { app2.handleEscKey({ key: 'Escape' }); } catch (e) { /* renderAll needs a full DOM */ }
  assert.strictEqual(app2._peekFocus().selectedState, null, 'Escape closed the open drawer');
});

test('app.css carries the P2-5 :focus-visible block (criterion 4)', function () {
  const fs = require('fs');
  const css = fs.readFileSync(path.join(__dirname, '..', 'tools', 'dashboard', 'app.css'), 'utf8');
  assert.ok(/\.exec-row:focus-visible\b/.test(css), 'rail rows get a keyboard focus ring');
  assert.ok(/\.state:focus-visible\b/.test(css), 'graph nodes get a keyboard focus ring');
  assert.ok(/#drawer \.close:focus-visible\b/.test(css), 'the drawer close button gets one');
  assert.ok(/\.skip-link\b/.test(css) && /\.skip-link:focus\b/.test(css), 'the skip link is styled, and reveals on focus');
  // :focus-visible, never a bare :focus that would also fire on a mouse click
  assert.strictEqual(/\.exec-row:focus\b(?!-visible)/.test(css), false, 'no bare .exec-row:focus rule');
});

// Round 5, G8 Dogfood: a "skip to content" bypass so a keyboard user is not
// forced through the whole rail (one Tab stop per review round) to reach the
// centre panel — WCAG 2.4.1.
test('installSkipLink injects a focusable bypass as the first body child, once', function () {
  const app = load();
  var body = { _kids: [], firstChild: null,
    insertBefore: function (n, ref) { this._kids.unshift(n); this.firstChild = n; } };
  var main = { _attrs: {}, setAttribute: function (k, v) { this._attrs[k] = v; }, focus: function () { this._focused = true; } };
  var created = null;
  global.document = {
    querySelector: function (s) { return s === '.skip-link' ? (created && created._match ? created : null) : null; },
    getElementById: function (id) { return id === 'center' ? main : null; },
    createElement: function (tag) {
      created = { tagName: tag, className: '', href: '', textContent: '', _listeners: {},
        addEventListener: function (ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); } };
      return created;
    },
    body: body
  };
  app.installSkipLink();
  assert.strictEqual(created && created.tagName, 'a', 'an <a> was created');
  assert.strictEqual(created.className, 'skip-link', 'with the skip-link class');
  assert.strictEqual(body.firstChild, created, 'inserted as the first body child (first tab stop)');
  assert.ok((created._listeners.click || []).length === 1, 'has an activation handler');
  // activating it focuses <main>, having made it focusable
  created._listeners.click[0]({ preventDefault: function () {} });
  assert.strictEqual(main._attrs.tabindex, '-1', 'main is made programmatically focusable');
  assert.ok(main._focused, 'and focus moves to it');

  // idempotent: a second call with the link already present is a no-op
  created._match = true;
  var kidsBefore = body._kids.length;
  app.installSkipLink();
  assert.strictEqual(body._kids.length, kidsBefore, 'not injected twice');
  delete global.document;
});

// Round 5, G8: while the drawer is open, Tab wraps within it instead of falling
// out to the top of the page (the drawer is last in the DOM).
test('trapDrawerTab keeps Tab inside the open drawer, and is inert otherwise', function () {
  const app = load();
  var firstEl = { focus: function () { focused = 'first'; } };
  var lastEl = { focus: function () { focused = 'last'; } };
  var focused = null, active = lastEl;
  var drawer = {
    className: 'open',
    contains: function (n) { return n === firstEl || n === lastEl; },
    querySelectorAll: function () { return [firstEl, lastEl]; }
  };
  global.document = { getElementById: function (id) { return id === 'drawer' ? drawer : null; },
    get activeElement() { return active; } };

  var prevented = false;
  app.trapDrawerTab({ key: 'Tab', shiftKey: false, preventDefault: function () { prevented = true; } });
  assert.ok(prevented && focused === 'first', 'Tab on the last element wraps to the first');

  focused = null; prevented = false; active = firstEl;
  app.trapDrawerTab({ key: 'Tab', shiftKey: true, preventDefault: function () { prevented = true; } });
  assert.ok(prevented && focused === 'last', 'Shift+Tab on the first wraps to the last');

  // closed drawer: inert
  focused = null; prevented = false; drawer.className = '';
  app.trapDrawerTab({ key: 'Tab', shiftKey: false, preventDefault: function () { prevented = true; } });
  assert.ok(!prevented && focused === null, 'a closed drawer does not trap Tab');

  // non-Tab key: inert
  drawer.className = 'open';
  app.trapDrawerTab({ key: 'Enter', preventDefault: function () { prevented = true; } });
  assert.ok(!prevented, 'only Tab is trapped');
  delete global.document;
});

// ================================================================ P2-8 · rail at scale · 2026-09-04
//
// The rail gained a name filter, a default cap with "show all", and roving-
// tabindex arrow navigation. The whole no-wrap navigation decision is a pure
// function; the render output and the delegated handler are the rest.

test('railArrowTarget steps by one, jumps for Home/End, and does NOT wrap', function () {
  const app = load();
  const n = 5;
  assert.strictEqual(app.railArrowTarget(n, 2, 'ArrowDown'), 3);
  assert.strictEqual(app.railArrowTarget(n, 2, 'ArrowUp'), 1);
  assert.strictEqual(app.railArrowTarget(n, 0, 'ArrowUp'), -1, 'no wrap off the top');
  assert.strictEqual(app.railArrowTarget(n, 4, 'ArrowDown'), -1, 'no wrap off the bottom');
  assert.strictEqual(app.railArrowTarget(n, 3, 'Home'), 0);
  assert.strictEqual(app.railArrowTarget(n, 1, 'End'), 4);
  assert.strictEqual(app.railArrowTarget(n, 0, 'Home'), -1, 'Home when already home is a no-op');
  assert.strictEqual(app.railArrowTarget(n, 4, 'End'), -1, 'End when already at end is a no-op');
  assert.strictEqual(app.railArrowTarget(n, 2, 'Enter'), -1, 'not an arrow/Home/End');
  assert.strictEqual(app.railArrowTarget(n, 2, 'Tab'), -1);
  assert.strictEqual(app.railArrowTarget(0, 0, 'ArrowDown'), -1, 'empty list');
  assert.strictEqual(app.railArrowTarget(1, 0, 'ArrowDown'), -1, 'single row: nowhere to go');
});

test('closestRow walks up to the nearest .exec-row (no Element.closest)', function () {
  const app = load();
  const row = { classList: { contains: function (c) { return c === 'exec-row'; } } };
  const inner = { classList: { contains: function () { return false; } }, parentNode: row };
  const deep = { classList: { contains: function () { return false; } }, parentNode: inner };
  assert.strictEqual(app.closestRow(deep), row);
  assert.strictEqual(app.closestRow(row), row, 'inclusive of the row itself');
  assert.strictEqual(app.closestRow({ classList: { contains: function () { return false; } }, parentNode: null }), null);
  assert.strictEqual(app.closestRow(null), null);
});

// A rail-list stub that records innerHTML and hands back fake .exec-row nodes so
// the delegated arrow handler can be invoked.
function railStub() {
  var handlers = {};
  var stub = {
    innerHTML: '',
    _rows: [],
    addEventListener: function (ev, fn) { (handlers[ev] = handlers[ev] || []).push(fn); },
    querySelector: function (s) {
      if (s === '.exec-row') return stub._rows[0] || null;
      if (/tabindex="0"/.test(s)) return stub._rows.filter(function (r) { return r._attrs.tabindex === '0'; })[0] || null;
      if (s === '.rail-more' || s === '.rail-clear') return stub['_' + s.slice(6)] || null;
      return null;
    },
    querySelectorAll: function (s) { return s.indexOf('exec-row') >= 0 ? stub._rows : []; },
    _fire: function (ev, arg) { (handlers[ev] || []).forEach(function (h) { h(arg); }); }
  };
  return stub;
}
function fakeRow(change, round, tabindex) {
  return {
    _attrs: { 'data-change': change, 'data-round': String(round), tabindex: tabindex },
    classList: { contains: function (c) { return c === 'exec-row'; } },
    getAttribute: function (k) { return this._attrs[k] != null ? this._attrs[k] : null; },
    setAttribute: function (k, v) { this._attrs[k] = String(v); },
    addEventListener: function () {},
    focus: function () { this._focused = true; },
    scrollIntoView: function () { this._scrolled = true; }
  };
}

test('handleRailArrows moves the roving tabindex + focus, and does not wrap', function () {
  const app = load();
  const rows = [fakeRow('a', 1, '0'), fakeRow('b', 1, '-1'), fakeRow('c', 1, '-1')];
  const list = { querySelectorAll: function (s) { return s.indexOf('exec-row') >= 0 ? rows : []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? list : null; } };

  var pd = 0;
  app.handleRailArrows({ key: 'ArrowDown', target: rows[0], preventDefault: function () { pd++; } });
  assert.strictEqual(rows[1]._focused, true, 'ArrowDown focuses the next row');
  assert.strictEqual(rows[1]._attrs.tabindex, '0', 'and it becomes the tab stop');
  assert.strictEqual(rows[0]._attrs.tabindex, '-1', 'the old one steps back');
  assert.strictEqual(pd, 1, 'and preventDefault so the page does not scroll');

  // ArrowUp on the FIRST row: no move (no wrap), but still preventDefault so
  // the page does not scroll at the boundary (G6 Peer r2).
  rows[0]._attrs.tabindex = '0'; rows[1]._attrs.tabindex = '-1';
  rows[0]._focused = false; rows[2]._focused = false;
  var bpd = 0;
  app.handleRailArrows({ key: 'ArrowUp', target: rows[0], preventDefault: function () { bpd++; } });
  assert.notStrictEqual(rows[2]._focused, true, 'no wrap to the bottom');
  assert.strictEqual(rows[0]._attrs.tabindex, '0', 'the tab stop did not move');
  assert.strictEqual(bpd, 1, 'a nav key on a row preventDefaults even at the boundary');

  // Enter / a stray key -> the handler is inert (each row's keyActivate owns those)
  rows[1]._focused = false;
  app.handleRailArrows({ key: 'Enter', target: rows[0], preventDefault: function () { pd++; } });
  assert.strictEqual(pd, 1, 'Enter is not the arrow handler\'s to touch');

  // e.target not on a row -> inert
  app.handleRailArrows({ key: 'ArrowDown', target: { classList: { contains: function () { return false; } }, parentNode: null }, preventDefault: function () {} });
  delete global.document;
});

test('resetRailView clears all three rail-narrowing controls together (G6 round 1)', function () {
  const app = load();
  app._setRailFilter('failing');
  app._setRailQuery('foo');
  app._setRailShowAll(true);
  var before = app._peekRailView();
  assert.ok(before.railFilter === 'failing' && before.railQuery === 'foo' && before.railShowAll === true, 'set: ' + JSON.stringify(before));
  app.resetRailView();
  var after = app._peekRailView();
  assert.strictEqual(after.railFilter, null);
  assert.strictEqual(after.railQuery, '');
  assert.strictEqual(after.railShowAll, false);
});

// G6 Peer round 2: restoreFocus landing on a rail row that renderRail did not
// mark tabbable (arrow-navigated away, then a background renderAll) must move
// the roving tab stop with it, so the two never diverge.
test('restoreFocus syncs the roving tab stop onto the rail row it lands on', function () {
  const app = load();
  var held = { getAttribute: function () { return '0'; }, setAttribute: function (k, v) { this._t = v; } };
  var landed = {
    _attrs: { 'data-change': 'c', 'data-round': '2', tabindex: '-1' },
    getAttribute: function (k) { return this._attrs[k]; },
    setAttribute: function (k, v) { this._attrs[k] = String(v); },
    focus: function () { this._focused = true; }
  };
  global.document = {
    querySelectorAll: function (s) { return s === '#rail-list .exec-row' ? [landed] : []; },
    querySelector: function (s) { return /tabindex="0"/.test(s) ? held : null; }
  };
  app.restoreFocus('rail' + String.fromCharCode(0) + 'c' + String.fromCharCode(0) + '2');
  delete global.document;
  assert.strictEqual(landed._focused, true, 'the row is focused');
  assert.strictEqual(landed._attrs.tabindex, '0', 'and becomes the tab stop');
  assert.strictEqual(held._t, '-1', 'the previous tab stop steps back');
});

test('renderRail: the name filter narrows the list; a non-matching change is gone', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'login-refactor', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(3) })),
    JSON.stringify(gateRec({ change: 'payment-flow', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(2) }))
  ] }]);
  const rail = railStub();
  const head = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? rail : (id === 'rail-project-head' ? head : null); }, querySelectorAll: function () { return []; } };
  app._selectProject('p');

  app._setRailQuery('');
  try { app.renderRail(); } catch (e) {}
  assert.ok(/login-refactor/i.test(rail.innerHTML) && /payment-flow/i.test(rail.innerHTML), 'both changes show unfiltered');

  app._setRailQuery('PAYMENT');   // case-insensitive
  try { app.renderRail(); } catch (e) {}
  assert.ok(/payment-flow/i.test(rail.innerHTML), 'the match stays');
  assert.strictEqual(/login-refactor/i.test(rail.innerHTML), false, 'the non-match is gone');

  app._setRailQuery('zzz-nothing');
  try { app.renderRail(); } catch (e) {}
  assert.ok(/rail-empty-filter/.test(rail.innerHTML) && /rail-clear/.test(rail.innerHTML), 'no match -> the empty row + a clear button');

  // G8 Dogfood: the rail SHOWS "Payment Flow", the ledger stores "payment-flow"
  // — a query typed the way the row reads (with a space) must still match.
  app._setRailQuery('payment flow');
  try { app.renderRail(); } catch (e) {}
  assert.ok(/payment-flow/i.test(rail.innerHTML), 'a spaced query matches the hyphenated slug: ' + rail.innerHTML);
  assert.strictEqual(/login-refactor/i.test(rail.innerHTML), false);

  // whitespace-only query is not a filter
  app._setRailQuery('   ');
  try { app.renderRail(); } catch (e) {}
  assert.ok(/payment-flow/i.test(rail.innerHTML) && /login-refactor/i.test(rail.innerHTML), 'a blank query shows everything');
  delete global.document;
});

test('railFilterNorm strips separators and lowercases both sides of the filter match', function () {
  const app = load();
  assert.strictEqual(app.railFilterNorm('Dashboard P1 Readability'), 'dashboardp1readability');
  assert.strictEqual(app.railFilterNorm('dashboard-p1_readability'), 'dashboardp1readability');
  assert.strictEqual(app.railFilterNorm('  trim  me  '), 'trimme');
  assert.strictEqual(app.railFilterNorm(''), '');
  assert.strictEqual(app.railFilterNorm(null), '');
});

test('renderRail: the default rail caps at RAIL_CAP change groups with a "show all", filtering lifts it', function () {
  const app = load();
  const cap = app._railCap();
  const lines = [];
  for (let i = 0; i < cap + 4; i++) {
    lines.push(JSON.stringify(gateRec({ change: 'chg-' + String(1000 + i), round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(i + 1) })));
  }
  app.ingest([{ path: 'l', project: 'p', lines: lines }]);
  const rail = railStub();
  const head = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? rail : (id === 'rail-project-head' ? head : null); }, querySelectorAll: function () { return []; } };
  app._selectProject('p');

  try { app.renderRail(); } catch (e) {}
  const groups = (rail.innerHTML.match(/class="change-group/g) || []).length;
  assert.strictEqual(groups, cap, 'the default view renders exactly RAIL_CAP groups: ' + groups);
  assert.ok(/class="rail-more"[^>]*>Show all \d+ changes/.test(rail.innerHTML), 'with a "show all" button: ' + rail.innerHTML.slice(-200));
  assert.ok(/\(4 more\)/.test(rail.innerHTML), 'and it names how many more');

  app._setRailShowAll(true);
  try { app.renderRail(); } catch (e) {}
  assert.strictEqual((rail.innerHTML.match(/class="change-group/g) || []).length, cap + 4, 'show all -> every group');
  assert.strictEqual(/class="rail-more"/.test(rail.innerHTML), false, 'and the button is gone');

  // a filter is never capped
  app._setRailShowAll(false);
  app._setRailQuery('chg');   // matches all
  try { app.renderRail(); } catch (e) {}
  assert.strictEqual((rail.innerHTML.match(/class="change-group/g) || []).length, cap + 4, 'while filtering, no cap');
  assert.strictEqual(/class="rail-more"/.test(rail.innerHTML), false);
  delete global.document;
});

// G8 Dogfood round 5: clearing a filter with a change from the capped-off tail
// selected left the centre panel showing a review with NO row in the rail. The
// selected group is now always rendered, past the cap, in its sorted position.
test('renderRail: the selected change is always rendered, even past the cap', function () {
  const app = load();
  const cap = app._railCap();
  const lines = [];
  // cap+5 real changes, newest first by date; the LAST (oldest) is "tail-chg"
  for (let i = 0; i < cap + 5; i++) {
    const name = i === cap + 4 ? 'tail-chg' : 'chg-' + String(1000 + i);
    lines.push(JSON.stringify(gateRec({ change: name, round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(i + 2) })));
  }
  app.ingest([{ path: 'l', project: 'p', lines: lines }]);
  const rail = railStub();
  const head = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? rail : (id === 'rail-project-head' ? head : null); }, querySelectorAll: function () { return []; } };
  app._selectExec('p', 'tail-chg', 1, null);   // select the deepest tail change
  try { app.renderRail(); } catch (e) {}

  assert.ok(/data-change="tail-chg"/.test(rail.innerHTML), 'the selected tail change renders despite the cap: ' + rail.innerHTML.slice(-400));
  const rows = rail.innerHTML.match(/<div class="exec-row[^"]*"[^>]*>/g) || [];
  const tailRow = rows.filter(function (t) { return /data-change="tail-chg"/.test(t); })[0];
  assert.ok(/class="exec-row selected/.test(tailRow) && /aria-pressed="true"/.test(tailRow), 'and it is marked selected: ' + tailRow);
  assert.ok(/tabindex="0"/.test(tailRow), 'and it is the roving tab stop');
  // it renders in sorted position (last), just above the "show all" button
  assert.ok(rail.innerHTML.indexOf('data-change="tail-chg"') > rail.innerHTML.indexOf('data-change="chg-1000"'), 'in its natural (last) sorted position');
  // "M more" excludes the shown rows: cap shown + 1 pinned = cap+1; 5 real tail; 1 pinned -> 4 more
  assert.ok(/\(4 more\)/.test(rail.innerHTML), 'the "more" count drops the pinned row: ' + rail.innerHTML.slice(-200));
  delete global.document;
});

// G3 Craft: the cap and its "Show all N changes" count are on REAL changes only
// — routing artifacts are "not a change" and railSummary's chip count excludes
// them, so counting them here made the rail show two different totals.
test('renderRail: routing artifacts do not count toward the cap or its label', function () {
  const app = load();
  const cap = app._railCap();
  const lines = [];
  for (let i = 0; i < cap; i++) {   // exactly cap real changes -> no cap
    lines.push(JSON.stringify(gateRec({ change: 'real-' + String(1000 + i), round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(i + 2) })));
  }
  lines.push(JSON.stringify(routeRec({ change: 'master', round: 1 })));   // a routing artifact
  app.ingest([{ path: 'l', project: 'p', lines: lines }]);
  const rail = railStub();
  const head = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? rail : (id === 'rail-project-head' ? head : null); }, querySelectorAll: function () { return []; } };
  app._selectProject('p');
  try { app.renderRail(); } catch (e) {}
  // cap real changes + 1 artifact = cap+1 groups, but keptReal == cap -> NOT capped
  assert.strictEqual(/class="rail-more"/.test(rail.innerHTML), false, 'cap real changes + an artifact does not trip the cap');
  assert.ok(/routing-artifact/.test(rail.innerHTML), 'the artifact still renders');
  delete global.document;
});

// ---- G5 Proof (2026-09-04): edge-decision-table rows the r1-r3 tests left
// uncovered but that ARE within headless reach. Each exercises P2-8 code that
// does not exist pre-change (new exports / new branches), so none free-passes.

test('renderRail: the name filter AND the status chip both apply (intersection, not union)', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'alpha-svc', round: 1, gate: 'G1', outcome: 'fail', findings: 1, date: isoDaysAgo(3) })),
    JSON.stringify(gateRec({ change: 'beta-svc',  round: 1, gate: 'G1', outcome: 'fail', findings: 1, date: isoDaysAgo(2) })),
    JSON.stringify(gateRec({ change: 'alpha-doc', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(1) }))
  ] }]);
  const rail = railStub();
  const head = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? rail : (id === 'rail-project-head' ? head : null); }, querySelectorAll: function () { return []; } };
  app._selectProject('p');

  app._setRailQuery('alpha');
  app._setRailFilter('failing');
  try { app.renderRail(); } catch (e) {}
  assert.ok(/data-change="alpha-svc"/.test(rail.innerHTML), 'alpha-svc matches BOTH the name and the status: ' + rail.innerHTML);
  assert.strictEqual(/data-change="beta-svc"/.test(rail.innerHTML), false, 'beta-svc is failing but the name does not match');
  assert.strictEqual(/data-change="alpha-doc"/.test(rail.innerHTML), false, 'alpha-doc matches the name but is not failing');
  app._setRailFilter(null);
  delete global.document;
});

test('wireRailSearch: Escape in the filter field clears the query and does NOT bubble to the drawer handler', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'kappa', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(2) })),
    JSON.stringify(gateRec({ change: 'lambda', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(1) }))
  ] }]);
  const rail = railStub();
  const inp = {
    value: 'kap', selectionStart: 3, _h: {},
    addEventListener: function (ev, fn) { (this._h[ev] = this._h[ev] || []).push(fn); },
    focus: function () { this._focused = true; },
    setSelectionRange: function () {}
  };
  const head = {
    innerHTML: '', addEventListener: function () {},
    querySelector: function (s) { return s === '.rail-search' ? inp : null; },
    querySelectorAll: function () { return []; }
  };
  global.document = {
    getElementById: function (id) {
      if (id === 'rail-list') return rail;
      if (id === 'rail-project-head') return head;
      if (id === 'rail-search') return inp;
      return null;
    },
    querySelectorAll: function () { return []; }
  };
  app._selectProject('p');
  app._setRailQuery('kap');
  app._setRailShowAll(true);
  try { app.renderRail(); } catch (e) {}

  const kd = (inp._h.keydown || [])[0];
  assert.strictEqual(typeof kd, 'function', 'wireRailSearch registered a keydown handler on the field');

  var stopped = 0;
  try { kd({ key: 'Escape', stopPropagation: function () { stopped++; } }); } catch (e) {}
  assert.strictEqual(stopped, 1, 'Escape stopPropagation so handleEscKey does not also fire and close the drawer');
  const view = app._peekRailView();
  assert.strictEqual(view.railQuery, '', 'the query is cleared');
  assert.strictEqual(view.railShowAll, false, 'and the cap is re-applied');
  assert.strictEqual(inp.value, '', 'the field is emptied');
  delete global.document;
});

test('renderRail: when the selected row is filtered out, the roving tab stop falls back to the first rendered row', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'visible-chg', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(2) })),
    JSON.stringify(gateRec({ change: 'hidden-chg',  round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(1) }))
  ] }]);
  const rail = railStub();
  const head = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? rail : (id === 'rail-project-head' ? head : null); }, querySelectorAll: function () { return []; } };
  app._selectExec('p', 'hidden-chg', 1, null);   // selection points at the change the filter will hide
  app._setRailQuery('visible');
  try { app.renderRail(); } catch (e) {}

  const rows = rail.innerHTML.match(/<div class="exec-row[^"]*"[^>]*>/g) || [];
  assert.ok(rows.length >= 1, 'the matching change still renders: ' + rail.innerHTML);
  assert.strictEqual(/data-change="hidden-chg"/.test(rail.innerHTML), false, 'the selected-but-filtered change is gone');
  const tabbable = rows.filter(function (t) { return /tabindex="0"/.test(t); });
  assert.strictEqual(tabbable.length, 1, 'exactly one row is still the tab stop: ' + rail.innerHTML);
  assert.ok(/data-change="visible-chg"/.test(tabbable[0]), 'and it is the first rendered row, not a stale reference: ' + tabbable[0]);
  delete global.document;
});

test('handleRailArrows scrolls the newly focused row into view within the rail', function () {
  const app = load();
  const rows = [fakeRow('a', 1, '0'), fakeRow('b', 1, '-1')];
  const list = { querySelectorAll: function (s) { return s.indexOf('exec-row') >= 0 ? rows : []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? list : null; } };
  app.handleRailArrows({ key: 'ArrowDown', target: rows[0], preventDefault: function () {} });
  assert.strictEqual(rows[1]._scrolled, true, 'the row the arrow moved to is scrolled into view (block:nearest)');
  delete global.document;
});

// G5 Proof: pin the G6-r1 leak fix — renderRail must NEVER add a keydown
// listener to the persistent #rail-list (that binding lives once in boot()).
// A future edit re-adding one inside renderRail would otherwise pass CI.
test('renderRail does not bind a keydown listener on the static #rail-list', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(gateRec({ change: 'x', round: 1, gate: 'G1', outcome: 'pass', date: isoDaysAgo(1) }))
  ] }]);
  var railEvents = [];
  const rail = { innerHTML: '', _rows: [],
    addEventListener: function (ev) { railEvents.push(ev); },
    querySelector: function () { return null; },
    querySelectorAll: function (s) { return s.indexOf('exec-row') >= 0 ? [] : []; } };
  const head = { innerHTML: '', addEventListener: function () {}, querySelector: function () { return null; }, querySelectorAll: function () { return []; } };
  global.document = { getElementById: function (id) { return id === 'rail-list' ? rail : (id === 'rail-project-head' ? head : null); }, querySelectorAll: function () { return []; } };
  app._selectProject('p');
  try { app.renderRail(); app.renderRail(); app.renderRail(); } catch (e) { /* downstream panels */ }
  delete global.document;
  assert.strictEqual(railEvents.indexOf('keydown'), -1, 'renderRail added a keydown listener to #rail-list: ' + JSON.stringify(railEvents));
});

// ================================================================ R-005
//
// changeIsBranchy() used to be a hand-enumerated list ONLY. tools/dashboard.sh
// now bakes the repo's real default branch into the model as
// PIPELINE.defaultBranch, and this function refuses THAT first — so a dashboard
// for a repo whose trunk is `prod` renders a `prod` route record as the muted
// routing artifact it is, not as a real change. The bash half is in
// tests/run.sh (test_ledger_refuses_the_computed_default_branch_*).

test('changeIsBranchy refuses the computed PIPELINE.defaultBranch, before the hand-list', function () {
  const app = load();
  global.PIPELINE.defaultBranch = 'prod';
  assert.strictEqual(app.changeIsBranchy('prod'), true, 'the resolved default branch is branchy even though it is not on the list');
  assert.strictEqual(app.changeIsBranchy('master'), true, 'the hand-list still applies too');
  assert.strictEqual(app.changeIsBranchy('release'), false, 'a plausible real change name is still not refused');
});

test('changeIsBranchy falls back to the hand-list only when PIPELINE.defaultBranch is absent or empty', function () {
  const app = load();
  // freshPipeline() sets no defaultBranch — the older-page / unit-harness case.
  assert.strictEqual(typeof global.PIPELINE.defaultBranch, 'undefined');
  assert.strictEqual(app.changeIsBranchy('prod'), false, 'with nothing computed, `prod` is a normal change name');
  assert.strictEqual(app.changeIsBranchy('master'), true, 'the hand-list fallback is intact');
  global.PIPELINE.defaultBranch = '';
  assert.strictEqual(app.changeIsBranchy('prod'), false, 'an empty computed value must not match every name');
  assert.strictEqual(app.changeIsBranchy(''), false, 'and must not make the empty change name branchy');
});

test('buildExecutions tags a default-branch route group as a routing artifact when the model names that branch', function () {
  const app = load();
  global.PIPELINE.defaultBranch = 'prod';
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'prod', round: 1, verdict: 'match' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'prod'; })[0];
  assert.ok(cg, 'the prod route group is still in the list, not dropped');
  assert.strictEqual(cg.isRoutingArtifact, true, 'a gateless route group named for the real trunk is a routing artifact, not a change');
});

// G4/G6 r7: a restarted lineage (a round-1 route with a DIFFERENT base) is scoped like ledger.sh
// compliance does it. An old lineage's higher-round PASS must not govern the new lineage, and an old
// FAIL must not void its passes; the older rounds stay visible as their own group.
test('a new lineage starts at a restart-marked round-1 route; older rounds do not govern it', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'aaaaaaa', date: '2026-01-01' })),
    JSON.stringify(gateRec({ change: 'x', round: 3, gate: 'G4', outcome: 'pass', date: '2026-01-02' })),
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'bbbbbbb', restart: true, date: '2026-01-03' })),
    JSON.stringify(gateRec({ change: 'x', round: 1, gate: 'G4', outcome: 'fail', findings: 1, date: '2026-01-04' }))
  ] }]);
  const all = app.buildExecutions('p');
  const cur = all.filter(function (c) { return c.change === 'x'; })[0];
  const old = all.filter(function (c) { return c.change === 'x (earlier lineage 1)'; })[0];
  assert.ok(cur && old, 'the old lineage is listed apart, not dropped, and not merged into the current one');
  const gov = app.gateGoverningAtOrBefore(cur, 'G4', cur.rounds[cur.rounds.length - 1]);
  assert.strictEqual(gov.entry.outcome, 'fail', 'the old lineage round-3 pass does not outrank the new lineage fail');
});

test('the same base again is a re-run, not a new lineage', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'aaaaaaa', verdict: 'under', date: '2026-01-01' })),
    JSON.stringify(gateRec({ change: 'x', round: 1, gate: 'G4', outcome: 'pass', date: '2026-01-02' })),
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'aaaaaaa', date: '2026-01-03' }))
  ] }]);
  const all = app.buildExecutions('p');
  assert.strictEqual(all.filter(function (c) { return /earlier lineage/.test(c.change); }).length, 0);
});

// G7 r8: a round-1 route with another base but NO restart marker is what a union merge of two
// ledgers produces. It must not start a lineage (that would drop an open FAIL from the page).
test('a different base without a restart marker does not start a lineage', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'aaaaaaa', date: '2026-01-01' })),
    JSON.stringify(gateRec({ change: 'x', round: 1, gate: 'G6', outcome: 'fail', findings: 1, date: '2026-01-02' })),
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'bbbbbbb', date: '2026-01-03' })),
    JSON.stringify(gateRec({ change: 'x', round: 1, gate: 'G4', outcome: 'pass', date: '2026-01-04' }))
  ] }]);
  const all = app.buildExecutions('p');
  assert.strictEqual(all.filter(function (c) { return /earlier lineage/.test(c.change); }).length, 0, 'one lineage');
  const cur = all.filter(function (c) { return c.change === 'x'; })[0];
  const gov = app.gateGoverningAtOrBefore(cur, 'G6', cur.rounds[cur.rounds.length - 1]);
  assert.strictEqual(gov.entry.outcome, 'fail', 'the open G6 fail still governs');
});

// G4 r8: the tier floor is the lineage maximum, like ledger.sh compliance, not the latest route.
test('computeStatus uses the lineage tier floor, not the latest round tier', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'aaaaaaa', predicted: 'T4', actual: 'T4', date: '2026-01-01' })),
    JSON.stringify(routeRec({ change: 'x', round: 2, base: 'aaaaaaa', predicted: 'T1', actual: 'T1', date: '2026-01-03' })),
    JSON.stringify(gateRec({ change: 'x', round: 2, gate: 'G6', outcome: 'pass', date: '2026-01-04' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'x'; })[0];
  const last = cg.rounds[cg.rounds.length - 1];
  const st = app.computeStatus(cg, last, true);
  assert.notStrictEqual(st.status, 'Succeeded', 'T4 gates are still mandated even though round 2 re-diffed as T1');
});

test('an earlier-lineage group is not counted as a change in the headline', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'aaaaaaa', date: '2026-01-01' })),
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'bbbbbbb', restart: true, date: '2026-01-02' }))
  ] }]);
  assert.strictEqual(app.computeProjectMetrics('p').changeCount, 1, 'one change, however many lineages');
});

// G5 r9 #9: only a route that carries a base raises the dashboard's tier floor, like ledger.sh.
test('a hand-typed route without a base does not raise the lineage tier floor', function () {
  const app = load();
  app.ingest([{ path: 'l', project: 'p', lines: [
    JSON.stringify(routeRec({ change: 'x', round: 1, base: 'aaaaaaa', predicted: 'T1', actual: 'T1', date: '2026-01-01' })),
    JSON.stringify(routeRec({ change: 'x', round: 2, predicted: 'T4', actual: 'T4', date: '2026-01-02' }))
  ] }]);
  const cg = app.buildExecutions('p').filter(function (c) { return c.change === 'x'; })[0];
  assert.strictEqual(app.floorTier(cg), 'T1', 'a route with no base is advisory');
});

if (failures > 0) {
  console.log('\n' + failures + ' failure(s)');
  process.exit(1);
}
console.log('\nall dashboard logic tests passed');
process.exit(0);
