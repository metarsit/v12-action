# v12-action

[![CI](https://github.com/metarsit/v12-action/actions/workflows/ci.yml/badge.svg)](https://github.com/metarsit/v12-action/actions/workflows/ci.yml)
[![Marketplace](https://img.shields.io/badge/marketplace-v12--security--audit-blue?logo=github)](https://github.com/marketplace/actions/v12-security-audit)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/metarsit/v12-action/badge)](https://scorecard.dev/viewer/?uri=github.com/metarsit/v12-action)

Run [V12](https://v12.sh) security audits from GitHub Actions and put the
results where people look: a sticky pull request comment, a check run with
inline annotations, the Security tab (SARIF), the job summary and Slack. The
action estimates every run before creating it, enforces a cost ceiling,
skips empty diffs, and degrades to warnings instead of failing your job when
a permission or an integration is missing.

![The sticky pull request comment: verdict, severity table, findings with links, collapsible details, delta since the last review, and a cost footer](docs/images/pr-comment.png)

## Should you use this?

V12 ships **Autopilot**, a hosted GitHub integration that reviews every pull
request and posts findings with no workflow to write. For plain per-PR
review, Autopilot is the better choice: nothing to wire, nothing to keep
pinned, no token to rotate.

This action is for the cases Autopilot does not cover:

- scheduled sweeps of what landed in the last week, or monthly full audits
- release gates that block a tag on findings, with a cost ceiling
- repositories without the V12 GitHub app (public repositories only; see
  [Cost and scope](#cost))
- routing results to Slack from CI, with mentions and threads
- code scanning alerts in the Security tab through SARIF
- pipelines that consume the results programmatically (outputs, JSON, SARIF)

V12 also has its own Slack integration; the Slack support here is for teams
that want CI-driven routing instead.

## Quick start

```yaml
permissions: { contents: read, pull-requests: write, checks: write }
steps:
  - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
    with: { fetch-depth: 0 }
  - uses: metarsit/v12-action@v1
    with:
      v12-token: ${{ secrets.V12_TOKEN }}
```

Add that to a `pull_request` workflow and the next push gets a comment. The
default is informative: findings never fail the job until you set
`fail-on`.

## Setup

### 1. Create the token

1. In V12, switch to the **organization that owns the repository**. A token
   is bound to exactly one organization at creation; a token created under
   your personal organization cannot write runs for a team repository, and
   losing membership of the bound organization returns `401`.
2. Go to **Settings -> Developer** and create a personal access token
   (`v12p_*`). It is shown once.
3. **In the scope picker, tick `runs:read` and `runs:write`** (and
   `runs:manage` if you want the action to cancel runs when a workflow is
   cancelled). New tokens default to `runs:read`, `user:read` and
   `repos:read` only, so a token created with the defaults fails the first
   run with `403 missing scope runs:write`. This is the most common
   first-run failure.

### 2. Store it

Add the token as a repository or organization secret named `V12_TOKEN`.
Pull requests from forks do not receive secrets; the action detects that
case and skips with a notice instead of failing.

### 3. Grant permissions

| Surface | Job permission |
|---|---|
| Read the checkout | `contents: read` |
| Sticky pull request comment | `pull-requests: write` |
| Check run with annotations | `checks: write` |
| SARIF upload to code scanning | `security-events: write` |
| Slack | none (uses `slack-webhook` or `slack-bot-token`) |

A missing permission produces a warning and the job summary still carries
the full result.

## Recipes

Every recipe is a complete workflow file from [`examples/`](examples/).

### Pull request review, non-blocking (recommended default)

Use this first. Findings are informative and never block a merge.

<!-- example:pr-review.yml:start -->

```yaml
# V12 review of every pull request, informative only (the recommended
# default): findings land in a sticky comment, a check run and the job
# summary, and never block the merge. Fork pull requests are skipped
# because they have no secrets.
name: V12 security review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

# One review per pull request at a time; a new push cancels the older run
# (the action cancels the V12 run too, so nothing keeps billing).
concurrency:
  group: v12-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write # sticky comment
  checks: write # check run with inline annotations

jobs:
  v12:
    if: ${{ !github.event.pull_request.draft }}
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          fetch-depth: 0 # exact merge base for the diff
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
```

<!-- example:pr-review.yml:end -->

### Pull request review, blocking on critical

Once the team trusts the results, block on the severities you choose and
make the check required in branch protection.

<!-- example:pr-review-blocking.yml:start -->

```yaml
# Same as pr-review.yml, but the job fails when a critical finding survives
# the validity filter. Make the check required in branch protection only
# after the team has used the informative mode for a while.
name: V12 security review (blocking on critical)

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

concurrency:
  group: v12-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write
  checks: write

jobs:
  v12:
    if: ${{ !github.event.pull_request.draft }}
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          fail-on: critical
          include-validity: valid,unreviewed
          max-cost-cents: 5000 # never spend more than $50 on one review
```

<!-- example:pr-review-blocking.yml:end -->

### Weekly diff sweep

Reviews everything that landed in the last seven days; silent and free when
nothing did.

<!-- example:weekly-diff.yml:start -->

```yaml
# Weekly review of everything that landed on the default branch in the last
# seven days. Silent (and free) when nothing landed. Costs one usage-billed
# diff review per week otherwise.
name: V12 weekly diff sweep

on:
  schedule:
    - cron: '0 6 * * 1' # Mondays 06:00 UTC
  workflow_dispatch:

permissions:
  contents: read
  checks: write

jobs:
  v12:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          fetch-depth: 0 # required to resolve the time window
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          mode: diff
          since: '7 days ago'
          max-cost-cents: 10000
          slack-webhook: ${{ secrets.SLACK_WEBHOOK }}
          slack-notify-on: findings
```

<!-- example:weekly-diff.yml:end -->

### Monthly full audit

A fixed-price audit of the whole tree, with a ceiling that must be raised
deliberately as the code grows.

<!-- example:monthly-full.yml:start -->

```yaml
# Monthly full-tree audit of the default branch (fixed price, charged when
# the run starts). The ceiling protects against surprises when the tree
# grows; raise it deliberately.
name: V12 monthly full audit

on:
  schedule:
    - cron: '0 5 1 * *' # first day of the month, 05:00 UTC
  workflow_dispatch:

permissions:
  contents: read
  checks: write
  security-events: write # SARIF into the Security tab

jobs:
  v12:
    runs-on: ubuntu-latest
    timeout-minutes: 240
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          mode: full
          paths: |
            contracts/
            src/
          max-cost-cents: 25000
          wait-timeout-minutes: 180
          upload-sarif: true
```

<!-- example:monthly-full.yml:end -->

### Release-tag gate

Audits the tagged commit and blocks on high and above; a failed or timed-out
run also fails, because "no result" is not a pass for a release.

<!-- example:release-gate.yml:start -->

```yaml
# Full audit of the tagged commit before a release ships. Blocks on high and
# above, and also fails when the V12 run itself fails or times out, because
# "no result" is not a pass for a release gate.
name: V12 release gate

on:
  push:
    tags: ['v*']

permissions:
  contents: read
  checks: write

jobs:
  v12:
    runs-on: ubuntu-latest
    timeout-minutes: 240
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        id: audit
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          mode: full
          fail-on: high
          fail-on-error: true
          wait-timeout-minutes: 180
          slack-webhook: ${{ secrets.SLACK_WEBHOOK }}
          slack-notify-on: always
      - name: Record the audit on the release
        if: always()
        env:
          RUN_URL: ${{ steps.audit.outputs.run-url }}
          CONCLUSION: ${{ steps.audit.outputs.conclusion }}
        run: printf 'V12 run %s finished with conclusion %s\n' "$RUN_URL" "$CONCLUSION"
```

<!-- example:release-gate.yml:end -->

### Manual dispatch with mode selection

<!-- example:manual-dispatch.yml:start -->

```yaml
# Manual run with the mode chosen at dispatch time. Useful for a one-off
# window review, a dry-run estimate, or commenting on a specific pull
# request from a manual run.
name: V12 audit (manual)

on:
  workflow_dispatch:
    inputs:
      mode:
        description: 'What to audit'
        type: choice
        options: [full, diff]
        default: full
      since:
        description: 'Window for diff mode, e.g. "14 days ago"'
        type: string
        default: '14 days ago'
      fail-on:
        description: 'Fail the job at this severity or above'
        type: choice
        options: [none, critical, high, medium, low]
        default: none
      estimate-only:
        description: 'Only print the quote, create nothing'
        type: boolean
        default: false
      pr-number:
        description: 'Pull request to comment on (optional)'
        type: string
        default: ''

permissions:
  contents: read
  checks: write
  pull-requests: write

jobs:
  v12:
    runs-on: ubuntu-latest
    timeout-minutes: 240
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          mode: ${{ inputs.mode }}
          since: ${{ inputs.mode == 'diff' && inputs.since || '' }}
          fail-on: ${{ inputs.fail-on }}
          estimate-only: ${{ inputs.estimate-only }}
          pr-number: ${{ inputs.pr-number }}
```

<!-- example:manual-dispatch.yml:end -->

### SARIF into the Security tab

<!-- example:sarif-security-tab.yml:start -->

```yaml
# Pull request review whose findings also appear as code scanning alerts in
# the Security tab. Either let the action upload (upload-sarif: true) or
# hand the file to github/codeql-action/upload-sarif yourself, shown here.
name: V12 review with SARIF

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

concurrency:
  group: v12-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write
  checks: write
  security-events: write # SARIF upload

jobs:
  v12:
    if: ${{ !github.event.pull_request.draft }}
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        id: audit
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          sarif-path: v12.sarif
      - uses: github/codeql-action/upload-sarif@cdf488f595d80d6e07e03d4674febd5ab45fa938 # v4
        if: steps.audit.outputs.sarif-path != ''
        with:
          sarif_file: ${{ steps.audit.outputs.sarif-path }}
          category: v12-audit/pr
```

<!-- example:sarif-security-tab.yml:end -->

### Slack notification

<!-- example:slack.yml:start -->

```yaml
# Pull request review routed to Slack with a bot token: the message is
# updated in place on every push and later runs reply in its thread, and
# the security team is mentioned on critical findings. Findings link out;
# descriptions and snippets stay out of Slack unless you opt in.
name: V12 review with Slack

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

concurrency:
  group: v12-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write
  checks: write

jobs:
  v12:
    if: ${{ !github.event.pull_request.draft }}
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          slack-bot-token: ${{ secrets.SLACK_BOT_TOKEN }} # needs chat:write, invited to the channel
          slack-channel: C0123456789
          slack-notify-on: findings
          slack-mention-on-critical: '<!subteam^S0123456789>'
          slack-thread: true
```

<!-- example:slack.yml:end -->

### Monorepo: matrix over subdirectories

V12 allows 20 run creations (and 30 estimates) per user per hour, shared
across REST, the CLI and MCP. A matrix of more than 20 packages cannot
finish within an hour on one token; keep it small or serialise it.

<!-- example:monorepo-matrix.yml:start -->

```yaml
# One review per package of a monorepo, each with its own sticky comment.
# V12 allows 20 run creations per user per hour (and 30 estimates), so keep
# the matrix small or serialise it with max-parallel; a matrix of more than
# 20 entries cannot complete within an hour with one token.
name: V12 monorepo review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

concurrency:
  group: v12-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write
  checks: write

jobs:
  v12:
    if: ${{ !github.event.pull_request.draft }}
    runs-on: ubuntu-latest
    timeout-minutes: 90
    strategy:
      fail-fast: false
      max-parallel: 2
      matrix:
        package: [contracts, services/api, packages/crypto]
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          paths: ${{ matrix.package }}/
          comment-key: ${{ matrix.package }}
          check-run-name: V12 Security (${{ matrix.package }})
          sarif-category: v12-audit/${{ matrix.package }}
```

<!-- example:monorepo-matrix.yml:end -->

### Multi-repo: reusable workflow

<!-- example:reusable-workflow.yml:start -->

```yaml
# Reusable workflow for an organization: keep this file in a central
# repository (for example .github/workflows/v12-review.yml in org/.github)
# and call it from every repository with the caller shown in
# multi-repo-caller.yml. Secrets are passed explicitly.
name: V12 review (reusable)

on:
  workflow_call:
    inputs:
      fail-on:
        type: string
        default: none
      max-cost-cents:
        type: string
        default: '5000'
    secrets:
      V12_TOKEN:
        required: true
      SLACK_WEBHOOK:
        required: false
    outputs:
      conclusion:
        value: ${{ jobs.v12.outputs.conclusion }}
      run-url:
        value: ${{ jobs.v12.outputs.run-url }}

permissions:
  contents: read
  pull-requests: write
  checks: write

jobs:
  v12:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    outputs:
      conclusion: ${{ steps.audit.outputs.conclusion }}
      run-url: ${{ steps.audit.outputs.run-url }}
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        id: audit
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          fail-on: ${{ inputs.fail-on }}
          max-cost-cents: ${{ inputs.max-cost-cents }}
          slack-webhook: ${{ secrets.SLACK_WEBHOOK }}
```

<!-- example:reusable-workflow.yml:end -->

<!-- example:multi-repo-caller.yml:start -->

```yaml
# Caller for reusable-workflow.yml, dropped into each repository. The
# organization-level V12_TOKEN secret is one token bound to one V12
# organization; repositories owned by another V12 organization need their
# own token.
name: V12 security review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

concurrency:
  group: v12-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write
  checks: write

jobs:
  review:
    if: ${{ !github.event.pull_request.draft }}
    uses: your-org/.github/.github/workflows/v12-review.yml@main
    with:
      fail-on: none
    secrets:
      V12_TOKEN: ${{ secrets.V12_TOKEN }}
      SLACK_WEBHOOK: ${{ secrets.SLACK_WEBHOOK }}
```

<!-- example:multi-repo-caller.yml:end -->

### Estimate-only dry run

<!-- example:estimate-only.yml:start -->

```yaml
# Dry run: quotes the review of every pull request without creating a run
# or charging anything (one call in the 30-per-hour estimate bucket). Use
# it to size max-cost-cents before enabling reviews, or as a cheap smoke
# test that the token and scopes work.
name: V12 estimate

on:
  pull_request:

permissions:
  contents: read

jobs:
  estimate:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
        with:
          fetch-depth: 0
          persist-credentials: false
      - uses: metarsit/v12-action@v1
        id: quote
        with:
          v12-token: ${{ secrets.V12_TOKEN }}
          estimate-only: true
      - name: Show the quote
        env:
          CENTS: ${{ steps.quote.outputs.estimate-cents }}
          MODE: ${{ steps.quote.outputs.billing-mode }}
        run: printf 'V12 would charge about %s cents (%s billing) for this review\n' "$CENTS" "$MODE"
```

<!-- example:estimate-only.yml:end -->

## Inputs

Inputs win over the config file. Inputs marked "config:" have an empty
default in `action.yml` so that a value from `.github/v12-audit.yml` can
apply; the effective default is stated in the description.

<!-- inputs:start -->

| Input | Description | Required | Default |
|---|---|---|---|
| `v12-token` | V12 personal access token (v12p_*) with the runs:read and runs:write scopes (runs:manage to cancel runs). Create it at v12.sh Settings -> Developer while switched to the organization that owns the repository. Leave empty on pull requests from forks; the action skips them. | false |  |
| `api-url` | V12 base URL. Change only for testing against a stub. | false | `https://v12.sh` |
| `repository` | GitHub repository to audit as owner/name. Defaults to the current repository. | false | `${{ github.repository }}` |
| `mode` | What to audit: auto (infer from the event), pr (diff of the pull request or merge group), diff (a range: since, or base-ref/head-ref), full (the whole tree at branch/sha). | false | `auto` |
| `since` | Time window for diff mode, resolved from git history, e.g. "7 days ago" or "2026-01-31". Needs fetch-depth: 0 on actions/checkout. | false |  |
| `base-ref` | Explicit base ref or SHA for diff mode (overrides since). | false |  |
| `head-ref` | Explicit head ref or SHA for diff mode. Defaults to HEAD. | false |  |
| `branch` | Branch or tag name for full mode. Defaults to the event ref name. | false |  |
| `sha` | Commit SHA for full mode. Defaults to the event SHA. | false |  |
| `name` | Run name shown in V12. Defaults to a name derived from the event. | false |  |
| `paths` | Paths or globs to audit, comma or newline separated. Directory prefixes (contracts/, contracts/**) are sent to V12 and reduce cost; other globs are expanded against the tree (at most 500 entries). Default: whole tree (config: paths.include). | false |  |
| `exclude-paths` | Globs whose findings are hidden, comma or newline separated. Applied by the action, not V12, so they do not reduce cost. Default: none (config: paths.exclude). | false |  |
| `context-documents` | V12 context document UIDs (UUIDs) attached to the run, comma or newline separated. Default: none (config: context-documents). | false |  |
| `config-file` | Path of the repository config file. Default: .github/v12-audit.yml (optional unless set explicitly). | false |  |
| `estimate-only` | Only request the estimate; create nothing. Prints the quote and sets estimate-cents. | false | `false` |
| `max-cost-cents` | Abort before creating a run when the estimate exceeds this many US cents. Default: no ceiling (config: defaults.max-cost-cents). | false |  |
| `skip-if-unchanged` | Skip diff reviews whose range has no changes after path filters, or that V12 quotes at 0 changed lines. Default: true (config: defaults.skip-if-unchanged). | false |  |
| `wait` | Wait for the run to finish. When false the job ends after the run is created. Default: true (config: defaults.wait). | false |  |
| `wait-timeout-minutes` | How long to wait for the run before exiting 0 with state timed_out. Default: 60 (config: defaults.wait-timeout-minutes). | false |  |
| `poll-interval-seconds` | Seconds between status polls (5..3600). Default: 15 (config: defaults.poll-interval-seconds). | false |  |
| `cancel-on-workflow-cancel` | Cancel the V12 run when the workflow is cancelled or the step is interrupted, so a usage-billed review does not keep running. | false | `true` |
| `fetch-report` | Download the Markdown report of a completed run and expose it as report-path. Default: true (config: defaults.fetch-report). | false |  |
| `max-findings-detail` | When V12 returns a summary-only findings list, fetch details for at most this many findings, most severe first. Default: 200 (config: defaults.max-findings-detail). | false |  |
| `fail-on` | Fail the job when a finding at this severity or above survives filtering: none, critical, high, medium, low, info, qa. Default: none (config: defaults.fail-on). | false |  |
| `include-validity` | Validity states that count as findings: valid, unreviewed, acknowledged, invalid. Default: valid,unreviewed (config: defaults.include-validity). | false |  |
| `ignore-auto-invalidated` | Drop findings that V12 auto-invalidated while they are still unreviewed. A reviewer marking a finding valid always wins. Default: false (config: defaults.ignore-auto-invalidated). | false |  |
| `min-severity` | Lowest severity shown on any surface: critical, high, medium, low, info, qa. Default: info, which hides qa (config: defaults.min-severity). | false |  |
| `fail-on-error` | Fail the job when the V12 run ends failed or cancelled, or when waiting times out. Default: false (config: defaults.fail-on-error). | false |  |
| `github-token` | Token for the comment, check run and SARIF upload. Needs pull-requests: write, checks: write and security-events: write respectively. | false | `${{ github.token }}` |
| `comment` | Post or update the sticky pull request comment. Default: true (config: defaults.comment). | false |  |
| `comment-key` | Distinguishes comments when the action runs several times on one pull request (matrix jobs). Defaults to the mode. | false |  |
| `pr-number` | Pull request to comment on when the event carries none (workflow_dispatch). | false |  |
| `hide-comment-when-clean` | Leave no comment when no findings survive filtering; an existing comment is removed. Default: false (config: defaults.hide-comment-when-clean). | false |  |
| `max-comment-findings` | Findings rendered with full details in the comment; the body shrinks further to stay under GitHub's size limit. Default: 25 (config: defaults.max-comment-findings). | false |  |
| `check-run` | Create the check run with inline annotations. Default: true (config: defaults.check-run). | false |  |
| `check-run-name` | Name of the check run. Default: V12 Security (config: defaults.check-run-name). | false |  |
| `max-annotations` | Maximum inline annotations, posted in batches of 50. Default: 200 (config: defaults.max-annotations). | false |  |
| `sarif-path` | Where to write the SARIF file (relative to the workspace). Default: a file under the runner temp directory, exposed as sarif-path. | false |  |
| `upload-sarif` | Upload the SARIF to code scanning from within the action (needs security-events: write; skipped on fork pull requests). Default: false (config: defaults.upload-sarif). | false |  |
| `sarif-category` | Code scanning category. Default: v12-audit/<mode> (config: defaults.sarif-category). | false |  |
| `job-summary` | Write the job summary. Default: true (config: defaults.job-summary). | false |  |
| `slack-webhook` | Slack incoming webhook URL (one-shot messages, no updates). | false |  |
| `slack-bot-token` | Slack bot token (xoxb-*) with chat:write; enables updating the message in place and thread replies. Requires slack-channel. | false |  |
| `slack-channel` | Channel ID for bot-token delivery. Default: none (config: notifications.slack.channel). | false |  |
| `slack-notify-on` | When to notify: always, findings, gate-failure, never. Default: gate-failure (config: notifications.slack.notify-on). | false |  |
| `slack-mention-on-critical` | Mention inserted when a critical finding is present, e.g. <@U0123> or <!subteam^S0123>. Default: none (config: notifications.slack.mention-on-critical). | false |  |
| `slack-thread` | Reply in the thread of the previous message for the same pull request (bot token only). Default: true (config: notifications.slack.thread). | false |  |
| `slack-include-snippets` | Include finding descriptions and code snippets in Slack. Off by default because Slack retention is not the security team's call. Default: false (config: notifications.slack.include-snippets). | false |  |
| `slack-max-findings` | Findings listed in the Slack message. Default: 5 (config: notifications.slack.max-findings). | false |  |

<!-- inputs:end -->

## Outputs

<!-- outputs:start -->

| Output | Description |
|---|---|
| `run-uid` | V12 run UID, empty when no run was created. |
| `run-url` | Link to the run on V12. |
| `state` | Run state as seen by the action: queued, running, completed, failed, cancelled, timed_out, not-created. |
| `conclusion` | success, neutral, failure, skipped, timed_out, cancelled. |
| `skipped-reason` | Why nothing was audited: fork-pr, empty-diff, over-budget, estimate-only, no-previous-commit, branch-deleted, no-matching-paths. |
| `estimate-cents` | Quoted price in US cents (priceCents for fixed billing, estimatedPriceCents for usage billing). |
| `cost-cents` | Realized cost in US cents from the run object, empty until known. |
| `billing-mode` | fixed or usage. |
| `duration-seconds` | Run duration from V12 timestamps. |
| `critical-count` | Critical findings after filtering and suppressions. |
| `high-count` | High findings after filtering and suppressions. |
| `medium-count` | Medium findings after filtering and suppressions. |
| `low-count` | Low findings after filtering and suppressions. |
| `info-count` | Info findings after filtering and suppressions. |
| `qa-count` | QA findings after filtering and suppressions (hidden unless min-severity is qa). |
| `total-count` | All findings after filtering and suppressions. |
| `gate-count` | Findings at or above fail-on. |
| `suppressed-count` | Findings hidden by active suppressions. |
| `new-count` | Findings new since the previous comment on this pull request (empty on the first run). |
| `resolved-count` | Findings resolved since the previous comment on this pull request. |
| `findings-json` | Filtered findings as a JSON array (empty array when larger than 900 KB; use findings-path). |
| `findings-path` | Path of the filtered findings JSON file. |
| `results-path` | Path of the full report JSON (counts, gate, target, cost) every surface renders from. |
| `sarif-path` | Path of the SARIF file. |
| `report-path` | Path of the Markdown report downloaded from V12 (empty when unavailable). |
| `comment-url` | URL of the pull request comment. |
| `check-run-url` | URL of the check run. |
| `slack-ts` | Timestamp of the Slack message (bot token only), usable for chat.update. |
| `work-dir` | Working directory with every intermediate file (config.json, refs.json, estimate.json, report.json, comment.md, summary.md). |

<!-- outputs:end -->

## Config file

An optional `.github/v12-audit.yml` holds repository defaults, path rules,
context documents, suppressions and Slack settings. Inputs set in the
workflow override it. The file is validated against
[`schema/v12-audit.schema.json`](schema/v12-audit.schema.json); the first
line below makes editors autocomplete it. A malformed file fails the job
with every error listed; it never falls back to defaults silently.

<!-- example:v12-audit.yml:start -->

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/metarsit/v12-action/v1/schema/v12-audit.schema.json
#
# Repository defaults for v12-action. Copy to .github/v12-audit.yml.
# Action inputs set in a workflow override anything here.

defaults:
  fail-on: high                       # none | critical | high | medium | low | info | qa
  include-validity: [valid, unreviewed]
  ignore-auto-invalidated: false      # drop V12-auto-invalidated findings while unreviewed
  min-severity: info                  # qa findings stay hidden unless this is qa
  max-cost-cents: 5000                # abort before creating a run quoted above $50.00
  wait-timeout-minutes: 60
  hide-comment-when-clean: false

paths:
  include: ['contracts/**', 'src/crypto/**']   # sent to V12 as prefixes; narrows cost
  exclude: ['**/test/**', '**/mocks/**']       # hides findings; does not reduce cost

# V12 context document UIDs (`v12 context list`), attached to every run.
context-documents:
  - 0197b7e2-72cd-7bb0-b1c6-6f2ae65a2e6d

# Every suppression expires. The fingerprint is printed in each finding's
# details block in the pull request comment and job summary.
suppressions:
  - fingerprint: 'a1b2c3d4e5f60718'
    reason: 'Mitigated by the upstream rate limiter, see SEC-412'
    expires: '2026-12-31'
    approved-by: '@security-team'

notifications:
  slack:
    notify-on: gate-failure           # always | findings | gate-failure | never
    mention-on-critical: '<!subteam^S0123456>'
    thread: true
    include-snippets: false
```

<!-- example:v12-audit.yml:end -->

Suppressions must carry an expiry date. When it passes, the finding is
gated and shown again and the job logs a warning naming the fingerprint and
the date. Suppressed findings stay visible in a collapsed section of the
comment with their reasons. The fingerprint to use is printed in each
finding's details in the comment and job summary.

## Permissions

| Surface | Scope | What happens without it |
|---|---|---|
| Comment | `pull-requests: write` | warning; summary and check run still produced |
| Check run | `checks: write` | warning; comment and summary still produced |
| SARIF upload (`upload-sarif: true`) | `security-events: write` | warning; the SARIF file is still written to `sarif-path` |
| Fork pull requests | secrets are not available | skipped with a notice, `skipped-reason=fork-pr` |

`pull_request_target` runs with the base repository's secrets and can
review fork pull requests. It is dangerous when combined with checking out
and executing the pull request's head: never do that in such a workflow.
This action itself does not need the head code (V12 reads the commits from
GitHub), but any other step in the same job does, so prefer reviewing fork
contributions after merge or on a schedule.

## Cost

Every run costs money, including a cron tick that reviews nothing new
unless the empty-diff skip catches it, so the action protects you in
several ways:

- **Estimate before every run.** `POST /runs/estimate` prices the exact
  commits; the run is created pinned to those commits.
- **`max-cost-cents`** aborts before anything is created when the quote is
  above the ceiling, with a message naming both numbers.
- **`skip-if-unchanged`** (default true) skips diff reviews whose range has
  no changes after path filters, or that V12 quotes at zero changed lines.
- **`estimate-only: true`** prints the quote and creates nothing, for
  sizing the ceiling.
- **Cost in every surface.** The comment footer, check-run summary, job
  summary and Slack message show the estimate and the realized cost.

Two billing modes exist. Full audits are **fixed**: `priceCents` is charged
in full when the run starts, derived from bytes, lines of code and file
count. Diff reviews are **usage**-billed: `estimatedPriceCents` is a
forecast, the run needs only a launch minimum, and realized provider usage
is debited as it goes, so the final cost can land above or below the
estimate. `paths` narrows a full audit and reduces its price; `exclude-paths`
only hides findings and does not.

V12 needs to read the repository: private repositories need the V12 GitHub
app installed; public repositories work without it.

## What a green check means

A green check means no finding at or above `fail-on` survived the filters:
`include-validity` (default `valid,unreviewed`), `ignore-auto-invalidated`,
`min-severity`, `exclude-paths` and the suppressions in the config file. It
does not mean the code is clean, and with the default `fail-on: none` the
check is green whenever the run completed. Read the comment.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `403 ... lacks the 'runs:write' scope` | the token was created with the default scopes | create a new token and tick `runs:write` in the scope picker |
| `401 ... rejected the token` | wrong or expired token, or the token's user left the organization the token is bound to | create a token while switched to the organization that owns the repository |
| `skipped (empty-diff)` on every scheduled run | shallow clone: the window cannot be resolved | set `fetch-depth: 0` on `actions/checkout` (the action unshallows when it can and warns) |
| `skipped (fork-pr)` | pull requests from forks have no secrets | expected; review after merge, on a schedule, or with `pull_request_target` after reading the security notes |
| SARIF upload rejected | job lacks `security-events: write`, or code scanning is disabled | add the permission; enable code scanning; the file is still at `sarif-path` |
| no comment appears | job lacks `pull-requests: write`, or the event is not a pull request | add the permission; for manual runs pass `pr-number` |
| `429 ... runs:write (20 per user per hour)` | too many runs from one user's token, often a matrix | reduce parallelism, spread schedules, or use one token per team |
| `Timed out after N minutes` | the audit is still running on V12 | raise `wait-timeout-minutes`; the job exits 0 and the run continues on V12 |
| `Cannot parse .github/v12-audit.yml: no YAML parser found` | self-hosted runner without `yq` or PyYAML | install mikefarah `yq` (hosted runners have it) |
| `Invalid v12-action configuration` | a typo in the config file or an input | the message lists every error; the schema is linked |

## How it works

1. **Preflight** masks the token, checks for `curl`, `jq` and `git`, and
   records the event. A fork pull request without a token ends here.
2. **Config** merges built-in defaults, `.github/v12-audit.yml` and inputs,
   and validates everything.
3. **Refs** decide the target. Pull requests review from the merge base of
   base and head (not the base branch tip) to the head commit; merge queues
   review the queue's base to head; pushes review before to after; time
   windows are resolved from git history (falling back to the root commit);
   tags and dispatches audit the whole tree. Empty ranges skip.
4. **Estimate, then pin.** The estimate names the exact commits it priced
   (`resolvedFromSha` and `resolvedToSha`, or `sha`); the create call reuses
   them, so a branch that moves between the two calls cannot make you pay
   for one diff and audit another. Over the ceiling stops here.
5. **Create and wait.** Progress is logged in a collapsed group; a timeout
   exits 0; a cancelled workflow cancels the run and follows
   `cancellationPending` to a terminal state so nothing keeps billing.
6. **Collect.** Findings are paged with `totalMatching`; a summary-only
   list triggers per-finding detail calls (most severe first, paced under
   the artifact-read bucket). Each finding gets a fingerprint:
   `sha256(path, normalized title, whitespace-stripped snippet)`, which
   survives line drift and is the identity used for the delta, the
   suppressions and the SARIF `partialFingerprints`.
7. **Filter and gate.** `include-validity` first, then
   `ignore-auto-invalidated`, `min-severity`, `exclude-paths`, then
   suppressions. Auto-invalidation is V12's own triage or proof-of-concept
   verdict and is independent of `validity`, which always carries the
   team's decision: an auto-invalidated finding is dropped only while it is
   still `unreviewed`; a reviewer who marked it `valid` outranks the
   machine.
8. **Render.** One comment, found by a hidden marker and updated in place,
   with the previous run's fingerprints carried in a base64 state block for
   the "2 new, 1 resolved" delta and the Slack thread. Check run, SARIF and
   summary render from the same report; Slack last, so its `ts` can be
   stored.
9. **Gate.** Outputs are published, then the job fails only on `fail-on`
   or `fail-on-error`.

REST with `curl` and `jq` was chosen over the V12 CLI so the action needs
no Node toolchain, and because the REST shapes and pagination are
documented. The reconciliation of the API against the documentation is in
[`docs/api-reconciliation.md`](docs/api-reconciliation.md).

## For coding agents

- [`AGENTS.md`](AGENTS.md): working on this action (layout, invariants,
  tests, release process).
- [`docs/for-agents/SETUP.md`](docs/for-agents/SETUP.md): a self-contained
  guide for an agent adding this action to another repository.
- [`skills/v12-audit/SKILL.md`](skills/v12-audit/SKILL.md): a Claude Code
  skill that wires the action up on request. Install it with:

```sh
mkdir -p .claude/skills/v12-audit && curl -fsSL https://raw.githubusercontent.com/metarsit/v12-action/v1/skills/v12-audit/SKILL.md -o .claude/skills/v12-audit/SKILL.md
```

## Contributing, security, licence

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the development setup, checks
and release process, [`SECURITY.md`](SECURITY.md) for the disclosure policy,
and [`CHANGELOG.md`](CHANGELOG.md) for changes and recorded decisions.
Licensed under the [MIT licence](LICENSE).
