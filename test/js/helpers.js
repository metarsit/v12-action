'use strict';
// Minimal fakes for the github-script environment.

function fakeCore() {
  const core = { outputs: {}, warnings: [], infos: [] };
  core.setOutput = (k, v) => { core.outputs[k] = v; };
  core.warning = (m) => core.warnings.push(m);
  core.info = (m) => core.infos.push(m);
  return core;
}

function httpError(status, message) {
  const e = new Error(message || `HTTP ${status}`);
  e.status = status;
  return e;
}

module.exports = { fakeCore, httpError, context: { repo: { owner: 'acme', repo: 'vault' } } };
