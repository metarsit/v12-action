#!/usr/bin/env bash
# scripts/render-check.sh - builds the check-run payload (title, summary,
# conclusion, annotations) that scripts/github/check-run.js posts.
#
# Env in:  V12_WORK_DIR (report.json, config.json, event.json), V12_ACTION_VERSION
# Files:   $V12_WORK_DIR/check-run.json
# Outputs: check-path, check-conclusion, check-annotations, check-action

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

report_json="$(work_file report.json)"
config_json="$(work_file config.json)"
event_json="$(work_file event.json)"
check_json="$(work_file check-run.json)"
[ -s "$report_json" ] || die "report.json is missing; collect-findings.sh did not run."
[ -s "$event_json" ] || printf '{}\n' >"$event_json"

max_annotations=$(json_get "$config_json" '.maxAnnotations')
[ -n "$max_annotations" ] || max_annotations=200

jqx --arg version "$V12_ACTION_VERSION" --argjson max "$max_annotations" \
  --slurpfile cfg "$config_json" --slurpfile ev "$event_json" '
  include "render";
  . as $r
  | ($r.findings | map(select(.hasLocation and .location.startLine != null)) | length) as $locatable
  | ($r.findings | map(select(.inDiff == false)) | length) as $outside
  | annotations($r; $max) as $ann
  | {
      name: ($cfg[0].checkRunName // "V12 Security"),
      headSha: ($r.target.blobSha // $ev[0].sha // ""),
      conclusion: check_conclusion($r),
      detailsUrl: ($r.run.url // "https://v12.sh"),
      title: (check_title($r) | .[0:255]),
      summary: (
        check_summary($r; $version)
        + (if $locatable > ($ann | length) then "\n\nInline annotations were capped at \($ann | length) of \($locatable) (max-annotations)." else "" end)
        + (if $outside > 0 then "\n\n\($outside) finding(s) are in files outside this diff; their annotations appear on the Checks tab only. See the pull request comment for the full list." else "" end)
        | .[0:65000]),
      annotations: $ann,
      annotationsTotal: $locatable
    }' "$report_json" >"$check_json"

action="create"
if [ "$(json_get "$config_json" '.checkRun')" != "true" ]; then
  action="skip"
elif [ -z "$(json_get "$check_json" '.headSha')" ]; then
  action="skip"
  log_warning "No commit SHA is available for the check run; skipping it."
fi
set_output check-path "$check_json"
set_output check-conclusion "$(json_get "$check_json" '.conclusion')"
set_output check-annotations "$(jq '.annotations | length' "$check_json")"
set_output check-action "$action"
log_info "Check run payload: conclusion $(json_get "$check_json" '.conclusion'), $(jq '.annotations | length' "$check_json") annotation(s), action ${action}"
