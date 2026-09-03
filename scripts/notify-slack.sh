#!/usr/bin/env bash
# scripts/notify-slack.sh - Slack delivery: incoming webhook or bot token.
#
# With a bot token the message is updated in place on re-runs (chat.update
# on the ts stored in the previous PR comment) and, with slack-thread true,
# a short reply is added to the thread. Webhooks cannot edit messages.
#
# Env in:  V12_WORK_DIR (report.json, config.json), V12_SLACK_WEBHOOK,
#          V12_SLACK_BOT_TOKEN, V12_SLACK_API_URL (default https://slack.com/api),
#          V12_PRIOR_STATE (JSON from the previous comment; slackTs/slackChannel),
#          V12_ACTION_VERSION, GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID
# Files:   $V12_WORK_DIR/slack-payload.json
# Outputs: slack-outcome, slack-ts, slack-channel, slack-payload-path

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

report_json="$(work_file report.json)"
config_json="$(work_file config.json)"
payload_json="$(work_file slack-payload.json)"
[ -s "$report_json" ] || die "report.json is missing; collect-findings.sh did not run."

mask "${V12_SLACK_WEBHOOK:-}"
mask "${V12_SLACK_BOT_TOKEN:-}"
api_url="${V12_SLACK_API_URL:-https://slack.com/api}"

finish() {
  # finish OUTCOME [TS] [CHANNEL]
  set_output slack-outcome "$1"
  set_output slack-ts "${2:-}"
  set_output slack-channel "${3:-}"
  set_output slack-payload-path "$payload_json"
  exit 0
}

notify_on=$(json_get "$config_json" '.slack.notifyOn')
should=$(jq -r --arg on "$notify_on" '
  (.counts.total > 0) as $findings
  | (.run.state | IN("failed", "cancelled", "timed_out")) as $trouble
  | ((.skipped // {}).reason == "over-budget") as $budget
  | if $on == "never" then false
    elif $on == "always" then true
    elif $on == "findings" then ($findings or $trouble or $budget)
    else .jobShouldFail end' "$report_json")

workflow_url=""
if [ -n "${GITHUB_SERVER_URL:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  workflow_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi
ctx=$(jq -n --arg version "$V12_ACTION_VERSION" --arg workflowUrl "$workflow_url" '{version: $version, workflowUrl: $workflowUrl}')
jqx --slurpfile cfg "$config_json" --argjson ctx "$ctx" 'include "slack"; slack_message(.; $cfg[0].slack; $ctx)' "$report_json" >"$payload_json"

if [ "$should" != "true" ]; then
  log_info "Slack: not notifying (slack-notify-on: ${notify_on})."
  finish "skipped (notify-on: ${notify_on})"
fi
if [ -z "${V12_SLACK_WEBHOOK:-}" ] && [ -z "${V12_SLACK_BOT_TOKEN:-}" ]; then
  log_info "Slack: no webhook or bot token configured."
  finish "not configured"
fi

# slack_post URL BODY_FILE [TOKEN] - one request with a single 429 retry.
# Sets SLACK_STATUS and SLACK_RESP.
SLACK_STATUS=""
SLACK_RESP="$(work_file slack-response.json)"
slack_post() {
  local url="$1" body="$2" token="${3:-}" attempt rc
  for attempt in 1 2; do
    rc=0
    if [ -n "$token" ]; then
      SLACK_STATUS=$(curl -sS --max-time 30 -o "$SLACK_RESP" -w '%{http_code}' -X POST -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json; charset=utf-8' --data-binary "@${body}" "$url") || rc=$?
    else
      SLACK_STATUS=$(curl -sS --max-time 30 -o "$SLACK_RESP" -w '%{http_code}' -X POST -H 'Content-Type: application/json; charset=utf-8' --data-binary "@${body}" "$url") || rc=$?
    fi
    [ "$rc" -eq 0 ] || SLACK_STATUS="000"
    if [ "$SLACK_STATUS" = "429" ] && [ "$attempt" -eq 1 ]; then
      sleep 2
      continue
    fi
    break
  done
  log_debug "slack <- ${SLACK_STATUS} $(head -c 500 "$SLACK_RESP" 2>/dev/null || true)"
}

slack_error_hint() {
  local err="$1"
  case "$err" in
    not_in_channel) printf 'invite the bot to the channel (/invite @your-bot).' ;;
    channel_not_found) printf 'check slack-channel (use the channel ID, e.g. C0123456789).' ;;
    invalid_auth | not_authed | token_revoked | account_inactive) printf 'the bot token is invalid or revoked.' ;;
    missing_scope) printf 'the bot token needs the chat:write scope.' ;;
    message_not_found | cant_update_message) printf 'the previous message no longer exists; a new one will be posted next time.' ;;
    *) printf '' ;;
  esac
}

if [ -n "${V12_SLACK_BOT_TOKEN:-}" ]; then
  channel=$(json_get "$config_json" '.slack.channel')
  [ -n "$channel" ] || die "slack-channel is required with slack-bot-token."
  thread=$(json_get "$config_json" '.slack.thread')
  prior_ts=""
  prior_channel=""
  if [ -n "${V12_PRIOR_STATE:-}" ] && printf '%s' "$V12_PRIOR_STATE" | jq -e 'type == "object"' >/dev/null 2>&1; then
    prior_ts=$(printf '%s' "$V12_PRIOR_STATE" | jq -r '.slackTs // empty')
    prior_channel=$(printf '%s' "$V12_PRIOR_STATE" | jq -r '.slackChannel // empty')
  fi
  if [ -n "$prior_ts" ] && [ -n "$prior_channel" ] && [ "$prior_channel" != "$channel" ]; then
    log_info "Slack: the previous message lives in ${prior_channel}; posting a new message in ${channel}."
    prior_ts=""
  fi

  if [ -n "$prior_ts" ]; then
    jq --arg channel "$channel" --arg ts "$prior_ts" '. + {channel: $channel, ts: $ts}' "$payload_json" >"$(work_file slack-update.json)"
    slack_post "${api_url%/}/chat.update" "$(work_file slack-update.json)" "$V12_SLACK_BOT_TOKEN"
    if [ "$SLACK_STATUS" = "200" ] && [ "$(jq -r '.ok' "$SLACK_RESP" 2>/dev/null)" = "true" ]; then
      log_info "Slack: updated the existing message ${prior_ts} in ${channel}."
      if [ "$thread" = "true" ]; then
        jqx --argjson ctx "$ctx" --arg channel "$channel" --arg ts "$prior_ts" 'include "slack"; slack_thread_reply(.; $ctx) + {channel: $channel, thread_ts: $ts}' "$report_json" >"$(work_file slack-reply.json)"
        slack_post "${api_url%/}/chat.postMessage" "$(work_file slack-reply.json)" "$V12_SLACK_BOT_TOKEN"
        if [ "$SLACK_STATUS" != "200" ] || [ "$(jq -r '.ok' "$SLACK_RESP" 2>/dev/null)" != "true" ]; then
          log_warning "Slack: could not post the thread reply (HTTP ${SLACK_STATUS}, $(jq -r '.error // "unknown error"' "$SLACK_RESP" 2>/dev/null))."
        fi
      fi
      finish "updated" "$prior_ts" "$channel"
    fi
    err=$(jq -r '.error // empty' "$SLACK_RESP" 2>/dev/null || true)
    log_warning "Slack: could not update message ${prior_ts} (HTTP ${SLACK_STATUS}, ${err:-no error code}); posting a new message. $(slack_error_hint "$err")"
  fi

  jq --arg channel "$channel" '. + {channel: $channel, unfurl_links: false, unfurl_media: false}' "$payload_json" >"$(work_file slack-post.json)"
  slack_post "${api_url%/}/chat.postMessage" "$(work_file slack-post.json)" "$V12_SLACK_BOT_TOKEN"
  if [ "$SLACK_STATUS" = "200" ] && [ "$(jq -r '.ok' "$SLACK_RESP" 2>/dev/null)" = "true" ]; then
    ts=$(jq -r '.ts // empty' "$SLACK_RESP")
    log_info "Slack: posted to ${channel} (ts ${ts})."
    finish "posted" "$ts" "$channel"
  fi
  err=$(jq -r '.error // empty' "$SLACK_RESP" 2>/dev/null || true)
  log_warning "Slack: chat.postMessage failed (HTTP ${SLACK_STATUS}, ${err:-no error code}). $(slack_error_hint "$err") The audit result is still in the job summary and pull request comment."
  finish "failed (${err:-HTTP $SLACK_STATUS})"
fi

# Incoming webhook: one-shot, no update possible.
slack_post "$V12_SLACK_WEBHOOK" "$payload_json"
if [ "$SLACK_STATUS" = "200" ]; then
  log_info "Slack: webhook delivered."
  finish "posted (webhook)"
fi
log_warning "Slack: webhook delivery failed (HTTP ${SLACK_STATUS}: $(head -c 200 "$SLACK_RESP" 2>/dev/null | tr '\n' ' ')). Check the webhook URL; the audit result is still in the job summary and pull request comment."
finish "failed (webhook HTTP ${SLACK_STATUS})"
