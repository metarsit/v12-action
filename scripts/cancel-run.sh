#!/usr/bin/env bash
# scripts/cancel-run.sh - cancels the V12 run recorded in the working
# directory. Used by the signal trap in create-and-wait.sh and by the
# composite step that runs when the workflow is cancelled, so a usage-billed
# diff review is not left running (and billing) after CI walked away.
#
# Usage: cancel-run.sh [MAX_WAIT_SECONDS]
# Env in: V12_TOKEN, V12_API_URL, V12_WORK_DIR (run-uid file)

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

max_wait="${1:-60}"
uid_file="$(work_file run-uid)"
if [ ! -s "$uid_file" ]; then
  log_info "No V12 run was created in this job; nothing to cancel."
  exit 0
fi
uid=$(tr -d '[:space:]' <"$uid_file")
run_json="$(work_file run.json)"
if [ -s "$run_json" ]; then
  case "$(json_get "$run_json" '.state')" in
    completed | failed | cancelled)
      log_info "V12 run ${uid} already reached a terminal state; nothing to cancel."
      exit 0
      ;;
  esac
fi

log_warning "Cancelling V12 run ${uid} because the workflow was cancelled or interrupted."
V12_MAX_ATTEMPTS=2
if ! v12_api POST "/runs/${uid}/cancel"; then
  log_warning "$(v12_error_message "$V12_STATUS" "$V12_RESP" POST "/runs/${uid}/cancel") The run may still be active: check ${V12_API_URL%/}/runs/${uid}."
  exit 0
fi
pending=$(json_get "$V12_RESP" '.cancellationPending')
if [ "$pending" != "true" ]; then
  log_info "V12 run ${uid} cancelled."
  exit 0
fi

# An active usage-billed diff review reports cancellationPending while the
# worker persists usage; poll briefly so the terminal state is recorded.
log_info "V12 is finishing the cancellation of run ${uid} (persisting usage); waiting up to ${max_wait}s."
deadline=$(($(now_epoch) + max_wait))
while [ "$(now_epoch)" -lt "$deadline" ]; do
  sleep 3
  if v12_api GET "/runs/${uid}"; then
    state=$(json_get "$V12_RESP" '.run.state')
    if [ -n "$state" ]; then
      jq '.run' "$V12_RESP" >"$run_json" 2>/dev/null || true
    fi
    case "$state" in
      completed | failed | cancelled)
        log_info "V12 run ${uid} is now ${state}."
        exit 0
        ;;
    esac
  fi
done
log_warning "V12 run ${uid} had not reached a terminal state after ${max_wait}s; cancellation is pending on V12's side. Check ${V12_API_URL%/}/runs/${uid}."
