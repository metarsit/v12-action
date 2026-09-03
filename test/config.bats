#!/usr/bin/env bats
# scripts/config.sh: defaults, config-file merge, input precedence, validation.

load test_helper

setup() {
  new_work
  WS="$V12_WORK_DIR/ws"
  mkdir -p "$WS/.github"
  export GITHUB_WORKSPACE="$WS"
  export GITHUB_REPOSITORY="acme/vault"
}

cfg() { jq -r "$1" "$V12_WORK_DIR/config.json"; }

@test "built-in defaults apply without a config file or inputs" {
  run_script config
  [ "$status" -eq 0 ]
  [ "$(cfg .mode)" = "auto" ]
  [ "$(cfg .failOn)" = "none" ]
  [ "$(cfg '.includeValidity | join(",")')" = "valid,unreviewed" ]
  [ "$(cfg .ignoreAutoInvalidated)" = "false" ]
  [ "$(cfg .minSeverity)" = "info" ]
  [ "$(cfg .maxCostCents)" = "null" ]
  [ "$(cfg .waitTimeoutMinutes)" = "60" ]
  [ "$(cfg .pollIntervalSeconds)" = "15" ]
  [ "$(cfg .slack.notifyOn)" = "gate-failure" ]
  [ "$(cfg .maxFindingsDetail)" = "200" ]
  [ "$(cfg .configFileLoaded)" = "false" ]
  [ "$(output_value config-file-loaded)" = "false" ]
}

@test "config file values apply and inputs win over them" {
  cp "$ROOT/examples/v12-audit.yml" "$WS/.github/v12-audit.yml"
  V12_INPUT_FAIL_ON=critical V12_INPUT_MAX_COST_CENTS=100 run_script config
  [ "$status" -eq 0 ]
  [ "$(cfg .failOn)" = "critical" ]
  [ "$(cfg .maxCostCents)" = "100" ]
  [ "$(cfg '.paths | join(",")')" = "contracts/**,src/crypto/**" ]
  [ "$(cfg '.excludePaths | join(",")')" = "**/test/**,**/mocks/**" ]
  [ "$(cfg '.contextDocuments[0]')" = "0197b7e2-72cd-7bb0-b1c6-6f2ae65a2e6d" ]
  [ "$(cfg '.suppressions[0].fingerprint')" = "a1b2c3d4e5f60718" ]
  [ "$(cfg '.suppressions[0].expired')" = "false" ]
  [ "$(cfg .slack.mentionOnCritical)" = "<!subteam^S0123456>" ]
  [ "$(cfg .configFileLoaded)" = "true" ]
}

@test "list inputs accept commas and newlines" {
  V12_INPUT_PATHS=$'contracts/**, src/**\n  lib/ ' V12_INPUT_INCLUDE_VALIDITY="valid, acknowledged" run_script config
  [ "$status" -eq 0 ]
  [ "$(cfg '.paths | join("|")')" = "contracts/**|src/**|lib/" ]
  [ "$(cfg '.includeValidity | join("|")')" = "valid|acknowledged" ]
}

@test "booleans and ints are normalised" {
  V12_INPUT_IGNORE_AUTO_INVALIDATED=True V12_INPUT_WAIT_TIMEOUT_MINUTES=" 5 " V12_INPUT_COMMENT=no run_script config
  [ "$status" -eq 0 ]
  [ "$(cfg .ignoreAutoInvalidated)" = "true" ]
  [ "$(cfg .waitTimeoutMinutes)" = "5" ]
  [ "$(cfg .comment)" = "false" ]
}

@test "invalid enum, number and validity inputs fail with every error listed" {
  V12_INPUT_FAIL_ON=severe V12_INPUT_MAX_COST_CENTS=abc V12_INPUT_INCLUDE_VALIDITY="valid,maybe" V12_INPUT_SLACK_NOTIFY_ON=sometimes run_script config
  [ "$status" -eq 1 ]
  [[ "$output" == *"fail-on: 'severe' is not one of none, critical, high, medium, low, info, qa"* ]]
  [[ "$output" == *"max-cost-cents: 'abc' is not a whole number"* ]]
  [[ "$output" == *"include-validity: 'maybe' is not one of"* ]]
  [[ "$output" == *"slack-notify-on: 'sometimes' is not one of always, findings, gate-failure, never"* ]]
  [ "$(grep -c '^::error::' <<<"$output")" -eq 1 ]
}

@test "unknown config keys are a hard failure" {
  printf 'defaults:\n  fail-on: high\n  bogus: 1\nextra: true\n' >"$WS/.github/v12-audit.yml"
  run_script config
  [ "$status" -eq 1 ]
  [[ "$output" == *"defaults: unknown key 'bogus'"* ]]
  [[ "$output" == *"config file: unknown key 'extra'"* ]]
}

@test "suppressions require fingerprint, reason and an expiry date" {
  printf 'suppressions:\n  - fingerprint: abc\n  - fingerprint: 0123456789abcdef\n    reason: ok\n    expires: 2030-02-30\n  - fingerprint: 0123456789abcdef\n    reason: fine\n    expires: "2030-01-01"\n    approved-by: me\n' >"$WS/.github/v12-audit.yml"
  run_script config
  [ "$status" -eq 1 ]
  [[ "$output" == *"suppressions[0].fingerprint: must be the 16-character hex fingerprint"* ]]
  [[ "$output" == *"suppressions[0].reason: a reason is required"* ]]
  [[ "$output" == *"suppressions[0].expires: an expiry date (YYYY-MM-DD) is required; permanent suppressions are not allowed"* ]]
  [[ "$output" == *"suppressions[1].expires: '2030-02-30' is not a valid calendar date"* ]]
  [[ "$output" != *"suppressions[2]"* ]]
}

@test "expired suppressions are flagged, not rejected" {
  printf 'suppressions:\n  - fingerprint: 0123456789abcdef\n    reason: old\n    expires: "2020-01-01"\n' >"$WS/.github/v12-audit.yml"
  run_script config
  [ "$status" -eq 0 ]
  [ "$(cfg '.suppressions[0].expired')" = "true" ]
}

@test "context documents must be UUIDs and at most 100" {
  V12_INPUT_CONTEXT_DOCUMENTS="12,0197b7e2-72cd-7bb0-b1c6-6f2ae65a2e6d" run_script config
  [ "$status" -eq 1 ]
  [[ "$output" == *"context-documents: '12' is not a context document UID"* ]]
  local many
  many=$(python3 -c 'print(",".join("0197b7e2-72cd-7bb0-b1c6-%012d" % i for i in range(101)))')
  V12_INPUT_CONTEXT_DOCUMENTS="$many" run_script config
  [ "$status" -eq 1 ]
  [[ "$output" == *"at most 100 documents"* ]]
}

@test "paths must be repository-relative" {
  V12_INPUT_PATHS="/abs/path,../up" run_script config
  [ "$status" -eq 1 ]
  [[ "$output" == *"paths: '/abs/path' must be relative"* ]]
  [[ "$output" == *"paths: '../up' must be relative"* ]]
}

@test "an explicitly configured but missing config file is an error" {
  V12_INPUT_CONFIG_FILE=".github/nope.yml" run_script config
  [ "$status" -eq 1 ]
  [[ "$output" == *"config-file '.github/nope.yml' was set explicitly but does not exist"* ]]
}

@test "a config file that is not a mapping is rejected" {
  printf -- '- just\n- a list\n' >"$WS/.github/v12-audit.yml"
  run_script config
  [ "$status" -eq 1 ]
  [[ "$output" == *"top level must be a YAML mapping"* ]]
}

@test "an empty config file is accepted" {
  : >"$WS/.github/v12-audit.yml"
  run_script config
  [ "$status" -eq 0 ]
  [ "$(cfg .configFileLoaded)" = "true" ]
}

@test "slack-bot-token without slack-channel is rejected" {
  V12_INPUT_SLACK_BOT_TOKEN=xoxb-1 run_script config
  [ "$status" -eq 1 ]
  [[ "$output" == *"slack-channel is required when slack-bot-token is set"* ]]
}

@test "secrets never land in config.json" {
  V12_INPUT_SLACK_BOT_TOKEN=xoxb-secret-1 V12_INPUT_SLACK_CHANNEL=C1 V12_INPUT_SLACK_WEBHOOK=https://hooks.slack.com/x run_script config
  [ "$status" -eq 0 ]
  ! grep -q 'xoxb-secret' "$V12_WORK_DIR/config.json"
  ! grep -q 'hooks.slack.com' "$V12_WORK_DIR/config.json"
  [ "$(cfg .slack.botTokenConfigured)" = "true" ]
  [ "$(cfg .slack.webhookConfigured)" = "true" ]
}
