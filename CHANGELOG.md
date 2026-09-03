# Changelog

All notable changes to this action are documented here. The format follows
Keep a Changelog; versions follow Semantic Versioning. The `v1` tag always
points at the latest 1.x release.

## Unreleased

### Added

- Composite action running V12 audits from CI in five modes: pull request
  diff review, scheduled diff over a time window, scheduled full audit,
  release gate on tags, and manual dispatch.
- Estimate-then-pin flow with a cost ceiling, empty-diff skips, polling with
  a timeout, and cancellation when the workflow is cancelled.
- Sticky pull request comment updated in place, with severity table,
  findings with source links, collapsible details, delta since the previous
  review, suppressed findings, and a footer with cost and duration.
- Check run with inline annotations, SARIF 2.1.0 for code scanning, a
  self-sufficient job summary, and Slack delivery by webhook or bot token
  (in-place updates and thread replies).
- Repository config file `.github/v12-audit.yml` with a JSON Schema,
  expiring suppressions, and path include/exclude rules.
- Offline test suite: stub V12 API, bats suites, golden files, Node tests,
  bash 3.2 lint, custom workflow lints, drift checks.
- Agent-facing documentation: `AGENTS.md`, `docs/for-agents/SETUP.md`, and
  the `v12-audit` Claude Code skill.

### Decisions

Judgement calls the brief did not settle, recorded here rather than in
commit messages.

- **Licence: MIT.** No licence was specified; MIT is the norm for actions
  and matches the badge the brief asks for.
- **Bash 3.2 floor, not "macOS unsupported".** All scripts avoid bash 4+
  features and GNU-only tool flags; `test/lint-bash32.sh` enforces it and
  CI runs on `macos-latest`.
- **yq for the config file.** GitHub-hosted runners (Ubuntu and macOS)
  ship mikefarah `yq`; the loader falls back to python3+PyYAML and fails
  with an actionable message otherwise. No YAML parser is vendored.
- **Merge base, not base tip, for pull requests.** `fromRef` is
  `git merge-base base head`; a shallow checkout is unshallowed with a
  warning. This is correct whether V12 diffs two-dot or three-dot.
- **`merge_group` gets no sticky comment.** The event has no pull request
  object and the audited commit is the queue's merge commit; the check run,
  summary and SARIF still run.
- **Both `branch` and `sha` are always sent** for full audits, sidestepping
  the unverified "sha without branch returns 400" rule. On tag builds the
  tag name is sent as `branch`.
- **`qa` findings are hidden by default** through `min-severity: info`.
  They are style findings, not security findings.
- **Findings-list detail fan-out.** When V12's list is summary-only, details
  are fetched for the most severe findings up to `max-findings-detail`
  (default 200), paced under the 300/minute artifact-read bucket.
- **Fingerprint scheme.** `sha256("v12-fp-v1", normalised path, title
  tokens lower-cased/sorted/stop-words removed, whitespace-stripped
  snippet)[0:16]`. Severity stays out of the fingerprint and goes into the
  SARIF rule id. GitHub dedups on `primaryLocationLineHash` only, so the
  fingerprint is emitted under that key with a `:n` suffix for repeats.
- **Suppressed findings are omitted from SARIF**, so code scanning closes
  their alerts; the reason lives in the config file.
- **Findings without a source location** anchor SARIF results to the
  workflow file (line 1) with an explanatory message, and get no inline
  annotation.
- **Comment cap 60,000 characters** (GitHub's limit is 65,536): details are
  dropped first, then table rows, then the body is cut.
- **Annotation levels** follow the gate: findings at or above `fail-on` are
  `failure`, other critical/high/medium are `warning`, the rest `notice`.
- **`hide-comment-when-clean` deletes** an existing comment on a clean run
  rather than leaving a stub.
- **Slack with a bot token** updates the previous message in place and
  posts a short thread reply; the message `ts` travels in the PR comment's
  state block. Webhooks cannot edit, so they post once.
- **`conclusion` vocabulary** mirrors check-run conclusions: `success`,
  `neutral`, `failure`, `skipped`, `timed_out`, `cancelled`. A failed V12
  run is `failure` as an output but the check run stays `neutral` unless
  `fail-on-error` is set, so an informative setup never blocks merges.
- **Realized cost** is read from the run object's `cost` field as US
  dollars (per the brief); if the field is absent the footer shows "n/a"
  and the job does not fail. The field name and unit were not verifiable
  offline.
- **Zip source is out of scope** for v1; "repositories without the V12 app"
  therefore means public repositories.
- **CI needs no V12 token.** The suite runs entirely against the offline
  stub; the estimate-only smoke job and the self-test workflow from the
  brief were removed so the repository carries no live credential.
