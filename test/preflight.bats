#!/usr/bin/env bats
# scripts/preflight.sh: token handling, event facts, fork detection.

load test_helper

setup() {
  new_work
  export RUNNER_TEMP="$V12_WORK_DIR"
  export GITHUB_REPOSITORY="acme/vault"
  export GITHUB_SHA="3333333333333333333333333333333333333333"
  export GITHUB_REF="refs/heads/main"
  export GITHUB_REF_NAME="main"
  export GITHUB_REF_TYPE="branch"
  export GITHUB_WORKFLOW_REF="acme/vault/.github/workflows/v12.yml@refs/heads/main"
  export GITHUB_EVENT_PATH="$V12_WORK_DIR/event-payload-in.json"
  printf '{}' >"$GITHUB_EVENT_PATH"
}

work_dir_from_output() { output_value work-dir; }

@test "masks the token and records event facts for a pull request" {
  cp "$FIXTURES/event-pull-request.json" "$GITHUB_EVENT_PATH"
  GITHUB_EVENT_NAME=pull_request V12_TOKEN=v12p_secret123 run_script preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::v12p_secret123"* ]]
  [ "$(output_value skipped)" = "false" ]
  [ "$(output_value is-fork)" = "false" ]
  local wd
  wd=$(work_dir_from_output)
  [ -f "$wd/event.json" ]
  [ "$(jq -r .pr.number "$wd/event.json")" = "12" ]
  [ "$(jq -r .pr.headSha "$wd/event.json")" = "1111111111111111111111111111111111111111" ]
  [ "$(jq -r .workflowPath "$wd/event.json")" = ".github/workflows/v12.yml" ]
  [ "$(jq -r .commentPrNumber "$wd/event.json")" = "12" ]
}

@test "fork pull request without a token is skipped with a notice" {
  cp "$FIXTURES/event-pull-request-fork.json" "$GITHUB_EVENT_PATH"
  GITHUB_EVENT_NAME=pull_request V12_TOKEN= run_script preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::V12 audit skipped: this pull request comes from a fork"* ]]
  [ "$(output_value skipped)" = "true" ]
  [ "$(output_value skipped-reason)" = "fork-pr" ]
  [ "$(output_value conclusion)" = "skipped" ]
  [ "$(output_value is-fork)" = "true" ]
}

@test "missing token outside a fork is a hard error with scope guidance" {
  GITHUB_EVENT_NAME=schedule V12_TOKEN= run_script preflight
  [ "$status" -eq 1 ]
  [[ "$output" == *"v12-token is empty"* ]]
  [[ "$output" == *"runs:read and runs:write"* ]]
}

@test "pull_request_target on a fork warns about executing head code" {
  cp "$FIXTURES/event-pull-request-fork.json" "$GITHUB_EVENT_PATH"
  GITHUB_EVENT_NAME=pull_request_target V12_TOKEN=v12p_x run_script preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Running on pull_request_target for a fork pull request"* ]]
  [ "$(output_value skipped)" = "false" ]
}

@test "an OAuth-looking token gets a warning" {
  GITHUB_EVENT_NAME=schedule V12_TOKEN=v12a_short run_script preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *"expires after one hour"* ]]
}

@test "pr-number input provides the comment target for manual runs" {
  GITHUB_EVENT_NAME=workflow_dispatch V12_TOKEN=v12p_x V12_INPUT_PR_NUMBER=77 run_script preflight
  [ "$status" -eq 0 ]
  [ "$(jq -r .commentPrNumber "$(work_dir_from_output)/event.json")" = "77" ]
  [ "$(jq -r .pr "$(work_dir_from_output)/event.json")" = "null" ]
}

@test "merge_group and push payloads are captured" {
  cp "$FIXTURES/event-merge-group.json" "$GITHUB_EVENT_PATH"
  GITHUB_EVENT_NAME=merge_group V12_TOKEN=v12p_x run_script preflight
  [ "$status" -eq 0 ]
  [ "$(jq -r .mergeGroup.headRef "$(work_dir_from_output)/event.json")" = "refs/heads/gh-readonly-queue/main/pr-12-2222222222222222222222222222222222222222" ]
  cp "$FIXTURES/event-push.json" "$GITHUB_EVENT_PATH"
  GITHUB_EVENT_NAME=push V12_TOKEN=v12p_x run_script preflight
  [ "$status" -eq 0 ]
  [ "$(jq -r .push.before "$(work_dir_from_output)/event.json")" = "2222222222222222222222222222222222222222" ]
}

@test "a missing or malformed event payload does not crash" {
  printf 'not json' >"$GITHUB_EVENT_PATH"
  GITHUB_EVENT_NAME=schedule V12_TOKEN=v12p_x run_script preflight
  [ "$status" -eq 0 ]
  rm -f "$GITHUB_EVENT_PATH"
  GITHUB_EVENT_NAME=schedule V12_TOKEN=v12p_x run_script preflight
  [ "$status" -eq 0 ]
}
