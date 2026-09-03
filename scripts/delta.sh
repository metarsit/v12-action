#!/usr/bin/env bash
# scripts/delta.sh - "2 new, 1 resolved since abc1234": compares this run's
# fingerprints with the ones stored in the previous sticky comment. The prior
# state arrives as JSON in V12_PRIOR_STATE (extracted by the find-comment
# step); no external storage is involved.
#
# Env in:  V12_WORK_DIR (report.json), V12_PRIOR_STATE (JSON or empty)
# Outputs: new-count, resolved-count

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

report_json="$(work_file report.json)"
prior_json="$(work_file prior-state.json)"
printf '%s' "${V12_PRIOR_STATE:-}" >"$prior_json"
if ! jq -e 'type == "object"' "$prior_json" >/dev/null 2>&1; then
  printf 'null\n' >"$prior_json"
fi

jqx --slurpfile prior "$prior_json" 'include "process"; apply_delta($prior[0])' "$report_json" >"$(work_file report.tmp)"
mv "$(work_file report.tmp)" "$report_json"

if [ "$(jq -r '.delta != null' "$report_json")" = "true" ]; then
  log_info "Delta since $(jq -r '.delta.priorSha | .[0:7]' "$report_json"): $(jq -r '.delta | "\(.newCount) new, \(.resolvedCount) resolved, \(.unchangedCount) unchanged"' "$report_json")"
  set_output new-count "$(jq -r '.delta.newCount' "$report_json")"
  set_output resolved-count "$(jq -r '.delta.resolvedCount' "$report_json")"
else
  set_output new-count ""
  set_output resolved-count ""
fi
