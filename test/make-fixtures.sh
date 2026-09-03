#!/usr/bin/env bash
# test/make-fixtures.sh - regenerates test/fixtures/report-*.json from the
# stub API so the golden-file tests render from stable, realistic inputs.
# Deterministic: timestamps come from V12_NOW and the stub's fixed dates.

set -o errexit -o nounset -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export BATS_TEST_FILENAME="$ROOT/test/make-fixtures.bats"
# shellcheck source=test/test_helper.bash
. "$ROOT/test/test_helper.bash"
export V12_TOKEN=v12p_ok
OUT="$ROOT/test/fixtures"

start_stub
trap stop_stub EXIT

run_pipeline() {
  # run_pipeline NAME REPO REFS_KIND [config env...]
  local name="$1" repo="$2" kind="$3"
  shift 3
  new_work
  WS="$V12_WORK_DIR/ws"
  mkdir -p "$WS/.github"
  export GITHUB_WORKSPACE="$WS"
  if [ -n "${CONFIG_FILE_CONTENT:-}" ]; then
    printf '%s\n' "$CONFIG_FILE_CONTENT" >"$WS/.github/v12-audit.yml"
  fi
  make_config "$@"
  if [ "$kind" = "full" ]; then make_refs_full "$repo"; else make_refs_diff "$repo"; fi
  bash "$SCRIPTS/estimate.sh" >/dev/null
  if [ "$(output_value skipped)" != "true" ]; then
    bash "$SCRIPTS/create-and-wait.sh" >/dev/null
    if [ "${CANCEL_AFTER_CREATE:-}" = "true" ]; then
      curl -s -H "Authorization: Bearer v12p_ok" "$V12_API_URL/api/v1/runs/$(cat "$V12_WORK_DIR/run-uid")" >/dev/null
      bash "$SCRIPTS/cancel-run.sh" 30 >/dev/null
    fi
  fi
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
  bash "$SCRIPTS/suppress.sh" >/dev/null
  V12_PRIOR_STATE="${PRIOR_STATE:-}" bash "$SCRIPTS/delta.sh" >/dev/null
  cp "$V12_WORK_DIR/report.json" "$OUT/report-${name}.json"
  printf 'wrote report-%s.json (%s findings, conclusion %s)\n' "$name" "$(jq '.findings | length' "$OUT/report-${name}.json")" "$(jq -r .conclusion "$OUT/report-${name}.json")"
}

# 1. First pass to learn fingerprints for the suppression fixtures.
run_pipeline scratch acme/vault diff V12_INPUT_FAIL_ON=high V12_INPUT_EXCLUDE_PATHS='**/test/**'
fp_active=$(jq -r '.findings[] | select(.uid == 109) | .fingerprint' "$OUT/report-scratch.json")
fp_expired=$(jq -r '.findings[] | select(.uid == 113) | .fingerprint' "$OUT/report-scratch.json")
prior=$(jq -c '{v: 1, sha: "9999999999999999999999999999999999999999", run: 41, slackTs: "1700000000.000100", slackChannel: "C0123", fps: ([.findings[0:3][].fingerprint] + ["ffffffffffffffff", "eeeeeeeeeeeeeeee"])}' "$OUT/report-scratch.json")
rm -f "$OUT/report-scratch.json"

# 2. The main findings report: gate on high, exclusions, one active and one
#    expired suppression, and a prior state for the delta.
CONFIG_FILE_CONTENT="$(printf 'suppressions:\n  - fingerprint: "%s"\n    reason: "Fence rendering only; tracked in SEC-77"\n    expires: "2099-12-31"\n    approved-by: "@security-team"\n  - fingerprint: "%s"\n    reason: "Pragma pinned in the release branch"\n    expires: "2020-01-01"\n' "$fp_active" "$fp_expired")" \
PRIOR_STATE="$prior" \
  run_pipeline findings acme/vault diff V12_INPUT_FAIL_ON=high V12_INPUT_EXCLUDE_PATHS='**/test/**'
unset CONFIG_FILE_CONTENT PRIOR_STATE

run_pipeline clean acme/clean diff V12_INPUT_FAIL_ON=high
run_pipeline failed acme/failing diff V12_INPUT_FAIL_ON=high
run_pipeline over-budget acme/vault diff V12_INPUT_MAX_COST_CENTS=100
run_pipeline empty-diff acme/empty diff
V12_WAIT_TIMEOUT_SECONDS_OVERRIDE=1 run_pipeline timed-out acme/slow diff
CANCEL_AFTER_CREATE=true run_pipeline cancelled acme/cancelling diff V12_INPUT_WAIT=false
run_pipeline full acme/vault full V12_INPUT_FAIL_ON=critical V12_INPUT_MIN_SEVERITY=low
