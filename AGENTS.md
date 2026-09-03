# AGENTS.md

Guidance for coding agents working on this repository (the action itself).
To add the action to another repository, use `docs/for-agents/SETUP.md`.

## What this is

A composite GitHub Action (`action.yml`) that runs V12 security audits from
CI and reports into the pull request, the check run, code scanning (SARIF),
the job summary and Slack. Bash + jq talk to the V12 REST API with curl;
`actions/github-script` does the GitHub API calls.

## Repository layout

| Path | Concern |
|---|---|
| `action.yml` | Composite wiring. Every input reaches scripts as `V12_INPUT_<NAME>` through `env:`. |
| `scripts/lib.sh` | Logging, outputs, portable sha256, the V12 client (`v12_api`) with retries and error messages. |
| `scripts/preflight.sh` | Token masking, tool checks, event facts (`event.json`), fork-PR skip. |
| `scripts/config.sh` + `scripts/jq/config.jq` | Defaults, config file, inputs merged into `config.json`; validation. |
| `scripts/resolve-refs.sh` | Mode inference and target resolution (`refs.json`): merge base, windows, tags, merge queues, path globs. |
| `scripts/estimate.sh` | `POST /runs/estimate`, cost ceiling, empty-diff skip, pinning (`pinned.json`). |
| `scripts/create-and-wait.sh`, `scripts/cancel-run.sh` | `POST /runs`, polling, timeout, cancellation. |
| `scripts/collect-findings.sh` + `scripts/jq/process.jq` | Pagination, detail fan-out, fingerprints, filters, gate -> `report.json`. |
| `scripts/suppress.sh`, `scripts/delta.sh`, `scripts/gate.sh` | Suppressions, delta vs previous comment, outputs and exit status. |
| `scripts/render-*.sh` + `scripts/jq/render.jq`, `sarif.jq`, `slack.jq` | Comment, check-run payload, job summary, SARIF, Slack payload. |
| `scripts/github/*.js` | github-script modules: comment find/post, check run. |
| `scripts/notify-slack.sh` | Slack delivery. |
| `schema/v12-audit.schema.json` | Config file schema. |
| `test/` | Stub API (`stub-api.py`), bats suites, goldens, fixtures, lints. |
| `scripts/dev/gen-docs.sh` | README table generator (drift-checked in CI). |

Data flows through JSON files in `$V12_WORK_DIR` (a per-run temp dir):
`event.json` -> `config.json` -> `refs.json` -> `estimate.json` / `pinned.json`
-> `run.json` -> `report.json` -> rendered files.

## Invariants that must not break

1. **No `${{ }}` inside any `run:` body** in `action.yml`, workflows or
   examples. Values go through `env:`. `test/lint-workflows.sh` fails CI.
2. **bash 3.2 floor.** No associative arrays, `mapfile`, `${var,,}`, `|&`,
   `&>>`, negative indexes, `local x=$(cmd)`; no GNU-only flags (`sed -i`,
   `grep -P`, `date -d`, `readlink -f`, `stat -c`, `base64 -w`).
   Expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}`.
   `test/lint-bash32.sh` fails CI.
3. **Estimate before create, and pin.** The create body is the estimate body
   plus name/context documents, with `fromRef`/`toRef`/`sha` replaced by the
   SHAs the estimate resolved. `paths` must reach both calls (regression
   test in `test/create-and-wait.bats`).
4. **Auto-invalidation rule.** `ignore-auto-invalidated` drops a finding
   only while it is `unreviewed`; any explicit validity wins.
5. **Never fail the job for a missing surface.** No comment permission, no
   check permission, no Slack, oversized SARIF: warnings and partial
   results. Only the gate (`fail-on`) and `fail-on-error` fail the job.
6. **Untrusted text is escaped.** Titles, descriptions, snippets, paths and
   config values go through `md_cell` / `md_text` / fenced blocks (Markdown)
   or `sl` (Slack), never into shell.
7. **Secrets never land in files or outputs.** `config.json` carries only
   "configured" booleans for Slack credentials.
8. **jq 1.6 compatibility.** No `trim`, `abs`, `toarray`, `pick`,
   `splits/2`, `debug/1`; bind values before `index($v)` (an argument to
   `index` is evaluated against the array); mind that `"" | split("/")` is
   `[]`.

## Running the tests

```
make test          # all offline suites (needs bats, jq, yq, python3, node)
bats test/x.bats   # one suite
make lint          # all linters
make goldens       # regenerate golden files after intentional rendering changes
make fixtures      # regenerate report fixtures after processing changes
make docs          # regenerate README tables from action.yml
```

Test hooks (environment variables, never used by the action itself):
`V12_POLL_INTERVAL_OVERRIDE`, `V12_WAIT_TIMEOUT_SECONDS_OVERRIDE`,
`V12_FINDINGS_PAGE_SIZE`, `V12_DETAIL_PAUSE`, `V12_NOW`, `V12_COMMENT_CAP`,
`V12_SARIF_MAX_RESULTS`, `V12_SARIF_MAX_GZIP_BYTES`, `V12_SLACK_API_URL`.

The stub API (`test/stub-api.py`) selects scenarios by bearer token and
`repoFullName`; its docstring lists them. Background processes in bats must
close fd 3 (`3>&-`) or the suite hangs.

## API facts to keep in mind

See `docs/api-reconciliation.md`. Highlights: `POST /runs` and
`GET /runs/{uid}` nest the run under `run`; the findings list key is
`findings` with `totalMatching`; estimate prices are `priceCents` (fixed)
or `estimatedPriceCents` (usage); context document UIDs are UUIDs;
`runs:write` is limited to 20 per user per hour.

## Release process

Bump `VERSION`, move changelog entries under the version, merge, tag
`vX.Y.Z`. `.github/workflows/release.yml` validates, tests, creates the
release from the changelog and moves the `v1` tag. Record judgement calls
under "Decisions" in `CHANGELOG.md`.
