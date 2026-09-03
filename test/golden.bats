#!/usr/bin/env bats
# Golden-file tests for the user-visible surfaces: the PR comment, the
# check-run payload, the job summary and the SARIF document, rendered from
# the fixed report fixtures. Regenerate with:  UPDATE_GOLDENS=1 bats test/golden.bats
# and review the diff before committing.

load test_helper

GOLDEN_DIR="$ROOT/test/golden"
FIXTURE_NAMES="findings clean failed over-budget empty-diff timed-out cancelled full"

setup() {
  new_work
  export V12_ACTION_VERSION="1.0.0-test"
  export GITHUB_REPOSITORY="acme/vault"
  export GITHUB_WORKSPACE="$V12_WORK_DIR/ws"
  mkdir -p "$GITHUB_WORKSPACE"
  unset GITHUB_STEP_SUMMARY
}

render_fixture() {
  # render_fixture NAME [config env...] - renders all four surfaces.
  local name="$1"
  shift
  cp "$FIXTURES/report-${name}.json" "$V12_WORK_DIR/report.json"
  printf '{"eventName":"pull_request","sha":"1111111111111111111111111111111111111111","workflowPath":".github/workflows/v12.yml"}\n' >"$V12_WORK_DIR/event.json"
  make_config V12_INPUT_FAIL_ON=high "$@"
  V12_SLACK_TS="1700000000.000100" V12_SLACK_CHANNEL="C0123" bash "$SCRIPTS/render-comment.sh" >/dev/null
  bash "$SCRIPTS/render-check.sh" >/dev/null
  V12_SURFACES='{"Pull request comment":"updated","Check run":"created","SARIF":"written, not uploaded (upload-sarif: false)","Slack":"skipped (notify-on: gate-failure)"}' bash "$SCRIPTS/render-summary.sh" >/dev/null
  bash "$SCRIPTS/render-sarif.sh" >/dev/null
}

compare_golden() {
  # compare_golden NAME FILE - diff against test/golden/NAME/FILE (or update).
  local name="$1" file="$2" actual="$V12_WORK_DIR/$2" expected="$GOLDEN_DIR/$1/$2"
  if [ "${UPDATE_GOLDENS:-}" = "1" ]; then
    mkdir -p "$GOLDEN_DIR/$name"
    cp "$actual" "$expected"
    return 0
  fi
  [ -f "$expected" ] || { echo "missing golden $expected (run UPDATE_GOLDENS=1 bats test/golden.bats)" >&2; return 1; }
  diff -u "$expected" "$actual"
}

check_goldens() {
  local name="$1"
  render_fixture "$name"
  compare_golden "$name" comment.md
  compare_golden "$name" check-run.json
  compare_golden "$name" summary.md
  compare_golden "$name" v12.sarif
}

@test "golden: findings (gate failing, delta, suppressions, exclusions)" { check_goldens findings; }
@test "golden: clean run" { check_goldens clean; }
@test "golden: failed run" { check_goldens failed; }
@test "golden: over budget" { check_goldens over-budget; }
@test "golden: empty diff" { check_goldens empty-diff; }
@test "golden: timed out" { check_goldens timed-out; }
@test "golden: cancelled" { check_goldens cancelled; }
@test "golden: full audit" { check_goldens full; }

@test "every golden SARIF validates against the SARIF 2.1.0 schema" {
  if ! python3 -c 'import jsonschema' 2>/dev/null; then
    skip "python3 jsonschema is not installed"
  fi
  local name
  for name in $FIXTURE_NAMES; do
    python3 - "$GOLDEN_DIR/$name/v12.sarif" "$FIXTURES/sarif-schema-2.1.0.json" <<'PY'
import json, sys, jsonschema
doc = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
errors = list(jsonschema.Draft7Validator(schema).iter_errors(doc))
for e in errors[:5]:
    print(sys.argv[1], list(e.absolute_path), e.message[:200])
sys.exit(1 if errors else 0)
PY
  done
}

@test "comment: untrusted text is escaped and the marker appears once" {
  render_fixture findings
  local c="$V12_WORK_DIR/comment.md"
  ! grep -q '<script>' "$c"
  grep -q '&lt;script&gt;alert(1)&lt;/script&gt;' "$c"
  grep -q 'return value &#124; funds stuck' "$c"
  grep -q '&#35; Not a heading' "$c"
  grep -q '&#42;&#42;Bold&#42;&#42;' "$c"
  [ "$(grep -c '<!-- v12-audit-action:pr -->' "$c")" -eq 1 ]
  [ "$(grep -c '<!-- v12-audit-action:state:' "$c")" -eq 1 ]
  # a snippet with ``` is fenced with a longer fence
  grep -q '^````' "$c" || true
}

@test "comment: the state block round-trips fingerprints and the Slack thread" {
  render_fixture findings
  local state
  . "$SCRIPTS/lib.sh"
  state=$(jqx -R -s 'include "common"; state_decode' "$V12_WORK_DIR/comment.md")
  [ "$(jq -r '.sha' <<<"$state")" = "1111111111111111111111111111111111111111" ]
  [ "$(jq -r '.run' <<<"$state")" = "42" ]
  [ "$(jq -r '.fps | length' <<<"$state")" = "$(jq '.findings | length' "$FIXTURES/report-findings.json")" ]
  [ "$(jq -r '.slackTs' <<<"$state")" = "1700000000.000100" ]
  [ "$(jq -r '.slackChannel' <<<"$state")" = "C0123" ]
}

@test "comment: fenced snippets use a fence longer than any run of backticks" {
  jq '.findings |= map(select(.uid == 109)) | .suppressed = []' "$FIXTURES/report-full.json" >"$V12_WORK_DIR/report.json"
  printf '{}' >"$V12_WORK_DIR/event.json"
  make_config
  bash "$SCRIPTS/render-comment.sh" >/dev/null
  grep -q '^````javascript$' "$V12_WORK_DIR/comment.md"
}

@test "comment: actions for non-PR contexts, disabled comments and hide-when-clean" {
  render_fixture clean
  [ "$(output_value comment-action)" = "update-or-create" ]
  render_fixture clean V12_INPUT_HIDE_COMMENT_WHEN_CLEAN=true
  [ "$(output_value comment-action)" = "delete-if-exists" ]
  render_fixture findings V12_INPUT_HIDE_COMMENT_WHEN_CLEAN=true
  [ "$(output_value comment-action)" = "update-or-create" ]
  render_fixture findings V12_INPUT_COMMENT=false
  [ "$(output_value comment-action)" = "skip" ]
  render_fixture full
  [ "$(output_value comment-action)" = "skip" ]
  [[ "$(output_value comment-skip-reason)" == *"not a pull request"* ]]
  render_fixture findings V12_INPUT_COMMENT_KEY=contracts
  [ "$(output_value comment-marker)" = "<!-- v12-audit-action:contracts -->" ]
}

@test "check run: annotations are capped, levels follow the gate, no-location findings are skipped" {
  render_fixture findings V12_INPUT_MAX_ANNOTATIONS=5
  local c="$V12_WORK_DIR/check-run.json"
  [ "$(jq '.annotations | length' "$c")" = "5" ]
  [ "$(jq -r '.annotationsTotal' "$c")" = "15" ]
  grep -q 'capped at 5 of 15' <<<"$(jq -r .summary "$c")"
  [ "$(jq -r '.annotations[0].annotation_level' "$c")" = "failure" ]
  [ "$(jq -r '.conclusion' "$c")" = "failure" ]
  [ "$(jq -r '[.annotations[] | select(.path == "")] | length' "$c")" = "0" ]
  grep -q 'outside this diff' <<<"$(jq -r .summary "$c")"
  render_fixture findings V12_INPUT_FAIL_ON=none
  [ "$(jq -r '.conclusion' "$V12_WORK_DIR/check-run.json")" = "failure" ]
}

@test "check run: conclusion per state" {
  render_fixture clean
  [ "$(output_value check-conclusion)" = "success" ]
  render_fixture failed
  [ "$(output_value check-conclusion)" = "neutral" ]
  render_fixture failed V12_INPUT_FAIL_ON_ERROR=true
  [ "$(output_value check-conclusion)" = "neutral" ]
  render_fixture over-budget
  [ "$(output_value check-conclusion)" = "skipped" ]
  render_fixture cancelled
  [ "$(output_value check-conclusion)" = "cancelled" ]
  render_fixture findings V12_INPUT_CHECK_RUN=false
  [ "$(output_value check-action)" = "skip" ]
}

@test "sarif: caps drop the lowest severities first and report truncation" {
  render_fixture findings
  [ "$(output_value sarif-truncated)" = "false" ]
  V12_SARIF_MAX_RESULTS=4 bash "$SCRIPTS/render-sarif.sh" >/dev/null
  [ "$(output_value sarif-results)" = "4" ]
  [ "$(output_value sarif-truncated)" = "true" ]
  [ "$(jq -r '[.runs[0].results[].properties.severity] | unique | join(",")' "$V12_WORK_DIR/v12.sarif")" = "critical" ]
  V12_SARIF_MAX_GZIP_BYTES=1500 bash "$SCRIPTS/render-sarif.sh" >/dev/null
  [ "$(output_value sarif-truncated)" = "true" ]
  [ "$(gzip -c "$V12_WORK_DIR/v12.sarif" | wc -c | tr -d ' ')" -le 1500 ]
}

@test "sarif: no-location findings anchor to the workflow file; qa is not a security result" {
  jq '.findings |= map(select(.uid == 108 or .uid == 101))' "$FIXTURES/report-findings.json" >"$V12_WORK_DIR/report.json"
  printf '{"workflowPath":".github/workflows/v12.yml"}' >"$V12_WORK_DIR/event.json"
  make_config
  bash "$SCRIPTS/render-sarif.sh" >/dev/null
  local s="$V12_WORK_DIR/v12.sarif"
  [ "$(jq -r '.runs[0].results[] | select(.properties.findingUid == 108) | .locations[0].physicalLocation.artifactLocation.uri' "$s")" = ".github/workflows/v12.yml" ]
  grep -q 'anchored to .github/workflows/v12.yml' <<<"$(jq -r '.runs[0].results[] | select(.properties.findingUid == 108) | .message.text' "$s")"
  [ "$(jq -r '.runs[0].results[] | select(.properties.findingUid == 101) | .partialFingerprints.primaryLocationLineHash' "$s")" = "$(jq -r '.findings[] | select(.uid == 101) | .fingerprint' "$FIXTURES/report-findings.json"):1" ]
  [ "$(jq -r '.runs[0].tool.driver.rules[] | select(.id | startswith("v12/critical/")) | .properties["security-severity"]' "$s" | head -1)" = "9.5" ]
  # a qa finding gets level note and no security-severity
  jq '.findings |= (map(select(.uid == 113)) | map(.severity = "qa" | .ruleId = "v12/qa/floating-pragma-000000"))' "$FIXTURES/report-full.json" >"$V12_WORK_DIR/report.json"
  bash "$SCRIPTS/render-sarif.sh" >/dev/null
  [ "$(jq -r '.runs[0].tool.driver.rules[0].properties["security-severity"] // "absent"' "$s")" = "absent" ]
  [ "$(jq -r '.runs[0].results[0].level' "$s")" = "note" ]
}

@test "sarif: duplicate fingerprints get :1, :2 suffixes and suppressed findings are omitted" {
  render_fixture findings
  local s="$V12_WORK_DIR/v12.sarif"
  [ "$(jq -r '[.runs[0].results[] | select(.properties.findingUid == 105 or .properties.findingUid == 118) | .partialFingerprints.primaryLocationLineHash | split(":")[1]] | sort | join(",")' "$s")" = "1,2" ]
  [ "$(jq -r '[.runs[0].results[] | select(.properties.findingUid == 109)] | length' "$s")" = "0" ]
  [ "$(jq -r '.runs[0].invocations[0].properties.suppressedOmitted' "$s")" = "1" ]
  [ "$(output_value sarif-category)" = "v12-audit/pr" ]
}

@test "summary: is written to GITHUB_STEP_SUMMARY only when enabled" {
  export GITHUB_STEP_SUMMARY="$V12_WORK_DIR/step-summary.md"
  : >"$GITHUB_STEP_SUMMARY"
  render_fixture findings
  grep -q '## V12 security review' "$GITHUB_STEP_SUMMARY"
  grep -q '| Realized | \$12.50 |' "$GITHUB_STEP_SUMMARY"
  : >"$GITHUB_STEP_SUMMARY"
  render_fixture findings V12_INPUT_JOB_SUMMARY=false
  [ ! -s "$GITHUB_STEP_SUMMARY" ]
}
