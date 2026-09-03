# Contributing

Thanks for helping. This document covers the development setup, the checks
every change must pass, and how releases work. Agents working on the
repository should also read `AGENTS.md`.

## Development setup

The action is bash, jq and a little JavaScript for `actions/github-script`.
You need:

- bash (scripts must keep working on bash 3.2, the macOS default)
- curl, jq 1.6 or newer, git, yq (mikefarah, v4)
- Python 3 with `jsonschema` (schema checks) and `pyyaml`
- bats-core 1.10+, shellcheck, shfmt, actionlint, zizmor, yamllint, codespell
- Node 20+ (`node --test` for the github-script modules)

`make help` lists the targets. The important ones:

```
make test        # bats suites against the offline stub API + node tests
make lint        # shellcheck, shfmt, bash 3.2 lint, actionlint, zizmor, yamllint, codespell
make docs        # regenerate the README input/output tables from action.yml
make check       # everything CI runs offline
```

Run a single suite with `bats test/collect.bats`. Set `RUNNER_DEBUG=1` to
see request and response bodies (the token is masked).

## Making a change

1. Branch from `main`.
2. Keep the invariants in `AGENTS.md`: no `${{ }}` in `run:` bodies, bash 3.2
   compatible scripts, estimate before create, the auto-invalidation rule.
3. Add or update tests. Rendering changes update golden files:
   `make goldens` regenerates them; review the diff before committing.
   Processing changes may need `make fixtures` first.
4. If you change `action.yml`, run `make docs` so the README tables match
   (CI fails on drift).
5. Add an entry to `CHANGELOG.md` under "Unreleased". Pull requests labelled
   `feature` or `fix` must touch the changelog.
6. Open a pull request. CI runs lint, the test matrix (ubuntu-latest,
   ubuntu-22.04, macos-latest; jq 1.6 and 1.7), SARIF schema validation
   and the drift checks. Everything runs offline against the stub API; no
   V12 token is needed for CI.

## Branch protection

`main` is protected: pull requests require the CI workflow to pass, a review
from a code owner for `action.yml`, `scripts/`, `schema/`, the workflows and
the stub API (`CODEOWNERS`), linear history, and no force pushes. Tags `v*`
are protected and created only by the release workflow.

## Releases

1. Update `VERSION`, move the "Unreleased" changelog entries under the new
   version heading with the date, and merge to `main`.
2. Tag the commit `vX.Y.Z` and push the tag. The release workflow validates
   `action.yml`, checks that `VERSION` and the changelog match the tag, runs
   the full suite, creates the GitHub release with notes from the changelog,
   and moves the `v1` major tag to the release commit.
3. The Marketplace listing updates from the release; `branding.icon` must
   stay one of the Feather icons GitHub accepts (CI checks it).

## Testing against the real API

CI is fully offline. To exercise the real V12 API, run the
`examples/estimate-only.yml` workflow in a repository that has a
`V12_TOKEN` secret; it costs nothing (one estimate call).
