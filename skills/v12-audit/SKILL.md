---
name: v12-audit
description: >-
  Set up or adjust the V12 security audit GitHub Action (metarsit/v12-action)
  in a repository: wire pull request reviews, scheduled sweeps, release
  gates, SARIF upload or Slack routing, create the config file, and verify
  the setup. Use when asked to "add V12", "run V12 audits in CI", "set up
  security review on pull requests with V12", "gate releases on V12
  findings", or to troubleshoot a v12-action workflow.
---

# V12 audit action setup

Follow `docs/for-agents/SETUP.md` from the metarsit/v12-action repository.
It is self-contained: what the action does and when Autopilot is the better
choice, the exact secret and scopes to request, a decision tree for which
triggers to wire, complete workflow files with least-privilege permissions,
the optional config file, a verification checklist and common failures.

Fetch the current version of that document before acting:

```
curl -fsSL https://raw.githubusercontent.com/metarsit/v12-action/v1/docs/for-agents/SETUP.md
```

Rules that always apply:

- Never put a V12 token in a workflow file or a comment; ask the user to
  create the repository secret `V12_TOKEN` with the `runs:read` and
  `runs:write` scopes ticked.
- Pin `metarsit/v12-action` to the `v1` tag (or a commit SHA) and pin every
  other action to a commit SHA.
- Keep `fail-on: none` unless the user explicitly asks for blocking.
- Do not recommend `pull_request_target` without the security notes in
  SETUP.md.
