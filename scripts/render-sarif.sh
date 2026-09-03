#!/usr/bin/env bash
# scripts/render-sarif.sh - emits SARIF 2.1.0 for code scanning, capped to
# GitHub's limits (5,000 results shown per run; 10 MB gzip-compressed),
# dropping the lowest severities first.
#
# Env in:  V12_WORK_DIR (report.json, config.json, event.json),
#          V12_ACTION_VERSION, V12_SARIF_MAX_RESULTS (default 5000),
#          V12_SARIF_MAX_GZIP_BYTES (default 9500000)
# Files:   the SARIF file (sarif-path input or $V12_WORK_DIR/v12.sarif)
# Outputs: sarif-path, sarif-results, sarif-truncated, sarif-category

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

report_json="$(work_file report.json)"
config_json="$(work_file config.json)"
event_json="$(work_file event.json)"
[ -s "$report_json" ] || die "report.json is missing; collect-findings.sh did not run."
[ -s "$event_json" ] || printf '{}\n' >"$event_json"

sarif_path=$(json_get "$config_json" '.sarifPath')
if [ -z "$sarif_path" ]; then
  sarif_path="$(work_file v12.sarif)"
else
  case "$sarif_path" in
    /*) ;;
    *) sarif_path="${GITHUB_WORKSPACE:-$PWD}/${sarif_path}" ;;
  esac
  mkdir -p "$(dirname "$sarif_path")"
fi

category=$(json_get "$config_json" '.sarifCategory')
if [ -z "$category" ]; then
  category="v12-audit/$(jq -r '.target.mode // "audit"' "$report_json")"
fi
anchor=$(jq -r '.workflowPath // empty' "$event_json")
[ -n "$anchor" ] || anchor="README.md"

max_results="${V12_SARIF_MAX_RESULTS:-5000}"
max_gzip="${V12_SARIF_MAX_GZIP_BYTES:-9500000}"
total=$(jq '.findings | length' "$report_json")

render() {
  jqx --arg version "$V12_ACTION_VERSION" --arg anchor "$anchor" --arg category "$category" --argjson max "$1" \
    'include "sarif"; sarif(.; $version; $anchor; $category; $max)' "$report_json" >"$sarif_path"
}

render "$max_results"
while [ "$(gzip -c "$sarif_path" | wc -c | tr -d ' ')" -gt "$max_gzip" ] && [ "$max_results" -gt 1 ]; do
  max_results=$((max_results / 2))
  log_warning "SARIF exceeds GitHub's 10 MB compressed limit; re-rendering with the ${max_results} most severe findings."
  render "$max_results"
done

included=$(jq '.runs[0].results | length' "$sarif_path")
truncated="false"
if [ "$included" -lt "$total" ]; then
  truncated="true"
  log_notice "SARIF contains ${included} of ${total} findings (lowest severities dropped to respect GitHub's limits)."
fi
set_output sarif-path "$sarif_path"
set_output sarif-results "$included"
set_output sarif-truncated "$truncated"
set_output sarif-category "$category"
log_info "SARIF written: ${sarif_path} (${included} result(s), category ${category})"
