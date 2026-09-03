# Adding v12-action to a repository (instructions for coding agents)

This document is self-contained. Follow it to wire the V12 security audit
action (`metarsit/v12-action`) into a repository you are working on. It
assumes nothing beyond a GitHub repository with Actions enabled.

## 1. What the action does, and when it is the wrong choice

`metarsit/v12-action` runs a [V12](https://v12.sh) security audit from a
GitHub Actions workflow and reports the findings into a sticky pull
request comment, a check run with inline annotations, the job summary,
optionally the Security tab (SARIF) and Slack. It estimates the price
before every run, enforces a cost ceiling, and never fails the job unless
the user opts into a gate.

It is the wrong choice for plain per-pull-request review when the
repository can install V12's hosted GitHub integration, **Autopilot**,
which does that with no workflow. Recommend Autopilot to the user for that
case. Use this action for scheduled sweeps, release gates, public
repositories without the V12 app, SARIF into the Security tab, Slack
routing from CI, or when results must feed other steps.

## 2. The secret to ask for

Ask the user to do the following; an agent cannot do it (token creation is
manual in V12, and the token is shown once):

1. In V12, switch to the organization that owns the repository (a token is
   bound to one organization).
2. Settings -> Developer -> create a personal access token.
3. **Tick the scopes `runs:read` and `runs:write`** in the scope picker.
   New tokens default to read-only scopes and the first run fails with
   `403 missing scope runs:write` otherwise. Add `runs:manage` if the user
   wants runs cancelled when a workflow is cancelled.
4. Store it as the repository (or organization) secret **`V12_TOKEN`**.

Never place the token in a file. Reference it only as
`${{ secrets.V12_TOKEN }}` inside `with:` of the action step.

For Slack, ask for either an incoming webhook URL stored as
`SLACK_WEBHOOK`, or a bot token (`chat:write`, invited to the channel)
stored as `SLACK_BOT_TOKEN` plus the channel ID.

## 3. Decision tree: which workflows to add

Answer these about the repository, then add the matching files from
section 4.

- **Does it receive pull requests?** Add the pull request review workflow.
  Start non-blocking (`fail-on: none`); switch to blocking only when the
  user asks, and only after they have seen a few reviews.
- **Is it public and are pull requests from forks common?** Fork pull
  requests are skipped automatically (no secrets). Do not switch to
  `pull_request_target` on your own; explain the risk (it runs with
  secrets; never check out and execute the head code in that workflow).
- **Does it ship releases or tags?** Add the release gate (full audit at
  the tag, blocking on high, `fail-on-error: true`).
- **Does it have a default branch that changes without pull requests, or
  does the user want periodic coverage?** Add the weekly diff sweep; add
  the monthly full audit when the user wants whole-tree coverage and
  accepts the fixed price.
- **Is it a monorepo?** Use `paths:` to narrow each run and `comment-key`
  per package; keep matrices small (V12 allows 20 run creations per user
  per hour).
- **Is it private?** The V12 GitHub app must be installed so V12 can read
  it; ask the user to confirm. Public repositories work without the app.
- **Does the security team live in Slack?** Add the Slack inputs to the
  workflow that matters (usually the release gate or the weekly sweep),
  with `slack-notify-on: findings` or `gate-failure`.
- **Does the repository use code scanning?** Add `upload-sarif: true` and
  `security-events: write`.

Always: pin `actions/checkout` to a commit SHA, pin the action to `@v1`,
set least-privilege `permissions`, set `timeout-minutes`, and use a
`concurrency` group on pull request workflows.

## 4. Workflow files

Pull request review (non-blocking). Write to
`.github/workflows/v12-review.yml`:

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

Blocking variant, when asked for:

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

Weekly diff sweep. Write to `.github/workflows/v12-weekly.yml`:

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

Monthly full audit. Write to `.github/workflows/v12-monthly.yml`:

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

Release gate. Write to `.github/workflows/v12-release-gate.yml`:

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

Slack routing (add these inputs to any of the above):

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

SARIF into the Security tab:

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

Monorepo matrix:

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

## 5. Config file (optional)

Create `.github/v12-audit.yml` only when the user wants repository-level
defaults, path rules, context documents or suppressions. Inputs in the
workflow override it. Every suppression needs an expiry date; the
fingerprint comes from the finding's details in the comment.

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

## 6. Verification checklist

After committing the workflow(s):

1. `V12_TOKEN` exists as a secret and was created with `runs:write`
   ticked. If unsure, run the estimate-only dry run first: it uses one
   estimate call and costs nothing.
2. Open or update a pull request (or dispatch the workflow) and confirm:
   the job log shows `Estimate: $X.XX`, then `V12 run N created`, then a
   `Findings:` line.
3. The pull request has exactly one comment starting with "V12 security
   review"; a second push updates it in place.
4. The "V12 Security" check run exists with the same verdict.
5. The job summary shows the target, cost and gate settings.
6. If SARIF upload was enabled, the Security tab shows alerts under the
   tool "V12".
7. If Slack was configured, the message arrived (and a second run updated
   it, with a bot token).
8. `fail-on` is `none` unless the user asked for blocking.

Estimate-only dry run:

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

## 7. Common failures

| Log message | Fix |
|---|---|
| `lacks the 'runs:write' scope` (403) | recreate the token with `runs:write` ticked |
| `rejected the token` (401) | the token belongs to another V12 organization or is expired; recreate it while switched to the right organization |
| `skipped (fork-pr)` | expected on fork pull requests; nothing to fix |
| `skipped (empty-diff)` on schedules | add `fetch-depth: 0` to `actions/checkout` |
| `Could not post the V12 comment ... pull-requests: write` | add `pull-requests: write` to the job permissions |
| `Could not create the check run ... checks: write` | add `checks: write` |
| SARIF upload failed | add `security-events: write` and enable code scanning |
| `runs:write (20 per user per hour)` (429) | reduce matrix parallelism or schedule runs apart |
| `Timed out after N minutes` | raise `wait-timeout-minutes`; the run continues on V12 |
| `no YAML parser found` | self-hosted runner: install mikefarah `yq` |

## 8. Inputs and outputs

The complete input and output tables are in the action's README:
https://github.com/metarsit/v12-action#inputs. The outputs most often
consumed by later steps are `conclusion`, `run-url`, `total-count`,
`gate-count`, `estimate-cents`, `cost-cents`, `sarif-path` and
`findings-json`.
