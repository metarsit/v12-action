#!/usr/bin/env bats
# suppress.sh, delta.sh and gate.sh on a completed run.

load test_helper

setup_file() {
  start_stub
  SHARED="$(mktemp -d "$BATS_FILE_TMPDIR/shared.XXXXXX")"
  export SHARED
  (
    V12_WORK_DIR="$SHARED" GITHUB_OUTPUT="$SHARED/outputs.txt"
    : >"$GITHUB_OUTPUT"
    export V12_WORK_DIR GITHUB_OUTPUT V12_TOKEN=v12p_ok
    make_config
    make_refs_diff acme/vault
    bash "$SCRIPTS/estimate.sh" >/dev/null
    bash "$SCRIPTS/create-and-wait.sh" >/dev/null
    bash "$SCRIPTS/collect-findings.sh" >/dev/null
  )
}
teardown_file() { stop_stub; }

setup() {
  new_work
  export V12_TOKEN=v12p_ok
  cp "$SHARED"/{refs.json,run.json,pinned.json,estimate.json,changed-files.json,report.json} "$V12_WORK_DIR/"
  WS="$V12_WORK_DIR/ws"
  mkdir -p "$WS/.github"
  export GITHUB_WORKSPACE="$WS"
}
rep() { jq -r "$1" "$V12_WORK_DIR/report.json"; }
fp_of() { jq -r --argjson u "$1" '.findings[] | select(.uid == $u) | .fingerprint' "$SHARED/report.json"; }

@test "an active suppression moves the finding out of the gate" {
  printf 'suppressions:\n  - fingerprint: "%s"\n    reason: "Mitigated upstream, SEC-1"\n    expires: "2099-01-01"\n    approved-by: "@sec"\n' "$(fp_of 101)" >"$WS/.github/v12-audit.yml"
  make_config V12_INPUT_FAIL_ON=critical
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  local before
  before=$(rep .gate.count)
  run_script suppress
  [ "$status" -eq 0 ]
  [ "$(rep '.suppressed | length')" = "1" ]
  [ "$(rep '.suppressed[0].uid')" = "101" ]
  [ "$(rep '.suppressed[0].suppression.reason')" = "Mitigated upstream, SEC-1" ]
  [ "$(rep .gate.count)" = "$((before - 1))" ]
  [ "$(rep '.findings | map(.uid) | index(101)')" = "null" ]
  [ "$(output_value suppressed-count)" = "1" ]
}

@test "an expired suppression re-surfaces the finding with a warning naming the expiry" {
  printf 'suppressions:\n  - fingerprint: "%s"\n    reason: "was mitigated"\n    expires: "2020-01-01"\n' "$(fp_of 101)" >"$WS/.github/v12-audit.yml"
  make_config
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  run_script suppress
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Suppression $(fp_of 101) expired on 2020-01-01 and no longer applies"* ]]
  [ "$(rep '.suppressed | length')" = "0" ]
  [ "$(rep '.expiredSuppressions[0].matched')" = "true" ]
  [ "$(rep '.findings | map(.uid) | index(101) != null')" = "true" ]
}

@test "suppressions that match nothing are reported" {
  printf 'suppressions:\n  - fingerprint: "0000000000000000"\n    reason: "gone"\n    expires: "2099-01-01"\n' >"$WS/.github/v12-audit.yml"
  make_config
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  run_script suppress
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 suppression(s) match no current finding: 0000000000000000"* ]]
}

@test "delta counts new, resolved and unchanged fingerprints" {
  make_config
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  local prior
  prior=$(jq -c '{v: 1, sha: "abcdef0123456789", run: 41, fps: ([.findings[0:5][].fingerprint] + ["ffffffffffffffff", "eeeeeeeeeeeeeeee"])}' "$V12_WORK_DIR/report.json")
  V12_PRIOR_STATE="$prior" run_script delta
  [ "$status" -eq 0 ]
  local total
  total=$(rep .counts.total)
  [ "$(rep .delta.newCount)" = "$((total - 5))" ]
  [ "$(rep .delta.resolvedCount)" = "2" ]
  [ "$(rep .delta.unchangedCount)" = "5" ]
  [ "$(rep .delta.priorSha)" = "abcdef0123456789" ]
  [ "$(rep '.findings[0].isNew')" = "false" ]
  [ "$(rep '.findings[-1].isNew')" = "true" ]
  [ "$(output_value new-count)" = "$((total - 5))" ]
  [ "$(output_value resolved-count)" = "2" ]
  [[ "$output" == *"Delta since abcdef0"* ]]
}

@test "delta handles duplicate fingerprints as a multiset" {
  make_config
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  local dup prior
  dup=$(fp_of 105)
  prior=$(jq -n --arg fp "$dup" '{v: 1, sha: "x", fps: [$fp]}')
  V12_PRIOR_STATE="$prior" run_script delta
  [ "$(jq -r --arg fp "$dup" '.delta.new | map(select(.fp == $fp)) | .[0].count' "$V12_WORK_DIR/report.json")" = "1" ]
}

@test "no prior state means no delta" {
  make_config
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  V12_PRIOR_STATE="" run_script delta
  [ "$status" -eq 0 ]
  [ "$(rep .delta)" = "null" ]
  [ "$(output_value new-count)" = "" ]
}

@test "gate exits 1 when findings reach fail-on, after publishing outputs" {
  make_config V12_INPUT_FAIL_ON=high
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  run_script gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::V12 gate failed"* ]]
  [ "$(output_value conclusion)" = "failure" ]
  [ "$(output_value gate-count)" = "$(rep .gate.count)" ]
  [ "$(output_value critical-count)" = "$(rep .counts.critical)" ]
  [ "$(output_value total-count)" = "$(rep .counts.total)" ]
  [ "$(output_value findings-json | jq 'length')" = "$(rep .counts.total)" ]
  [ -s "$(output_value findings-path)" ]
}

@test "gate passes with fail-on none" {
  make_config
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  run_script gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"V12 gate passed"* ]]
  [ "$(output_value conclusion)" = "neutral" ]
}

@test "fail-on-error fails the job for a failed run" {
  make_config V12_INPUT_FAIL_ON=none V12_INPUT_FAIL_ON_ERROR=true
  make_refs_diff acme/failing
  bash "$SCRIPTS/estimate.sh" >/dev/null
  bash "$SCRIPTS/create-and-wait.sh" >/dev/null
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  run_script gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"ended in state 'failed' and fail-on-error is true"* ]]
}

@test "skipped reports exit 0" {
  make_config V12_INPUT_MAX_COST_CENTS=1 V12_INPUT_FAIL_ON=critical
  make_refs_diff acme/vault
  bash "$SCRIPTS/estimate.sh" >/dev/null
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  run_script gate
  [ "$status" -eq 0 ]
  [ "$(output_value conclusion)" = "skipped" ]
  [ "$(output_value total-count)" = "0" ]
}
