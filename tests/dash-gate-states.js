#!/usr/bin/env node
'use strict';
// Prints, for one change in a ledger file, the outcome app.js says governs each gate in the
// change's LATEST round of its CURRENT lineage: "<gate> pass|fail|skipped|n/a|none".
// Used by tests/run.sh to compare the dashboard with `ledger.sh compliance` on the same ledger,
// so the two re-implementations of the verdict logic cannot drift apart unnoticed.
//   node dash-gate-states.js <ledger.jsonl> <change>
const fs = require('fs');
const path = require('path');

const ledger = process.argv[2];
const change = process.argv[3];
const gates = {};
['G1', 'G2', 'G3', 'G4', 'G5', 'G6', 'G7', 'G8'].forEach(function (g) { gates[g] = { persona: g }; });
global.PIPELINE = { matrix: {}, gates: gates };
global.LEDGERS = [];
const app = require(path.join(__dirname, '..', 'tools', 'dashboard', 'app.js'));
const lines = fs.readFileSync(ledger, 'utf8').split('\n').filter(function (l) { return l.trim(); });
app.ingest([{ path: 'l', project: 'p', lines: lines }]);
const cg = app.buildExecutions('p').filter(function (c) { return c.change === change; })[0];
if (!cg) { console.log('no-such-change'); process.exit(0); }
const latest = cg.rounds[cg.rounds.length - 1];
Object.keys(gates).forEach(function (g) {
  const gov = app.gateGoverningAtOrBefore(cg, g, latest);
  console.log(g + ' ' + (gov ? gov.entry.outcome : 'none'));
});
