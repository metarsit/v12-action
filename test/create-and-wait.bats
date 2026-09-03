#!/usr/bin/env bats
# scripts/create-and-wait.sh and cancel-run.sh: pinned create body, polling
# to every terminal state, timeout, wait: false, cancellation on signals.

load test_helper

setup_file() { start_stub; }
teardown_file() { stop_stub; }
setup() {
  new_work
  export V12_TOKEN=v12p_ok
}

prepare() { # prepare REPO [config env...]
  local repo="$1"
  shift
  make_config "$@"
  make_refs_diff "$repo"
  bash "$SCRIPTS/estimate.sh" >/dev/null
}
create_body() { stub_requests POST '/api/v1/runs$' | tail -1 | jq -c '.body'; }
runj() { jq -r "$1" "$V12_WORK_DIR/run.json"; }

@test "a completed run yields state, cost, duration and the report" {
  prepare acme/vault
  run_script create-and-wait
  [ "$status" -eq 0 ]
  [ "$(output_value run-uid)" = "42" ]
  [ "$(output_value run-url)" = "https://v12.sh/runs/42" ]
  [ "$(output_value state)" = "completed" ]
  [ "$(output_value cost-cents)" = "1250" ]
  [ "$(output_value duration-seconds)" = "750" ]
  [ "$(output_value waited)" = "true" ]
  [ -s "$(output_value report-path)" ]
  grep -q '# V12 report for run 42' "$(output_value report-path)"
  [[ "$output" == *"::group::Waiting for V12 run 42"* ]]
  [[ "$output" == *"queued: Waiting for a worker"* ]]
  [[ "$output" == *"running: Analyzing 3 files"* ]]
  [[ "$output" == *"::notice::V12 run 42 created"* ]]
  [ "$(cat "$V12_WORK_DIR/run-uid")" = "42" ]
}

@test "the create call is pinned to the estimated commits and carries the name" {
  prepare acme/vault
  run_script create-and-wait
  local body
  body=$(create_body)
  [ "$(jq -r '.diffReviewConfig.fromRef' <<<"$body")" = "2222222222222222222222222222222222222222" ]
  [ "$(jq -r '.diffReviewConfig.toRef' <<<"$body")" = "1111111111111111111111111111111111111111" ]
  [ "$(jq -r '.name' <<<"$body")" = "PR #12 Fix withdraw | reentrancy" ]
  [ "$(jq -r 'has("branch") or has("sha")' <<<"$body")" = "false" ]
}

@test "paths reach both the estimate and the create call (regression)" {
  make_config
  make_refs_diff acme/vault
  jq '.apiPaths = ["contracts/", "src/crypto/"]' "$V12_WORK_DIR/refs.json" >"$V12_WORK_DIR/r.json" && mv "$V12_WORK_DIR/r.json" "$V12_WORK_DIR/refs.json"
  bash "$SCRIPTS/estimate.sh" >/dev/null
  run_script create-and-wait
  [ "$status" -eq 0 ]
  local est cre
  est=$(stub_requests POST /api/v1/runs/estimate | tail -1 | jq -c '.body.paths')
  cre=$(create_body | jq -c '.paths')
  [ "$est" = '["contracts/","src/crypto/"]' ]
  [ "$cre" = "$est" ]
}

@test "context documents are sent on create, not on the estimate" {
  prepare acme/vault V12_INPUT_CONTEXT_DOCUMENTS="0197b7e2-72cd-7bb0-b1c6-6f2ae65a2e6d"
  run_script create-and-wait
  [ "$status" -eq 0 ]
  [ "$(create_body | jq -c '.contextDocumentUids')" = '["0197b7e2-72cd-7bb0-b1c6-6f2ae65a2e6d"]' ]
  [ "$(stub_requests POST /api/v1/runs/estimate | tail -1 | jq -r '.body | has("contextDocumentUids")')" = "false" ]
}

@test "a failed run is reported as a warning, not a job failure" {
  prepare acme/failing
  run_script create-and-wait
  [ "$status" -eq 0 ]
  [ "$(output_value state)" = "failed" ]
  [[ "$output" == *"::warning::V12 run 43 failed: Worker crashed"* ]]
  [ -z "$(output_value report-path)" ]
}

@test "wait: false returns right after creation" {
  prepare acme/slow V12_INPUT_WAIT=false
  run_script create-and-wait
  [ "$status" -eq 0 ]
  [ "$(output_value waited)" = "false" ]
  [ "$(output_value state)" = "queued" ]
  [ "$(output_value run-uid)" = "45" ]
}

@test "a run without a cost field reports an empty cost" {
  prepare acme/nocost
  run_script create-and-wait
  [ "$status" -eq 0 ]
  [ "$(output_value state)" = "completed" ]
  [ "$(output_value cost-cents)" = "" ]
}

@test "waiting times out gracefully and exits 0" {
  prepare acme/slow
  V12_WAIT_TIMEOUT_SECONDS_OVERRIDE=1 run_script create-and-wait
  [ "$status" -eq 0 ]
  [ "$(output_value state)" = "timed_out" ]
  [[ "$output" == *"::warning::Timed out"* ]]
  [[ "$output" == *"continues on V12's side"* ]]
}

@test "cancel-run.sh follows cancellationPending to the terminal state" {
  prepare acme/cancelling V12_INPUT_WAIT=false
  bash "$SCRIPTS/create-and-wait.sh" >/dev/null
  curl -s -H "Authorization: Bearer v12p_ok" "$V12_API_URL/api/v1/runs/44" >/dev/null
  run_script cancel-run 20
  [ "$status" -eq 0 ]
  [[ "$output" == *"finishing the cancellation of run 44"* ]]
  [[ "$output" == *"V12 run 44 is now cancelled"* ]]
  [ "$(runj .state)" = "cancelled" ]
}

@test "cancel-run.sh is a no-op without a run" {
  make_config
  run_script cancel-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to cancel"* ]]
}

# The runner sends SIGINT then SIGTERM to a cancelled step. A non-interactive
# shell starts `&` jobs with SIGINT ignored (so the child cannot trap it),
# which is why this test exercises the same handler through SIGTERM.
@test "SIGTERM while waiting cancels the run and exits 130" {
  prepare acme/slow
  bash "$SCRIPTS/create-and-wait.sh" >"$V12_WORK_DIR/wait.log" 2>&1 3>&- &
  local pid=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$V12_WORK_DIR/run-uid" ] && break
    sleep 0.2
  done
  sleep 0.5
  kill -TERM "$pid"
  rc=0
  wait "$pid" || rc=$?
  [ "${rc:-0}" -eq 130 ]
  [ -n "$(stub_requests POST /api/v1/runs/45/cancel)" ]
  grep -q 'Cancelling V12 run 45' "$V12_WORK_DIR/wait.log"
}

@test "missing runs:write scope fails with the scope name" {
  V12_TOKEN=v12p_readonly prepare acme/vault
  V12_TOKEN=v12p_readonly run_script create-and-wait
  [ "$status" -eq 1 ]
  [[ "$output" == *"lacks the 'runs:write' scope"* ]]
}
