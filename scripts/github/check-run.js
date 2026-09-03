// scripts/github/check-run.js - creates the "V12 Security" check run with
// inline annotations, batched to GitHub's 50-per-request limit.
//
//   const cr = require(process.env.V12_ACTION_PATH + '/scripts/github/check-run.js');
//   await cr.create({ github, context, core }, { payloadPath });

'use strict';

const fs = require('fs');

const BATCH = 50;

async function create({ github, context, core }, opts) {
  const owner = opts.owner || context.repo.owner;
  const repo = opts.repo || context.repo.repo;
  const payload = JSON.parse(fs.readFileSync(opts.payloadPath, 'utf8'));
  const annotations = Array.isArray(payload.annotations) ? payload.annotations : [];
  const output = { title: payload.title, summary: payload.summary };
  const result = { id: '', url: '', annotations: 0, outcome: '' };
  if (!payload.headSha) {
    core.warning('No commit SHA for the check run; skipping.');
    result.outcome = 'skipped';
    setOutputs(core, result);
    return result;
  }
  try {
    const first = annotations.slice(0, BATCH);
    const { data } = await github.rest.checks.create({
      owner,
      repo,
      name: payload.name,
      head_sha: payload.headSha,
      status: 'completed',
      conclusion: payload.conclusion,
      details_url: payload.detailsUrl,
      output: first.length > 0 ? { ...output, annotations: first } : output,
    });
    result.id = String(data.id);
    result.url = data.html_url || '';
    result.annotations = first.length;
    for (let i = BATCH; i < annotations.length; i += BATCH) {
      const batch = annotations.slice(i, i + BATCH);
      await github.rest.checks.update({ owner, repo, check_run_id: data.id, output: { ...output, annotations: batch } });
      result.annotations += batch.length;
    }
    result.outcome = 'created';
    core.info(`Check run "${payload.name}" created (${payload.conclusion}) with ${result.annotations} annotation(s): ${result.url}`);
  } catch (error) {
    const status = error && error.status;
    const hint = status === 403 || status === 404
      ? 'The GITHUB_TOKEN lacks "checks: write" (403/404). Add it to the job permissions; on pull requests from forks the token is read-only.'
      : '';
    core.warning(`Could not create the check run: ${error.message}. ${hint} The pull request comment and job summary carry the same information.`.trim());
    result.outcome = 'failed';
  }
  setOutputs(core, result);
  return result;
}

function setOutputs(core, result) {
  core.setOutput('check-run-id', result.id);
  core.setOutput('check-run-url', result.url);
  core.setOutput('check-run-annotations', String(result.annotations));
  core.setOutput('check-run-outcome', result.outcome);
}

module.exports = { create, BATCH };
