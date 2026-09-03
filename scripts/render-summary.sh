#!/usr/bin/env bash
# scripts/render-summary.sh - writes the job summary (self-sufficient: it is
# what people read when the comment could not be posted).
#
# Env in:  V12_WORK_DIR (report.json, config.json), V12_ACTION_VERSION,
#          V12_SURFACES (optional JSON object: surface -> result text),
#          GITHUB_STEP_SUMMARY
# Files:   $V12_WORK_DIR/summary.md
# Outputs: summary-path

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

report_json="$(work_file report.json)"
config_json="$(work_file config.json)"
summary_md="$(work_file summary.md)"
[ -s "$report_json" ] || die "report.json is missing; collect-findings.sh did not run."

surfaces='null'
if [ -n "${V12_SURFACES:-}" ] && printf '%s' "$V12_SURFACES" | jq -e 'type == "object"' >/dev/null 2>&1; then
  surfaces="$V12_SURFACES"
fi

jqx -r --arg version "$V12_ACTION_VERSION" --argjson surfaces "$surfaces" \
  'include "render"; summary_body(.; $version; $surfaces)' "$report_json" >"$summary_md"

# GitHub caps a step summary at 1 MiB; keep a wide margin.
if [ "$(file_size "$summary_md")" -gt 900000 ]; then
  head -c 880000 "$summary_md" >"$(work_file summary.tmp)"
  printf '\n\n(summary truncated; see the full run)\n' >>"$(work_file summary.tmp)"
  mv "$(work_file summary.tmp)" "$summary_md"
fi

set_output summary-path "$summary_md"
if [ "$(json_get "$config_json" '.jobSummary')" = "true" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$summary_md" >>"$GITHUB_STEP_SUMMARY"
  log_info "Job summary written ($(file_size "$summary_md") bytes)."
else
  log_info "Job summary rendered to ${summary_md} (not published: job-summary is false or GITHUB_STEP_SUMMARY is unset)."
fi
