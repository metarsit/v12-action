#!/usr/bin/env bash
# scripts/gate.sh - the last step: publishes the machine outputs and decides
# the job's exit status. Runs after every surface so a failing gate never
# hides the comment, check run, SARIF or summary.
#
# Env in:  V12_WORK_DIR (report.json)
# Outputs: conclusion, state, *-count, findings-json, findings-path,
#          results-path

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

report_json="$(work_file report.json)"
[ -s "$report_json" ] || die "report.json is missing; collect-findings.sh did not run."

findings_path="$(work_file findings.json)"
jq -c '.findings' "$report_json" >"$findings_path"

set_output conclusion "$(jq -r '.conclusion' "$report_json")"
set_output state "$(jq -r '.run.state' "$report_json")"
for sev in critical high medium low info qa; do
  set_output "${sev}-count" "$(jq -r ".counts.${sev}" "$report_json")"
done
set_output total-count "$(jq -r '.counts.total' "$report_json")"
set_output gate-count "$(jq -r '.gate.count' "$report_json")"
set_output suppressed-count "$(jq -r '.suppressed | length' "$report_json")"
set_output findings-path "$findings_path"
set_output results-path "$report_json"
if [ "$(file_size "$findings_path")" -le 900000 ]; then
  set_output findings-json "$(cat "$findings_path")"
else
  log_warning "findings-json output omitted: the findings array is larger than 900 KB. Read the findings-path file instead."
  set_output findings-json "[]"
fi

if [ "$(jq -r '.skipped != null' "$report_json")" = "true" ]; then
  log_info "V12 audit skipped: $(jq -r '.skipped.reason' "$report_json")"
  exit 0
fi

summary=$(jq -r '"\(.counts.total) finding(s) after filters; gate fail-on=\(.gate.failOn): \(.gate.count) at or above"' "$report_json")
if [ "$(jq -r '.jobShouldFail' "$report_json")" = "true" ]; then
  if [ "$(jq -r '.gate.failing' "$report_json")" = "true" ]; then
    die "V12 gate failed: ${summary}. Run: $(jq -r '.run.url // "n/a"' "$report_json")"
  fi
  die "V12 run ended in state '$(jq -r '.run.state' "$report_json")' and fail-on-error is true. Run: $(jq -r '.run.url // "n/a"' "$report_json")"
fi
log_info "V12 gate passed: ${summary}."
