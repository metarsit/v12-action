#!/usr/bin/env bash
# scripts/create-and-wait.sh - creates the run pinned to the estimated
# commits, then polls it to a terminal state.
#
# Env in:  V12_TOKEN, V12_API_URL, V12_WORK_DIR (config.json, refs.json,
#          request-body.json, pinned.json)
# Files:   $V12_WORK_DIR/run-uid, run.json, create-response.json, report.md
# Outputs: run-uid, run-url, state, duration-seconds, cost-cents, report-path,
#          waited

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

config_json="$(work_file config.json)"
refs_json="$(work_file refs.json)"
body_json="$(work_file request-body.json)"
pinned_json="$(work_file pinned.json)"
create_body="$(work_file create-body.json)"
run_json="$(work_file run.json)"
uid_file="$(work_file run-uid)"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Layer name, context documents and the pinned refs on the shared body.
jq -n --slurpfile body "$body_json" --slurpfile pinned "$pinned_json" --slurpfile refs "$refs_json" --slurpfile cfg "$config_json" '
  ($body[0]) as $b | ($pinned[0]) as $p | ($refs[0]) as $r | ($cfg[0]) as $c
  | $b
  | .name = $r.runName
  | (if ($c.contextDocuments | length) > 0 then .contextDocumentUids = $c.contextDocuments else . end)
  | (if $r.kind == "diff"
     then .diffReviewConfig = {fromRef: $p.fromRef, toRef: $p.toRef}
     else (.branch = $p.branch | (if ($p.sha // "") != "" then .sha = $p.sha else . end))
     end)' >"$create_body"

log_info "Creating V12 run '$(jq -r '.name' "$create_body")'..."
if ! v12_api POST /runs "$create_body"; then
  v12_fail POST /runs
fi
cp "$V12_RESP" "$(work_file create-response.json)"
if ! jq -e '.run.uid != null' "$V12_RESP" >/dev/null 2>&1; then
  die "Unexpected create response from V12 (no run.uid): $(head -c 500 "$V12_RESP")"
fi
jq '.run' "$V12_RESP" >"$run_json"
uid=$(json_get "$run_json" '.uid')
printf '%s\n' "$uid" >"$uid_file"
run_url=$(json_get "$run_json" '.webUrl')
[ -n "$run_url" ] || run_url="${V12_API_URL%/}/runs/${uid}"
set_output run-uid "$uid"
set_output run-url "$run_url"
log_notice "V12 run ${uid} created: ${run_url}"

# The create response carries the quote V12 charged/started with.
if jq -e '.estimate | type == "object"' "$V12_RESP" >/dev/null 2>&1; then
  created_quote=$(jq -r '.estimate | if .billingMode == "usage" then .estimatedPriceCents else .priceCents end // empty' "$V12_RESP")
  if [ -n "$created_quote" ]; then
    jq --argjson q "$created_quote" '.createQuoteCents = ($q | round)' "$pinned_json" >"$(work_file pinned.tmp)" && mv "$(work_file pinned.tmp)" "$pinned_json"
  fi
fi

finish() {
  # finish STATE - writes the run outputs from run.json.
  local state="$1" cost duration report_path=""
  cost=$(jqx 'include "common"; .cost | if . == null then "" else (usd_to_cents | tostring) end' -r "$run_json")
  duration=$(jqx -r 'include "common"; ((.endedAt | iso_to_epoch) // now) as $e | (.startedAt | iso_to_epoch) as $s | if $s == null then "" else (($e - $s) | floor | tostring) end' "$run_json")
  if [ -z "$duration" ]; then
    duration=$(($(now_epoch) - started_wall))
  fi
  if [ -n "$cost" ]; then
    jq --argjson c "$cost" '.costCents = $c' "$run_json" >"$(work_file run.tmp)" && mv "$(work_file run.tmp)" "$run_json"
  else
    log_debug "The run object carries no 'cost' field; cost will be reported as n/a."
  fi
  # actionState is this action's view (timed_out / not waited) next to
  # V12's own state, which may still be "running".
  jq --argjson d "$duration" --arg url "$run_url" --arg s "$state" '.durationSeconds = $d | .webUrl = (.webUrl // $url) | .actionState = $s' "$run_json" >"$(work_file run.tmp)" && mv "$(work_file run.tmp)" "$run_json"
  if [ "$state" = "completed" ] && [ "$(json_get "$config_json" '.fetchReport')" = "true" ]; then
    report_path="$(work_file report.md)"
    # A 404 is normal when no report exists; anything else is only a warning.
    if v12_api GET "/runs/${uid}/report" "" "text/markdown"; then
      cp "$V12_RESP" "$report_path"
    else
      if [ "$V12_STATUS" != "404" ]; then
        log_warning "Could not fetch the V12 report: $(v12_error_message "$V12_STATUS" "$V12_RESP" GET "/runs/${uid}/report")"
      fi
      report_path=""
    fi
  fi
  set_output state "$state"
  set_output duration-seconds "$duration"
  set_output cost-cents "$cost"
  set_output report-path "$report_path"
}

started_wall=$(now_epoch)
if [ "$(json_get "$config_json" '.wait')" != "true" ]; then
  log_info "wait: false - not waiting for the run to finish. Follow it at ${run_url}."
  set_output waited "false"
  finish "$(json_get "$run_json" '.state')"
  exit 0
fi
set_output waited "true"

interval=$(json_get "$config_json" '.pollIntervalSeconds')
timeout_min=$(json_get "$config_json" '.waitTimeoutMinutes')
deadline=$((started_wall + timeout_min * 60))
# Test hooks (documented in AGENTS.md): shorten polling without touching the
# user-facing minimums.
if [ -n "${V12_POLL_INTERVAL_OVERRIDE:-}" ]; then interval="$V12_POLL_INTERVAL_OVERRIDE"; fi
if [ -n "${V12_WAIT_TIMEOUT_SECONDS_OVERRIDE:-}" ]; then deadline=$((started_wall + V12_WAIT_TIMEOUT_SECONDS_OVERRIDE)); fi
cancel_enabled=$(json_get "$config_json" '.cancelOnWorkflowCancel')
sleep_pid=""

on_signal() {
  trap - INT TERM
  if [ -n "$sleep_pid" ]; then
    kill "$sleep_pid" 2>/dev/null || true
  fi
  group_end
  if [ "$cancel_enabled" = "true" ]; then
    # The runner gives a cancelled step a few seconds; keep the request short.
    V12_HTTP_TIMEOUT=6 V12_MAX_ATTEMPTS=1 bash "$script_dir/cancel-run.sh" 5 || true
  else
    log_warning "Workflow interrupted; V12 run ${uid} is left running (cancel-on-workflow-cancel is false): ${run_url}"
  fi
  exit 130
}
trap on_signal INT TERM

group_start "Waiting for V12 run ${uid} (poll every ${interval}s, timeout ${timeout_min}m)"
last_line=""
last_heartbeat=$started_wall
state=""
consecutive_errors=0
while :; do
  if v12_api GET "/runs/${uid}"; then
    consecutive_errors=0
    if jq -e '.run.state != null' "$V12_RESP" >/dev/null 2>&1; then
      jq '.run' "$V12_RESP" >"$run_json"
    else
      die "Unexpected run response from V12 (no run.state): $(head -c 500 "$V12_RESP")"
    fi
    state=$(json_get "$run_json" '.state')
    line="${state}: $(json_get "$run_json" '.statusMessage')"
    if [ "$line" != "$last_line" ]; then
      log_info "[$(now_iso)] ${line}"
      last_line="$line"
      last_heartbeat=$(now_epoch)
    elif [ $(($(now_epoch) - last_heartbeat)) -ge 300 ]; then
      log_info "[$(now_iso)] still ${state} ($((($(now_epoch) - started_wall) / 60))m elapsed)"
      last_heartbeat=$(now_epoch)
    fi
    case "$state" in
      completed | failed | cancelled) break ;;
    esac
  else
    consecutive_errors=$((consecutive_errors + 1))
    log_warning "Polling V12 run ${uid} failed: $(v12_error_message "$V12_STATUS" "$V12_RESP" GET "/runs/${uid}")"
    if [ "$consecutive_errors" -ge 3 ]; then
      group_end
      die "Gave up polling V12 run ${uid} after ${consecutive_errors} consecutive failures. The run continues on V12's side: ${run_url}"
    fi
  fi
  if [ "$(now_epoch)" -ge "$deadline" ]; then
    group_end
    trap - INT TERM
    log_warning "Timed out after ${timeout_min} minutes waiting for V12 run ${uid}; it continues on V12's side: ${run_url}. Raise wait-timeout-minutes to wait longer."
    finish "timed_out"
    exit 0
  fi
  sleep "$interval" &
  sleep_pid=$!
  wait "$sleep_pid" || true
  sleep_pid=""
done
group_end
trap - INT TERM

case "$state" in
  completed) log_info "V12 run ${uid} completed: ${run_url}" ;;
  failed) log_warning "V12 run ${uid} failed: $(json_get "$run_json" '.statusMessage') (${run_url})" ;;
  cancelled) log_warning "V12 run ${uid} was cancelled: ${run_url}" ;;
esac
finish "$state"
