#!/usr/bin/env bash
# scripts/suppress.sh - applies the config file's suppressions to report.json.
# Suppressed findings move to a separate list (still rendered, collapsed).
# Expired suppressions do not apply: the finding re-surfaces and a warning
# names the expiry.
#
# Env in:  V12_WORK_DIR (config.json, report.json)
# Outputs: suppressed-count

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

config_json="$(work_file config.json)"
report_json="$(work_file report.json)"

jqx --slurpfile cfg "$config_json" 'include "process"; apply_suppressions($cfg[0])' "$report_json" >"$(work_file report.tmp)"
mv "$(work_file report.tmp)" "$report_json"

jq -r '.expiredSuppressions[] | "\(.fingerprint)\t\(.expires)\t\(.reason)\t\(.matched)"' "$report_json" | while IFS=$'\t' read -r fp expires reason matched; do
  [ -n "$fp" ] || continue
  if [ "$matched" = "true" ]; then
    log_warning "Suppression ${fp} expired on ${expires} and no longer applies; the finding is visible and gated again. Reason on file: ${reason}. Re-review it and extend or remove the suppression in the config file."
  else
    log_warning "Suppression ${fp} expired on ${expires} (no current finding matches it); remove it from the config file. Reason on file: ${reason}."
  fi
done
n_unmatched=$(jq '.unmatchedSuppressions | length' "$report_json")
if [ "$n_unmatched" -gt 0 ]; then
  log_info "${n_unmatched} suppression(s) match no current finding: $(jq -r '.unmatchedSuppressions | map(.fingerprint) | join(", ")' "$report_json")"
fi
n_suppressed=$(jq '.suppressed | length' "$report_json")
if [ "$n_suppressed" -gt 0 ]; then
  log_info "${n_suppressed} finding(s) suppressed by the config file."
fi
set_output suppressed-count "$n_suppressed"
