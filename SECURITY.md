# Security policy

This action handles a V12 API token, a GitHub token and, optionally, Slack
credentials, and it runs inside other people's CI. Reports about anything
that could leak those credentials, execute untrusted input, or misreport a
security result are treated as security issues.

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private vulnerability reporting on
this repository ("Security" tab, "Report a vulnerability"). If that is not
available to you, email the maintainers listed in `CODEOWNERS` through their
GitHub profiles.

Include the action version (`VERSION` or the tag you pin), the workflow
trigger, and a minimal reproduction. Please do not include real tokens.

You will get an acknowledgement within three business days and a fix or a
documented decision within thirty days for confirmed issues. Fixes are
released as a patch version and the `v1` major tag is moved to it; a GitHub
Security Advisory is published for anything that affects consumers.

## Supported versions

Only the latest release of the current major version (`v1`) receives fixes.
Pin the action to a commit SHA or to the major tag; the major tag is moved
only to releases that pass the full test suite.

## What the action does with credentials

- The V12 token is registered with `::add-mask::` before any other output
  and is sent only to the configured `api-url` (default `https://v12.sh`)
  as a bearer header. It is never written to the working directory, outputs,
  SARIF, comments or Slack.
- The GitHub token is used only through `actions/github-script` for
  comments, check runs and the SARIF upload.
- Slack credentials are masked and sent only to `hooks.slack.com` (webhook)
  or `slack.com/api` (bot token).
- Finding titles, descriptions, snippets, file paths and config values are
  treated as untrusted input: they are escaped before being placed in
  Markdown or Slack and are never interpolated into shell commands.
- No `${{ }}` expression is ever interpolated into a `run:` body; every
  value reaches a script through `env:`. CI enforces this mechanically
  (`test/lint-workflows.sh`).

## Scope

In scope: the composite action (`action.yml`, `scripts/`), the release
workflow, and the documentation that tells people how to grant permissions.
Out of scope: vulnerabilities in V12 itself (report those to V12), in
GitHub, or in the repositories the action audits.
