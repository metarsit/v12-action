#!/usr/bin/env bats
# scripts/estimate.sh: request shape, cost ceiling, empty diffs, pinning,
# estimate-only and error handling against the stub.

load test_helper

setup_file() { start_stub; }
teardown_file() { stop_stub; }
setup() {
  new_work
  export V12_TOKEN=v12p_ok
}

est() { jq -r "$1" "$V12_WORK_DIR/estimate.json"; }
pinned() { jq -r "$1" "$V12_WORK_DIR/pinned.json"; }
last_estimate_body() { stub_requests POST /api/v1/runs/estimate | tail -1 | jq -c '.body'; }

@test "diff review sends diffReviewConfig with SHAs and no branch/sha" {
  make_config
  make_refs_diff
  run_script estimate
  [ "$status" -eq 0 ]
  local body
  body=$(last_estimate_body)
  [ "$(jq -r '.source' <<<"$body")" = "github" ]
  [ "$(jq -r '.repoFullName' <<<"$body")" = "acme/vault" ]
  [ "$(jq -r '.diffReviewConfig.fromRef' <<<"$body")" = "2222222222222222222222222222222222222222" ]
  [ "$(jq -r '.diffReviewConfig.toRef' <<<"$body")" = "1111111111111111111111111111111111111111" ]
  [ "$(jq -r 'has("branch") or has("sha") or has("name") or has("paths")' <<<"$body")" = "false" ]
  [ "$(output_value estimate-cents)" = "1250" ]
  [ "$(output_value billing-mode)" = "usage" ]
  [ "$(output_value scope-files)" = "3" ]
  [ "$(output_value skipped)" = "false" ]
  [[ "$output" == *"Usage billing"* ]]
}

@test "full audit sends branch and sha and pins to resolved.sha" {
  make_config
  make_refs_full
  run_script estimate
  [ "$status" -eq 0 ]
  local body
  body=$(last_estimate_body)
  [ "$(jq -r '.branch' <<<"$body")" = "main" ]
  [ "$(jq -r '.sha' <<<"$body")" = "3333333333333333333333333333333333333333" ]
  [ "$(jq -r 'has("diffReviewConfig")' <<<"$body")" = "false" ]
  [ "$(output_value estimate-cents)" = "9900" ]
  [ "$(output_value billing-mode)" = "fixed" ]
  [ "$(pinned .sha)" = "3333333333333333333333333333333333333333" ]
  [ "$(pinned .pinnedSha)" = "true" ]
}

@test "paths reach the estimate call" {
  make_config
  make_refs_diff
  jq '.apiPaths = ["contracts/"]' "$V12_WORK_DIR/refs.json" >"$V12_WORK_DIR/r.json" && mv "$V12_WORK_DIR/r.json" "$V12_WORK_DIR/refs.json"
  run_script estimate
  [ "$status" -eq 0 ]
  [ "$(last_estimate_body | jq -c '.paths')" = '["contracts/"]' ]
  [ "$(output_value scope-files)" = "2" ]
}

@test "pinned refs come from resolvedFromSha/resolvedToSha" {
  make_config
  make_refs_diff
  run_script estimate
  [ "$(pinned .fromRef)" = "2222222222222222222222222222222222222222" ]
  [ "$(pinned .toRef)" = "1111111111111111111111111111111111111111" ]
  [ "$(pinned .pinnedFrom)" = "true" ]
  [ "$(pinned .quoteCents)" = "1250" ]
  [[ "$output" == *"Pinned to the commits V12 priced"* ]]
}

@test "the cost ceiling aborts before anything is created" {
  make_config V12_INPUT_MAX_COST_CENTS=1000
  make_refs_diff
  run_script estimate
  [ "$status" -eq 0 ]
  [ "$(output_value skipped)" = "true" ]
  [ "$(output_value skipped-reason)" = "over-budget" ]
  [[ "$output" == *"quoted \$12.50"* ]]
  [[ "$output" == *"ceiling of \$10.00"* ]]
  [ -z "$(stub_requests POST '/api/v1/runs$')" ]
  [ "$(jq -r .skippedReason "$V12_WORK_DIR/refs.json")" = "over-budget" ]
}

@test "a quote equal to the ceiling proceeds" {
  make_config V12_INPUT_MAX_COST_CENTS=1250
  make_refs_diff
  run_script estimate
  [ "$status" -eq 0 ]
  [ "$(output_value skipped)" = "false" ]
}

@test "zero billable changed lines skips the diff review" {
  make_config
  make_refs_diff acme/empty
  run_script estimate
  [ "$status" -eq 0 ]
  [ "$(output_value skipped-reason)" = "empty-diff" ]
  [[ "$output" == *"0 billable changed lines"* ]]
}

@test "skip-if-unchanged false keeps an empty diff" {
  make_config V12_INPUT_SKIP_IF_UNCHANGED=false
  make_refs_diff acme/empty
  run_script estimate
  [ "$status" -eq 0 ]
  [ "$(output_value skipped)" = "false" ]
}

@test "estimate-only stops after the quote" {
  make_config V12_INPUT_ESTIMATE_ONLY=true
  make_refs_full
  run_script estimate
  [ "$status" -eq 0 ]
  [ "$(output_value skipped)" = "true" ]
  [ "$(output_value skipped-reason)" = "estimate-only" ]
  [ "$(output_value conclusion)" = "skipped" ]
  [ "$(output_value estimate-cents)" = "9900" ]
  [[ "$output" == *"::notice::estimate-only: V12 quoted \$99.00"* ]]
}

@test "an unexpected estimate shape fails loudly" {
  make_config
  make_refs_full acme/badshape
  run_script estimate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected estimate response from V12 (no 'estimate' object)"* ]]
}

@test "a 400 surfaces the server message" {
  make_config
  make_refs_full acme/reject
  run_script estimate
  [ "$status" -eq 1 ]
  [[ "$output" == *"(HTTP 400)"* ]]
  [[ "$output" == *"Server message: repository acme/reject is not accessible"* ]]
  [[ "$output" == *"private repositories need the V12 GitHub app installed"* ]]
}

@test "a 401 explains the token and organization binding" {
  V12_TOKEN=v12p_bad make_config
  make_refs_full
  V12_TOKEN=v12p_bad run_script estimate
  [ "$status" -eq 1 ]
  [[ "$output" == *"rejected the token (401)"* ]]
}

@test "a rate-limited estimate is retried" {
  make_config
  make_refs_full
  V12_TOKEN=v12p_ratelimit run_script estimate
  [ "$status" -eq 0 ]
  [[ "$output" == *"rate limit (429)"* ]]
  [ "$(output_value estimate-cents)" = "9900" ]
}
