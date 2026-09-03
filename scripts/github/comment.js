// scripts/github/comment.js - sticky pull request comment: find the previous
// one (and the state it carries), then create / update / delete it.
//
// Loaded from actions/github-script with an absolute path, e.g.
//   const c = require(process.env.V12_ACTION_PATH + '/scripts/github/comment.js');
//   await c.find({ github, context, core }, { marker, issueNumber });
//   await c.post({ github, context, core }, { marker, issueNumber, bodyPath, action });
// Every value comes through the options object (set from env by the caller),
// never from `${{ }}` interpolation inside the script.

'use strict';

const fs = require('fs');

const STATE_RE = /<!-- v12-audit-action:state:([A-Za-z0-9+/=]+) -->/;
const MAX_PAGES = 10;

function decodeState(body) {
  const m = STATE_RE.exec(body || '');
  if (!m) return null;
  try {
    const parsed = JSON.parse(Buffer.from(m[1], 'base64').toString('utf8'));
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (e) {
    return null;
  }
}

function permissionHint(error) {
  const status = error && error.status;
  if (status === 403 || status === 404) {
    return 'The GITHUB_TOKEN lacks "pull-requests: write" (403/404). Add it to the job permissions; on pull requests from forks the token is read-only and the comment cannot be posted.';
  }
  return '';
}

async function listAll(github, owner, repo, issueNumber) {
  const comments = [];
  for (let page = 1; page <= MAX_PAGES; page += 1) {
    const { data } = await github.rest.issues.listComments({ owner, repo, issue_number: issueNumber, per_page: 100, page });
    comments.push(...data);
    if (data.length < 100) break;
  }
  return comments;
}

async function find({ github, context, core }, opts) {
  const owner = opts.owner || context.repo.owner;
  const repo = opts.repo || context.repo.repo;
  const issueNumber = Number(opts.issueNumber);
  const result = { id: '', url: '', state: null };
  if (!issueNumber) {
    core.setOutput('comment-id', '');
    core.setOutput('prior-state', '');
    return result;
  }
  try {
    const comments = await listAll(github, owner, repo, issueNumber);
    const mine = comments.filter((c) => typeof c.body === 'string' && c.body.includes(opts.marker));
    if (mine.length > 0) {
      const last = mine[mine.length - 1];
      result.id = String(last.id);
      result.url = last.html_url || '';
      result.state = decodeState(last.body);
    }
  } catch (error) {
    core.warning(`Could not list pull request comments: ${error.message}. ${permissionHint(error)}`.trim());
  }
  core.setOutput('comment-id', result.id);
  core.setOutput('comment-url', result.url);
  core.setOutput('prior-state', result.state ? JSON.stringify(result.state) : '');
  return result;
}

async function post({ github, context, core }, opts) {
  const owner = opts.owner || context.repo.owner;
  const repo = opts.repo || context.repo.repo;
  const issueNumber = Number(opts.issueNumber);
  const existingId = opts.existingId ? Number(opts.existingId) : 0;
  const outcome = { action: opts.action, url: '', id: '' };
  if (!issueNumber) {
    core.setOutput('comment-url', '');
    return outcome;
  }
  try {
    if (opts.action === 'delete-if-exists') {
      if (existingId) {
        await github.rest.issues.deleteComment({ owner, repo, comment_id: existingId });
        core.info(`Deleted the previous V12 comment (${existingId}); the run is clean and hide-comment-when-clean is set.`);
        outcome.action = 'deleted';
      } else {
        outcome.action = 'none';
      }
    } else if (opts.action === 'update-or-create') {
      const body = fs.readFileSync(opts.bodyPath, 'utf8');
      if (existingId) {
        const { data } = await github.rest.issues.updateComment({ owner, repo, comment_id: existingId, body });
        outcome.url = data.html_url || '';
        outcome.id = String(data.id);
        outcome.action = 'updated';
      } else {
        const { data } = await github.rest.issues.createComment({ owner, repo, issue_number: issueNumber, body });
        outcome.url = data.html_url || '';
        outcome.id = String(data.id);
        outcome.action = 'created';
      }
      core.info(`V12 comment ${outcome.action}: ${outcome.url}`);
    } else {
      outcome.action = 'skipped';
    }
  } catch (error) {
    const hint = permissionHint(error);
    if (error && error.status === 422) {
      core.warning(`GitHub rejected the comment body (422): ${error.message}. The body is capped at 60,000 characters; if this persists, lower max-comment-findings.`);
    } else {
      core.warning(`Could not post the V12 comment: ${error.message}. ${hint} The job summary carries the same information.`.trim());
    }
    outcome.action = 'failed';
  }
  core.setOutput('comment-url', outcome.url);
  core.setOutput('comment-id', outcome.id);
  core.setOutput('comment-outcome', outcome.action);
  return outcome;
}

module.exports = { find, post, decodeState };
