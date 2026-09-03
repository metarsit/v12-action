#!/usr/bin/env bats
# scripts/notify-slack.sh: notify-on policy, webhook delivery, bot-token
# posting, in-place updates and thread replies, error handling, and the
# Block Kit payload golden.

load test_helper

setup_file() { start_stub; }
teardown_file() { stop_stub; }

setup() {
  new_work
  export V12_ACTION_VERSION="1.0.0-test"
  export V12_SLACK_API_URL="$V12_API_URL/slack/api"
  export GITHUB_SERVER_URL="https://github.com" GITHUB_REPOSITORY="acme/vault" GITHUB_RUN_ID="777"
  export GITHUB_WORKSPACE="$V12_WORK_DIR/ws"
  mkdir -p "$GITHUB_WORKSPACE"
  unset V12_SLACK_WEBHOOK V12_SLACK_BOT_TOKEN V12_PRIOR_STATE
}

use_report() { cp "$FIXTURES/report-$1.json" "$V12_WORK_DIR/report.json"; }
slack_requests() { jq -c 'select(.path | startswith("/slack/"))' "$STUB_LOG"; }

@test "default notify-on gate-failure posts only when the job would fail" {
  use_report findings
  make_config V12_INPUT_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok"
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok" run_script notify-slack
  [ "$status" -eq 0 ]
  [ "$(output_value slack-outcome)" = "posted (webhook)" ]
  use_report clean
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok" run_script notify-slack
  [ "$(output_value slack-outcome)" = "skipped (notify-on: gate-failure)" ]
}

@test "notify-on policies: never, always, findings" {
  use_report clean
  make_config V12_INPUT_SLACK_WEBHOOK=x V12_INPUT_SLACK_NOTIFY_ON=never
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok" run_script notify-slack
  [ "$(output_value slack-outcome)" = "skipped (notify-on: never)" ]
  make_config V12_INPUT_SLACK_WEBHOOK=x V12_INPUT_SLACK_NOTIFY_ON=always
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok" run_script notify-slack
  [ "$(output_value slack-outcome)" = "posted (webhook)" ]
  make_config V12_INPUT_SLACK_WEBHOOK=x V12_INPUT_SLACK_NOTIFY_ON=findings
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok" run_script notify-slack
  [ "$(output_value slack-outcome)" = "skipped (notify-on: findings)" ]
  use_report over-budget
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok" run_script notify-slack
  [ "$(output_value slack-outcome)" = "posted (webhook)" ]
  use_report failed
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok" run_script notify-slack
  [ "$(output_value slack-outcome)" = "posted (webhook)" ]
}

@test "nothing configured is a quiet no-op; a failing webhook is a warning" {
  use_report findings
  make_config
  run_script notify-slack
  [ "$status" -eq 0 ]
  [ "$(output_value slack-outcome)" = "not configured" ]
  make_config V12_INPUT_SLACK_WEBHOOK=x
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/bad" run_script notify-slack
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::Slack: webhook delivery failed (HTTP 404"* ]]
  [ "$(output_value slack-outcome)" = "failed (webhook HTTP 404)" ]
}

@test "the Block Kit payload matches the golden and never carries snippets by default" {
  use_report findings
  make_config V12_INPUT_SLACK_WEBHOOK=x V12_INPUT_SLACK_MENTION_ON_CRITICAL='<!subteam^S0123>'
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok" run_script notify-slack
  [ "$status" -eq 0 ]
  local p="$V12_WORK_DIR/slack-payload.json"
  if [ "${UPDATE_GOLDENS:-}" = "1" ]; then cp "$p" "$ROOT/test/golden/findings/slack.json"; fi
  diff -u "$ROOT/test/golden/findings/slack.json" "$p"
  ! grep -q 'msg.sender.call' "$p"
  ! grep -q 'The permit digest' "$p"
  grep -q '<!subteam^S0123>' "$p"
  [ "$(jq '.blocks | length' "$p")" -le 50 ]
  [ "$(jq -r '.blocks[0].text.text | length' "$p")" -le 150 ]
  [ "$(jq -r '[.blocks[] | select(.type == "section" and .accessory != null)] | length' "$p")" = "5" ]
  grep -q '&lt;script&gt;' "$p"
  [ "$(slack_requests | tail -1 | jq -r '.body.text')" = "$(jq -r .text "$p")" ]
}

@test "snippets are included only when opted in" {
  use_report findings
  make_config V12_INPUT_SLACK_WEBHOOK=x V12_INPUT_SLACK_INCLUDE_SNIPPETS=true V12_INPUT_SLACK_MAX_FINDINGS=2
  V12_SLACK_WEBHOOK="$V12_API_URL/slack/webhook/ok" run_script notify-slack
  grep -q 'The permit digest' "$V12_WORK_DIR/slack-payload.json"
  [ "$(jq -r '[.blocks[] | select(.type == "section" and .accessory != null)] | length' "$V12_WORK_DIR/slack-payload.json")" = "2" ]
  grep -q 'and 14 more' "$V12_WORK_DIR/slack-payload.json"
}

@test "bot token posts a new message and returns its ts" {
  use_report findings
  make_config V12_INPUT_SLACK_BOT_TOKEN=x V12_INPUT_SLACK_CHANNEL=C0123
  V12_SLACK_BOT_TOKEN=xoxb-good run_script notify-slack
  [ "$status" -eq 0 ]
  [ "$(output_value slack-outcome)" = "posted" ]
  [[ "$(output_value slack-ts)" == 1700000001.* ]]
  [ "$(output_value slack-channel)" = "C0123" ]
  [[ "$output" == *"::add-mask::xoxb-good"* ]]
  [ "$(slack_requests | tail -1 | jq -r '.path')" = "/slack/api/chat.postMessage" ]
  [ "$(slack_requests | tail -1 | jq -r '.body.channel')" = "C0123" ]
}

@test "bot token updates the previous message in place and replies in its thread" {
  use_report findings
  make_config V12_INPUT_SLACK_BOT_TOKEN=x V12_INPUT_SLACK_CHANNEL=C0123
  V12_SLACK_BOT_TOKEN=xoxb-good V12_PRIOR_STATE='{"slackTs":"1700000000.000100","slackChannel":"C0123"}' run_script notify-slack
  [ "$status" -eq 0 ]
  [ "$(output_value slack-outcome)" = "updated" ]
  [ "$(output_value slack-ts)" = "1700000000.000100" ]
  local last2
  last2=$(slack_requests | tail -2)
  [ "$(sed -n 1p <<<"$last2" | jq -r '.path')" = "/slack/api/chat.update" ]
  [ "$(sed -n 1p <<<"$last2" | jq -r '.body.ts')" = "1700000000.000100" ]
  [ "$(sed -n 2p <<<"$last2" | jq -r '.path')" = "/slack/api/chat.postMessage" ]
  [ "$(sed -n 2p <<<"$last2" | jq -r '.body.thread_ts')" = "1700000000.000100" ]
  grep -q 'Re-run for' <<<"$(sed -n 2p <<<"$last2" | jq -r '.body.text')"
}

@test "slack-thread false updates without a thread reply; a lost message falls back to posting" {
  use_report findings
  make_config V12_INPUT_SLACK_BOT_TOKEN=x V12_INPUT_SLACK_CHANNEL=C0123 V12_INPUT_SLACK_THREAD=false
  V12_SLACK_BOT_TOKEN=xoxb-good V12_PRIOR_STATE='{"slackTs":"1700000000.000100","slackChannel":"C0123"}' run_script notify-slack
  [ "$(output_value slack-outcome)" = "updated" ]
  [ "$(slack_requests | tail -1 | jq -r '.path')" = "/slack/api/chat.update" ]
  V12_SLACK_BOT_TOKEN=xoxb-good V12_PRIOR_STATE='{"slackTs":"1600000000.000000","slackChannel":"C0123"}' run_script notify-slack
  [[ "$output" == *"::warning::Slack: could not update message 1600000000.000000"* ]]
  [[ "$output" == *"message_not_found"* ]]
  [ "$(output_value slack-outcome)" = "posted" ]
}

@test "a different channel in the prior state starts a fresh message" {
  use_report findings
  make_config V12_INPUT_SLACK_BOT_TOKEN=x V12_INPUT_SLACK_CHANNEL=C0999
  V12_SLACK_BOT_TOKEN=xoxb-good V12_PRIOR_STATE='{"slackTs":"1700000000.000100","slackChannel":"C0123"}' run_script notify-slack
  [ "$(output_value slack-outcome)" = "posted" ]
  [[ "$output" == *"posting a new message in C0999"* ]]
}

@test "Slack API errors become warnings with a hint" {
  use_report findings
  make_config V12_INPUT_SLACK_BOT_TOKEN=x V12_INPUT_SLACK_CHANNEL=C-notin
  V12_SLACK_BOT_TOKEN=xoxb-good run_script notify-slack
  [ "$status" -eq 0 ]
  [[ "$output" == *"not_in_channel"* ]]
  [[ "$output" == *"invite the bot"* ]]
  [ "$(output_value slack-outcome)" = "failed (not_in_channel)" ]
  make_config V12_INPUT_SLACK_BOT_TOKEN=x V12_INPUT_SLACK_CHANNEL=C0123
  V12_SLACK_BOT_TOKEN=xoxb-bad run_script notify-slack
  [[ "$output" == *"invalid_auth"* ]]
  [ "$(output_value slack-outcome)" = "failed (invalid_auth)" ]
}
