'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { fakeCore, httpError, context } = require('./helpers');
const comment = require('../../scripts/github/comment.js');

const MARKER = '<!-- v12-audit-action:pr -->';
const state = Buffer.from(JSON.stringify({ v: 1, sha: 'abc', fps: ['0123456789abcdef'] })).toString('base64');

function fakeGithub(comments, calls) {
  return {
    rest: {
      issues: {
        listComments: async ({ page }) => ({ data: page === 1 ? comments : [] }),
        createComment: async (args) => { calls.push(['create', args]); return { data: { id: 900, html_url: 'https://github.com/acme/vault/pull/12#issuecomment-900' } }; },
        updateComment: async (args) => { calls.push(['update', args]); return { data: { id: args.comment_id, html_url: 'https://github.com/acme/vault/pull/12#issuecomment-' + args.comment_id } }; },
        deleteComment: async (args) => { calls.push(['delete', args]); return {}; },
      },
    },
  };
}

test('find returns the last marker comment and decodes its state', async () => {
  const core = fakeCore();
  const github = fakeGithub([
    { id: 1, body: 'unrelated', html_url: 'u1' },
    { id: 2, body: `${MARKER}\nold\n<!-- v12-audit-action:state:${state} -->`, html_url: 'u2' },
    { id: 3, body: `${MARKER}\nnewer\n<!-- v12-audit-action:state:${state} -->`, html_url: 'u3' },
    { id: 4, body: '<!-- v12-audit-action:other -->', html_url: 'u4' },
  ], []);
  const r = await comment.find({ github, context, core }, { marker: MARKER, issueNumber: 12 });
  assert.strictEqual(r.id, '3');
  assert.deepStrictEqual(r.state, { v: 1, sha: 'abc', fps: ['0123456789abcdef'] });
  assert.strictEqual(core.outputs['comment-id'], '3');
  assert.strictEqual(JSON.parse(core.outputs['prior-state']).sha, 'abc');
});

test('find tolerates a malformed state block and missing permissions', async () => {
  const core = fakeCore();
  const github = fakeGithub([{ id: 5, body: `${MARKER} <!-- v12-audit-action:state:!!! -->`, html_url: 'u' }], []);
  const r = await comment.find({ github, context, core }, { marker: MARKER, issueNumber: 12 });
  assert.strictEqual(r.id, '5');
  assert.strictEqual(r.state, null);
  const denied = { rest: { issues: { listComments: async () => { throw httpError(403, 'Resource not accessible by integration'); } } } };
  const core2 = fakeCore();
  const r2 = await comment.find({ github: denied, context, core: core2 }, { marker: MARKER, issueNumber: 12 });
  assert.strictEqual(r2.id, '');
  assert.match(core2.warnings[0], /pull-requests: write/);
});

test('post updates in place when a comment exists and creates otherwise', async () => {
  const bodyPath = path.join(os.tmpdir(), `v12-body-${process.pid}.md`);
  fs.writeFileSync(bodyPath, `${MARKER}\nbody`);
  const calls = [];
  const github = fakeGithub([], calls);
  const core = fakeCore();
  const r1 = await comment.post({ github, context, core }, { marker: MARKER, issueNumber: 12, bodyPath, action: 'update-or-create', existingId: '77' });
  assert.strictEqual(r1.action, 'updated');
  assert.strictEqual(calls[0][0], 'update');
  assert.strictEqual(calls[0][1].comment_id, 77);
  const r2 = await comment.post({ github, context, core }, { marker: MARKER, issueNumber: 12, bodyPath, action: 'update-or-create', existingId: '' });
  assert.strictEqual(r2.action, 'created');
  assert.strictEqual(calls[1][0], 'create');
  assert.strictEqual(core.outputs['comment-url'], 'https://github.com/acme/vault/pull/12#issuecomment-900');
  fs.unlinkSync(bodyPath);
});

test('post deletes an existing comment when asked and never fails the job', async () => {
  const calls = [];
  const github = fakeGithub([], calls);
  const core = fakeCore();
  const r = await comment.post({ github, context, core }, { marker: MARKER, issueNumber: 12, action: 'delete-if-exists', existingId: '5' });
  assert.strictEqual(r.action, 'deleted');
  assert.strictEqual(calls[0][0], 'delete');
  const none = await comment.post({ github, context, core }, { marker: MARKER, issueNumber: 12, action: 'delete-if-exists', existingId: '' });
  assert.strictEqual(none.action, 'none');
  const denied = { rest: { issues: { createComment: async () => { throw httpError(403, 'Resource not accessible by integration'); } } } };
  const bodyPath = path.join(os.tmpdir(), `v12-body2-${process.pid}.md`);
  fs.writeFileSync(bodyPath, 'x');
  const core2 = fakeCore();
  const failed = await comment.post({ github: denied, context, core: core2 }, { marker: MARKER, issueNumber: 12, bodyPath, action: 'update-or-create', existingId: '' });
  assert.strictEqual(failed.action, 'failed');
  assert.match(core2.warnings[0], /pull-requests: write/);
  assert.strictEqual(core2.outputs['comment-url'], '');
  fs.unlinkSync(bodyPath);
});
