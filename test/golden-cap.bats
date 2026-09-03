#!/usr/bin/env bats
# Comment size cap against a 300-finding run from the stub.

load test_helper

setup_file() { start_stub; }
teardown_file() { stop_stub; }

setup() {
  new_work
  export V12_TOKEN=v12p_ok V12_ACTION_VERSION="1.0.0-test"
  make_config V12_INPUT_FAIL_ON=high V12_INPUT_INCLUDE_VALIDITY=valid,invalid,unreviewed,acknowledged V12_INPUT_MIN_SEVERITY=qa
  make_refs_diff acme/many
  bash "$SCRIPTS/estimate.sh" >/dev/null
  bash "$SCRIPTS/create-and-wait.sh" >/dev/null
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  printf '{}' >"$V12_WORK_DIR/event.json"
}

chars() { jq -R -s 'length' "$V12_WORK_DIR/comment.md"; }

@test "300 findings fit under the 60,000-character cap with a 'more' note" {
  run_script render-comment
  [ "$status" -eq 0 ]
  [ "$(chars)" -le 60000 ]
  grep -q 'more findings), see the full run' "$V12_WORK_DIR/comment.md" || grep -q 'more finding' "$V12_WORK_DIR/comment.md"
  grep -q '<!-- v12-audit-action:state:' "$V12_WORK_DIR/comment.md"
}

@test "a smaller cap drops details, then rows, and finally hard-truncates" {
  V12_COMMENT_CAP=8000 run_script render-comment
  [ "$(chars)" -le 8000 ]
  grep -q '| Severity | Finding | Location |' "$V12_WORK_DIR/comment.md"
  V12_COMMENT_CAP=300 run_script render-comment
  [ "$(chars)" -le 300 ]
}

@test "the check run posts at most max-annotations and SARIF at most 5000 results" {
  bash "$SCRIPTS/render-check.sh" >/dev/null
  [ "$(jq '.annotations | length' "$V12_WORK_DIR/check-run.json")" = "200" ]
  [ "$(jq '.annotationsTotal' "$V12_WORK_DIR/check-run.json")" = "300" ]
  bash "$SCRIPTS/render-sarif.sh" >/dev/null
  [ "$(jq '.runs[0].results | length' "$V12_WORK_DIR/v12.sarif")" = "300" ]
}
