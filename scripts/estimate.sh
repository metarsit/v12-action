#!/usr/bin/env bash
# scripts/estimate.sh - quotes the run before anything is created.
#
# Builds the request body once (shared verbatim with create-and-wait.sh so a
# path list can never reach one call and not the other), posts it to
# POST /runs/estimate, enforces the cost ceiling, skips diffs V12 says are
# empty, and records the commits V12 priced so the create call is pinned to
# them.
#
# Env in:  V12_TOKEN, V12_API_URL, V12_WORK_DIR (config.json, refs.json)
# Files:   $V12_WORK_DIR/request-body.json, estimate.json, pinned.json
# Outputs: estimate-cents, billing-mode, skipped, skipped-reason, conclusion,
#          scope-files

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

config_json="$(work_file config.json)"
refs_json="$(work_file refs.json)"
body_json="$(work_file request-body.json)"
estimate_json="$(work_file estimate.json)"
pinned_json="$(work_file pinned.json)"

# The body is identical for estimate and create except for name, context
# documents and the pinned refs, which create-and-wait.sh layers on top.
jq -n --slurpfile refs "$refs_json" '
  ($refs[0]) as $r
  | {source: "github", repoFullName: $r.repository}
  + (if ($r.apiPaths | length) > 0 then {paths: $r.apiPaths} else {} end)
  + (if $r.kind == "diff"
     then {diffReviewConfig: {fromRef: $r.fromRef, toRef: $r.toRef}}
     else ({branch: $r.branch} + (if ($r.sha // "") != "" then {sha: $r.sha} else {} end))
     end)' >"$body_json"

log_info "Requesting an estimate from V12..."
if ! v12_api POST /runs/estimate "$body_json"; then
  case "$V12_STATUS" in
    400 | 422)
      msg=$(v12_error_message "$V12_STATUS" "$V12_RESP" POST /runs/estimate)
      if [ "$(jq -r '.apiPaths | length' "$refs_json")" != "0" ]; then
        die "$msg Hint: 'paths' was sent (${V12_STATUS}); if V12 rejects paths for this kind of run, remove the paths input for it."
      fi
      if [ "$(jq -r '.kind' "$refs_json")" = "full" ]; then
        die "$msg Hint: V12 resolves the audited commit from 'branch' ($(jq -r '.branch' "$refs_json")); make sure that branch or tag exists on GitHub and that V12 can see the repository (private repositories need the V12 GitHub app installed)."
      fi
      die "$msg"
      ;;
    *) v12_fail POST /runs/estimate ;;
  esac
fi
cp "$V12_RESP" "$estimate_json"

# Fail loudly on an unexpected shape rather than silently mis-pricing.
if ! jq -e '.estimate | type == "object"' "$estimate_json" >/dev/null 2>&1; then
  die "Unexpected estimate response from V12 (no 'estimate' object): $(head -c 500 "$estimate_json")"
fi

billing_mode=$(json_get "$estimate_json" '.estimate.billingMode')
quote=$(jq -r '.estimate | if .billingMode == "usage" then .estimatedPriceCents else .priceCents end // empty' "$estimate_json")
if [ -z "$quote" ]; then
  die "Unexpected estimate response from V12: billingMode='${billing_mode}' but neither estimate.priceCents (fixed) nor estimate.estimatedPriceCents (usage) is present: $(jq -c '.estimate' "$estimate_json")"
fi
case "$quote" in
  *[!0-9.]* | '') die "Unexpected estimate price '${quote}' from V12." ;;
esac
quote=$(printf '%s' "$quote" | jq 'round')

scope_files=$(jq -r '.scope | if type == "array" then length else 0 end' "$estimate_json")
changed_lines=$(jq -r '.estimate.billableChangedLines // empty' "$estimate_json")
kind=$(json_get "$refs_json" '.kind')

set_output estimate-cents "$quote"
set_output billing-mode "${billing_mode:-unknown}"
set_output scope-files "$scope_files"
log_info "Estimate: $(money "$quote") (${billing_mode:-unknown} billing), ${scope_files} file(s) in scope$([ -n "$changed_lines" ] && printf ', %s changed line(s)' "$changed_lines")"
if [ "$billing_mode" = "usage" ]; then
  log_info "Usage billing: V12 charges realized provider usage as the review runs, so the final cost can land above or below this estimate."
fi
if [ "${RUNNER_DEBUG:-0}" = "1" ]; then
  group_start "Estimate scope"
  jq -r '.scope[]? | "\(.path)\t\(.loc // "-") loc\t\(.bytes // "-") bytes"' "$estimate_json"
  group_end
fi

# Pin the create call to the commits V12 priced. Branches move between two
# API calls; the estimate names the exact commits it looked at.
jq --slurpfile refs "$refs_json" '
  ($refs[0]) as $r
  | .resolved as $res
  | if $r.kind == "diff" then
      {fromRef: ($res.resolvedFromSha // $r.fromRef), toRef: ($res.resolvedToSha // $r.toRef),
       pinnedFrom: ($res.resolvedFromSha != null), pinnedTo: ($res.resolvedToSha != null)}
    else
      {branch: $r.branch, sha: ($res.sha // $r.sha), pinnedSha: ($res.sha != null)}
    end
  | . + {quoteCents: (.quoteCents // null)}' "$estimate_json" \
  | jq --argjson quote "$quote" --arg mode "${billing_mode:-unknown}" '. + {quoteCents: $quote, billingMode: $mode}' >"$pinned_json"

if [ "$kind" = "diff" ]; then
  if [ "$(jq -r '.pinnedFrom and .pinnedTo' "$pinned_json")" = "true" ]; then
    log_info "Pinned to the commits V12 priced: $(jq -r '"\(.fromRef[0:7])..\(.toRef[0:7])"' "$pinned_json")"
  else
    log_debug "Estimate did not return resolvedFromSha/resolvedToSha; the create call reuses the SHAs sent to the estimate."
  fi
else
  if [ "$(jq -r '.pinnedSha' "$pinned_json")" = "true" ]; then
    log_info "Pinned to the commit V12 priced: $(jq -r '.sha[0:7]' "$pinned_json")"
  fi
fi

skip() {
  local reason="$1" message="$2"
  log_notice "V12 audit skipped ($reason): $message"
  jq --arg reason "$reason" --arg message "$message" '. + {empty: true, skippedReason: $reason, skippedMessage: $message}' "$refs_json" >"$(work_file refs.tmp)"
  mv "$(work_file refs.tmp)" "$refs_json"
  set_output skipped "true"
  set_output skipped-reason "$reason"
  set_output conclusion "skipped"
  exit 0
}

if [ "$kind" = "diff" ] && [ "$(json_get "$config_json" '.skipIfUnchanged')" = "true" ] && [ "$changed_lines" = "0" ]; then
  skip "empty-diff" "V12 reports 0 billable changed lines for $(jq -r '.displayRange' "$refs_json"); nothing to review and nothing to charge."
fi

max_cost=$(json_get "$config_json" '.maxCostCents')
if [ -n "$max_cost" ] && [ "$quote" -gt "$max_cost" ]; then
  skip "over-budget" "V12 quoted $(money "$quote") for this run, above the max-cost-cents ceiling of $(money "$max_cost"). No run was created and nothing was charged. Raise max-cost-cents or narrow 'paths' to proceed."
fi

if [ "$(json_get "$config_json" '.estimateOnly')" = "true" ]; then
  log_notice "estimate-only: V12 quoted $(money "$quote") (${billing_mode:-unknown} billing) for ${scope_files} file(s). No run was created."
  jq '. + {empty: true, skippedReason: "estimate-only", skippedMessage: "estimate-only mode: no run created"}' "$refs_json" >"$(work_file refs.tmp)"
  mv "$(work_file refs.tmp)" "$refs_json"
  set_output skipped "true"
  set_output skipped-reason "estimate-only"
  set_output conclusion "estimate-only"
  exit 0
fi
set_output skipped "false"
