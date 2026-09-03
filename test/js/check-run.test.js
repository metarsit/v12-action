'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { fakeCore, httpError, context } = require('./helpers');
const checkRun = require('../../scripts/github/check-run.js');

function payload(n, extra) {
  const annotations = [];
  for (let i = 0; i < n; i += 1) {
    annotations.push({ path: `src/f${i}.sol`, start_line: i + 1, end_line: i + 2, annotation_level: 'warning', title: `t${i}`, message: `m${i}` });
  }
  const p = path.join(os.tmpdir(), `v12-check-${process.pid}-${n}.json`);
  fs.writeFileSync(p, JSON.stringify({ name: 'V12 Security', headSha: 'abc', conclusion: 'neutral', detailsUrl: 'https://v12.sh/runs/42', title: 't', summary: 's', annotations, ...extra }));
  return p;
}

test('creates the check run and appends annotations in batches of 50', async () => {
  const calls = [];
  const github = { rest: { checks: {
    create: async (args) => { calls.push(['create', args]); return { data: { id: 555, html_url: 'https://github.com/acme/vault/runs/555' } }; },
    update: async (args) => { calls.push(['update', args]); return { data: {} }; },
  } } };
  const core = fakeCore();
  const r = await checkRun.create({ github, context, core }, { payloadPath: payload(120) });
  assert.strictEqual(r.outcome, 'created');
  assert.strictEqual(r.annotations, 120);
  assert.strictEqual(calls.length, 3);
  assert.strictEqual(calls[0][1].output.annotations.length, 50);
  assert.strictEqual(calls[0][1].head_sha, 'abc');
  assert.strictEqual(calls[0][1].conclusion, 'neutral');
  assert.strictEqual(calls[0][1].details_url, 'https://v12.sh/runs/42');
  assert.strictEqual(calls[1][1].output.annotations.length, 50);
  assert.strictEqual(calls[2][1].output.annotations.length, 20);
  assert.strictEqual(calls[2][1].check_run_id, 555);
  assert.strictEqual(core.outputs['check-run-url'], 'https://github.com/acme/vault/runs/555');
});

test('a check run without annotations omits the annotations key', async () => {
  const calls = [];
  const github = { rest: { checks: { create: async (args) => { calls.push(args); return { data: { id: 1, html_url: 'u' } }; }, update: async () => ({ data: {} }) } } };
  const r = await checkRun.create({ github, context, core: fakeCore() }, { payloadPath: payload(0) });
  assert.strictEqual(r.outcome, 'created');
  assert.strictEqual(calls[0].output.annotations, undefined);
});

test('missing checks: write becomes a warning, not a failure', async () => {
  const github = { rest: { checks: { create: async () => { throw httpError(403, 'Resource not accessible by integration'); } } } };
  const core = fakeCore();
  const r = await checkRun.create({ github, context, core }, { payloadPath: payload(3) });
  assert.strictEqual(r.outcome, 'failed');
  assert.match(core.warnings[0], /checks: write/);
  assert.strictEqual(core.outputs['check-run-outcome'], 'failed');
});

test('no head sha skips the check run', async () => {
  const core = fakeCore();
  const r = await checkRun.create({ github: {}, context, core }, { payloadPath: payload(1, { headSha: '' }) });
  assert.strictEqual(r.outcome, 'skipped');
});
