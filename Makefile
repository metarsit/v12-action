# v12-action developer targets. CI runs the same commands.

SHELL := /usr/bin/env bash
SCRIPTS := $(wildcard scripts/*.sh)
TEST_SCRIPTS := $(wildcard test/*.sh) test/test_helper.bash
BATS_FILES := test/lib.bats test/config.bats test/preflight.bats test/resolve-refs.bats test/estimate.bats \
  test/create-and-wait.bats test/collect.bats test/report.bats test/golden.bats test/golden-cap.bats test/slack.bats

.PHONY: help test test-bats test-js lint lint-shell lint-bash32 lint-actions lint-yaml lint-spell fixtures goldens docs docs-check check

help: ## list targets
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-14s %s\n", $$1, $$2}'

test: test-bats test-js ## run every offline test

test-bats: ## bats suites against the stub API
	bats $(wildcard $(BATS_FILES))

test-js: ## node unit tests for the github-script modules
	node --test test/js/*.test.js

lint: lint-shell lint-bash32 lint-actions lint-yaml lint-spell ## every linter

lint-shell: ## shellcheck + shfmt
	shellcheck -x -S style $(SCRIPTS) $(TEST_SCRIPTS)
	shfmt -d $(SCRIPTS) $(TEST_SCRIPTS)

lint-bash32: ## reject bash 4+ features and GNU-only flags
	bash test/lint-bash32.sh

ZIZMOR_FLAGS ?= --offline
WORKFLOW_EXAMPLES := $(filter-out examples/v12-audit.yml,$(wildcard examples/*.yml))

lint-actions: ## actionlint, zizmor and the custom workflow lints
	actionlint .github/workflows/*.yml $(WORKFLOW_EXAMPLES)
	zizmor $(ZIZMOR_FLAGS) --min-severity low .
	bash test/lint-workflows.sh
	bash test/lint-inputs.sh
	bash test/lint-branding.sh

lint-yaml: ## yamllint with the committed config
	yamllint -c .yamllint.yml .

lint-spell: ## codespell
	codespell

fixtures: ## regenerate test/fixtures/report-*.json from the stub
	bash test/make-fixtures.sh

goldens: ## regenerate test/golden from the fixtures (review the diff)
	UPDATE_GOLDENS=1 bats test/golden.bats

docs: ## regenerate the README input/output tables from action.yml
	bash scripts/dev/gen-docs.sh --write

docs-check: ## fail when the README tables drift from action.yml
	bash scripts/dev/gen-docs.sh --check

check: lint test docs-check ## everything CI runs offline
