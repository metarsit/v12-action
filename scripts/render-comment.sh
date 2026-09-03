#!/usr/bin/env bash
# scripts/render-comment.sh - renders the sticky pull request comment body
# from report.json and decides what the comment step should do with it.
#
# Env in:  V12_WORK_DIR (report.json, config.json), V12_ACTION_VERSION,
#          V12_SLACK_TS / V12_SLACK_CHANNEL (optional, stored in the state
#          block so the next run can update the Slack message),
#          V12_COMMENT_CAP (characters, default 60000)
# Files:   $V12_WORK_DIR/comment.md
# Outputs: comment-path, comment-marker, comment-action, comment-chars,
#          comment-skip-reason

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

report_json="$(work_file report.json)"
config_json="$(work_file config.json)"
comment_md="$(work_file comment.md)"
[ -s "$report_json" ] || die "report.json is missing; collect-findings.sh did not run."

key=$(json_get "$config_json" '.commentKey')
[ -n "$key" ] || key=$(json_get "$report_json" '.target.mode')
[ -n "$key" ] || key="audit"
key=$(printf '%s' "$key" | tr -c 'A-Za-z0-9_.:/-' '-' | cut -c1-64)
max_details=$(json_get "$config_json" '.maxCommentFindings')
[ -n "$max_details" ] || max_details=25
cap="${V12_COMMENT_CAP:-60000}"

slack_json='null'
if [ -n "${V12_SLACK_TS:-}" ]; then
  slack_json=$(jq -n --arg ts "$V12_SLACK_TS" --arg ch "${V12_SLACK_CHANNEL:-}" '{ts: $ts, channel: $ch}')
fi

# -j: the file is exactly the body, no trailing newline, so its length is
# what GitHub counts against the 65,536-character limit.
jqx -j --arg key "$key" --arg version "$V12_ACTION_VERSION" --argjson details "$max_details" \
  --argjson slack "$slack_json" --argjson cap "$cap" \
  'include "render"; comment_fitting(.; $key; $version; $details; $slack; $cap)' "$report_json" >"$comment_md"

chars=$(jq -R -s 'length' "$comment_md")
marker=$(jqx -n -r --arg key "$key" 'include "common"; state_marker($key)')

action="update-or-create"
reason=""
clean=$(jq -r '(.skipped == null) and (.run.state == "completed") and (.counts.total == 0) and ((.suppressed | length) == 0)' "$report_json")
if [ "$(json_get "$config_json" '.comment')" != "true" ]; then
  action="skip"
  reason="comment: false"
elif [ "$(jq -r '.target.commentPrNumber // empty' "$report_json")" = "" ]; then
  action="skip"
  reason="not a pull request (set pr-number to comment from a manual run)"
elif [ "$clean" = "true" ] && [ "$(json_get "$config_json" '.hideCommentWhenClean')" = "true" ]; then
  action="delete-if-exists"
  reason="clean run and hide-comment-when-clean is true"
fi

set_output comment-path "$comment_md"
set_output comment-marker "$marker"
set_output comment-action "$action"
set_output comment-chars "$chars"
set_output comment-skip-reason "$reason"
log_info "Comment rendered: ${chars} characters, marker ${marker}, action ${action}${reason:+ ($reason)}"
if [ "${RUNNER_DEBUG:-0}" = "1" ]; then
  group_start "Comment body"
  cat "$comment_md"
  group_end
fi
