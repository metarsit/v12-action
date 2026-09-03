#!/usr/bin/env bash
# scripts/collect-findings.sh - fetches the run's findings, fetches details
# when the list is summary-only, computes fingerprints, applies the
# validity / auto-invalidation / severity / path filters and the gate, and
# writes report.json, the single input every output surface renders from.
#
# Env in:  V12_TOKEN, V12_API_URL, V12_WORK_DIR (config.json, refs.json,
#          run.json, pinned.json, estimate.json, changed-files.json)
#          V12_ACTION_VERSION, V12_NOW (tests), V12_FINDINGS_PAGE_SIZE (tests)
# Files:   $V12_WORK_DIR/findings-raw.json, report.json
# Outputs: findings-fetched

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

config_json="$(work_file config.json)"
refs_json="$(work_file refs.json)"
run_json="$(work_file run.json)"
pinned_json="$(work_file pinned.json)"
estimate_json="$(work_file estimate.json)"
changed_json="$(work_file changed-files.json)"
raw_json="$(work_file findings-raw.json)"
report_json="$(work_file report.json)"
now="${V12_NOW:-$(now_iso)}"

for f in "$pinned_json" "$estimate_json" "$changed_json" "$run_json"; do
  if [ ! -s "$f" ]; then printf 'null\n' >"$f"; fi
done
if [ ! -s "$refs_json" ]; then printf '{}\n' >"$refs_json"; fi

meta_base() {
  jq -n --arg now "$now" --arg version "$V12_ACTION_VERSION" --slurpfile est "$estimate_json" \
    --arg skippedReason "${1:-}" --arg skippedMessage "${2:-}" '
    {generatedAt: $now, actionVersion: $version,
     scopeFiles: ($est[0].scope | if type == "array" then length else null end),
     billableChangedLines: ($est[0].estimate.billableChangedLines // null),
     skippedReason: (if $skippedReason == "" then null else $skippedReason end),
     skippedMessage: (if $skippedMessage == "" then null else $skippedMessage end)}'
}

write_skipped() {
  jqx -n --slurpfile cfg "$config_json" --slurpfile refs "$refs_json" --slurpfile pinned "$pinned_json" \
    --argjson meta "$(meta_base "${1:-}" "${2:-}")" \
    'include "process"; build_skipped_report($cfg[0]; $refs[0]; ($pinned[0] // {}); $meta)' >"$report_json"
  set_output findings-fetched "0"
  log_debug "report (skipped): $(jq -c . "$report_json")"
}

# --- no run: skipped / over budget / estimate-only ---------------------------
if [ "$(jq -r '.empty // false' "$refs_json")" = "true" ] || ! jq -e 'type == "object" and .uid != null' "$run_json" >/dev/null 2>&1; then
  write_skipped "$(jq -r '.skippedReason // "not-created"' "$refs_json")" "$(jq -r '.skippedMessage // ""' "$refs_json")"
  exit 0
fi

uid=$(json_get "$run_json" '.uid')
state=$(json_get "$run_json" '.state')
printf '[]\n' >"$raw_json"
total_matching=""
detail_needed=false
detail_fetched=0
detail_capped=false
detail_cap=$(json_get "$config_json" '.maxFindingsDetail')
[ -n "$detail_cap" ] || detail_cap=200

if [ "$state" = "completed" ]; then
  page_size="${V12_FINDINGS_PAGE_SIZE:-100}"
  offset=0
  pages=0
  group_start "Fetching findings for V12 run ${uid}"
  while :; do
    pages=$((pages + 1))
    if ! v12_api GET "/runs/${uid}/findings?limit=${page_size}&offset=${offset}"; then
      group_end
      v12_fail GET "/runs/${uid}/findings"
    fi
    if ! jq -e '.findings | type == "array"' "$V12_RESP" >/dev/null 2>&1; then
      group_end
      die "Unexpected findings response from V12 (no 'findings' array): $(head -c 500 "$V12_RESP")"
    fi
    n=$(jq -r '.findings | length' "$V12_RESP")
    total_matching=$(jq -r '.totalMatching // empty' "$V12_RESP")
    jq -s '.[0] + .[1].findings' "$raw_json" "$V12_RESP" >"$(work_file findings.tmp)"
    mv "$(work_file findings.tmp)" "$raw_json"
    offset=$((offset + n))
    log_info "page ${pages}: ${n} finding(s), ${offset} of ${total_matching:-?} fetched"
    if [ "$n" -eq 0 ]; then break; fi
    if [ -z "$total_matching" ]; then
      # No totalMatching in the response: stop on a short page.
      if [ "$n" -lt "$page_size" ]; then break; fi
    elif [ "$offset" -ge "$total_matching" ]; then
      break
    fi
    if [ "$pages" -ge 200 ]; then
      log_warning "Stopped fetching findings after ${pages} pages (${offset} findings)."
      break
    fi
  done
  group_end
  [ -n "$total_matching" ] || total_matching=$(jq 'length' "$raw_json")

  # A summary-only list (no description / sourceLocations) needs one detail
  # call per finding, in the reads:artifact bucket (300 per minute). Only
  # findings that survive the validity and severity filters are fetched,
  # most severe first, up to max-findings-detail.
  if jq -e 'length > 0 and (map(has("sourceLocations") and has("description")) | all | not)' "$raw_json" >/dev/null 2>&1; then
    detail_needed=true
    jqx --slurpfile cfg "$config_json" '
      include "common";
      ($cfg[0]) as $c
      | map(select(. as $f
          | (($c.includeValidity | index(($f.validity | str | ascii_downcase))) != null)
          and ((.severity | str | ascii_downcase | sev_rank) <= ($c.minSeverity | sev_rank))
          and (($c.ignoreAutoInvalidated and ((.autoInvalidated // false) | to_bool) and ((.validity | str | ascii_downcase) == "unreviewed")) | not)
        ))
      | sort_findings | map(.uid)' "$raw_json" >"$(work_file detail-candidates.json)"
    n_candidates=$(jq 'length' "$(work_file detail-candidates.json)")
    n_fetch="$n_candidates"
    if [ "$n_candidates" -gt "$detail_cap" ]; then
      detail_capped=true
      n_fetch="$detail_cap"
      log_warning "The findings list is summary-only and ${n_candidates} findings need a detail call each; fetching the ${detail_cap} most severe (max-findings-detail). The rest are listed by title only."
    fi
    group_start "Fetching details for ${n_fetch} finding(s)"
    : >"$(work_file details.jsonl)"
    for fuid in $(jq -r --argjson cap "$detail_cap" '.[0:$cap][]' "$(work_file detail-candidates.json)"); do
      if v12_api GET "/runs/${uid}/findings/${fuid}"; then
        if jq -e 'type == "object" and .uid != null' "$V12_RESP" >/dev/null 2>&1; then
          jq -c '. + {detailFetched: true}' "$V12_RESP" >>"$(work_file details.jsonl)"
          detail_fetched=$((detail_fetched + 1))
        fi
      else
        log_warning "Could not fetch finding ${fuid}: $(v12_error_message "$V12_STATUS" "$V12_RESP" GET "/runs/${uid}/findings/${fuid}")"
      fi
      # Stay well under the 300-per-minute artifact-read bucket.
      sleep "${V12_DETAIL_PAUSE:-0.25}"
    done
    group_end
    jq -s '.[0] as $raw | (.[1:] | map({key: (.uid | tostring), value: .}) | from_entries) as $d
           | $raw | map(. as $f | ($d[$f.uid | tostring] // $f))' "$raw_json" "$(work_file details.jsonl)" >"$(work_file findings.tmp)"
    mv "$(work_file findings.tmp)" "$raw_json"
  fi
else
  log_info "Run ${uid} is ${state}; no findings to collect."
fi

# --- fingerprints (sha256 in bash; jq has no hashing) ------------------------
# jq emits NUL-separated (uid, material, normalised title) triples, the NUL
# being produced by ([0] | implode); bash reads them with read -d '' and
# hashes each one.
fp_lines="$(work_file fingerprints.tsv)"
: >"$fp_lines"
if [ "$(jq 'length' "$raw_json")" -gt 0 ]; then
  jqx -j 'include "common"; ([0] | implode) as $nul | .[] | (.uid | tostring), $nul, fingerprint_material, $nul, (.title | norm_title), $nul' "$raw_json" >"$(work_file fp-material.bin)"
  while IFS= read -r -d '' fuid && IFS= read -r -d '' material && IFS= read -r -d '' ntitle; do
    fp=$(printf '%s' "$material" | sha256_hex | cut -c1-16)
    th=$(printf '%s' "$ntitle" | sha256_hex | cut -c1-16)
    printf '%s\t%s\t%s\n' "$fuid" "$fp" "$th" >>"$fp_lines"
  done <"$(work_file fp-material.bin)"
fi
jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: {fingerprint: .[1], titleHash: .[2]}}) | from_entries' "$fp_lines" >"$(work_file fingerprints.json)"
jq -s '.[1] as $fp | .[0] | map(. + ($fp[.uid | tostring] // {fingerprint: "", titleHash: ""}))' "$raw_json" "$(work_file fingerprints.json)" >"$(work_file findings.tmp)"
mv "$(work_file findings.tmp)" "$raw_json"

# --- report --------------------------------------------------------------------
meta=$(meta_base | jq --argjson total "${total_matching:-0}" --argjson needed "$detail_needed" --argjson fetched "$detail_fetched" --argjson capped "$detail_capped" --argjson cap "$detail_cap" \
  '. + {totalMatching: $total, detail: {needed: $needed, fetched: $fetched, capped: $capped, cap: $cap}}')
jqx --slurpfile cfg "$config_json" --slurpfile refs "$refs_json" --slurpfile run "$run_json" \
  --slurpfile pinned "$pinned_json" --slurpfile changed "$changed_json" --argjson meta "$meta" \
  'include "process"; build_report($cfg[0]; $refs[0]; $run[0]; ($pinned[0] // {}); ($changed[0] // {}); $meta)' "$raw_json" >"$report_json"

set_output findings-fetched "$(jq 'length' "$raw_json")"
log_info "Findings: $(jq -r '.counts | "\(.total) after filters (critical \(.critical), high \(.high), medium \(.medium), low \(.low), info \(.info), qa \(.qa))"' "$report_json"); hidden: $(jq -r '.hidden | "\(.total) (validity \(.validity), auto-invalidated \(.autoInvalidated), below min-severity \(.belowMinSeverity), excluded paths \(.excludedPath))"' "$report_json")"
log_debug "report: $(jq -c 'del(.findings[].description, .findings[].impact, .findings[].rootCause)' "$report_json")"
