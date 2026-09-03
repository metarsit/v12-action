#!/usr/bin/env bats
# scripts/collect-findings.sh: pagination, summary-only detail fetching,
# fingerprints, filters, and the gate cross product against test/oracle.py.

load test_helper

setup_file() {
  start_stub
  # One completed run shared by the read-only tests in this file.
  SHARED="$(mktemp -d "$BATS_FILE_TMPDIR/shared.XXXXXX")"
  export SHARED
  (
    V12_WORK_DIR="$SHARED" GITHUB_OUTPUT="$SHARED/outputs.txt"
    : >"$GITHUB_OUTPUT"
    export V12_WORK_DIR GITHUB_OUTPUT V12_TOKEN=v12p_ok
    make_config V12_INPUT_MIN_SEVERITY=qa
    make_refs_diff acme/vault
    bash "$SCRIPTS/estimate.sh" >/dev/null
    bash "$SCRIPTS/create-and-wait.sh" >/dev/null
  )
}
teardown_file() { stop_stub; }

setup() {
  new_work
  export V12_TOKEN=v12p_ok
}

# use_shared_run [config env...] - copies the shared run into this test's
# work dir and rebuilds config.json with the given inputs.
use_shared_run() {
  cp "$SHARED"/{refs.json,run.json,pinned.json,estimate.json,changed-files.json,request-body.json} "$V12_WORK_DIR/"
  make_config "$@"
}
rep() { jq -r "$1" "$V12_WORK_DIR/report.json"; }

@test "default filters keep valid+unreviewed findings, sorted by severity" {
  use_shared_run
  run_script collect-findings
  [ "$status" -eq 0 ]
  [ "$(output_value findings-fetched)" = "25" ]
  # oracle: fail-on none, valid+unreviewed, ignore-auto false, min-severity info
  read -r total gate crit high med low info qa < <(python3 "$ROOT/test/oracle.py" "$FIXTURES/findings-run-42.json" none valid,unreviewed false info)
  [ "$(rep .counts.total)" = "$total" ]
  [ "$(rep .counts.critical)" = "$crit" ]
  [ "$(rep .counts.high)" = "$high" ]
  [ "$(rep .counts.medium)" = "$med" ]
  [ "$(rep .counts.low)" = "$low" ]
  [ "$(rep .counts.info)" = "$info" ]
  [ "$(rep .counts.qa)" = "0" ]
  [ "$(rep .gate.count)" = "0" ]
  [ "$(rep .conclusion)" = "neutral" ]
  [ "$(rep '.findings | map(.severity) | unique | join(",")')" = "critical,high,info,low,medium" ]
  [ "$(rep '.findings[0].severity')" = "critical" ]
  [ "$(rep '.findings[-1].severity')" = "info" ]
  [ "$(rep '.hidden.belowMinSeverity')" = "2" ]
  [ "$(rep '.hidden.validity')" = "4" ]
}

@test "auto-invalidated findings are dropped only while unreviewed" {
  use_shared_run V12_INPUT_IGNORE_AUTO_INVALIDATED=true V12_INPUT_MIN_SEVERITY=qa
  run_script collect-findings
  [ "$status" -eq 0 ]
  # 103 (unreviewed + auto) dropped, 104 (valid + auto) kept, 110/124 dropped
  [ "$(rep '.findings | map(.uid) | index(103)')" = "null" ]
  [ "$(rep '.findings | map(.uid) | index(104) != null')" = "true" ]
  [ "$(rep '.hidden.autoInvalidated')" = "3" ]
}

@test "fingerprints are 16 hex chars, stable, and identical for identical findings" {
  use_shared_run
  run_script collect-findings
  [ "$(rep '.findings | map(.fingerprint | test("^[0-9a-f]{16}$")) | all')" = "true" ]
  local a b
  a=$(rep '.findings[] | select(.uid == 105) | .fingerprint')
  b=$(rep '.findings[] | select(.uid == 118) | .fingerprint')
  [ "$a" = "$b" ]
  local expected
  expected=$(python3 - <<'PY'
import hashlib, re
title = "Reentrancy in withdraw() lets a caller drain the vault"
stop = {"a","an","the","in","of","on","to","is","for","with","via","by","and","or","at","from","as"}
toks = sorted(set(t for t in re.findall(r"[a-z0-9]+", title.lower()) if t not in stop))
snippet = '(bool ok, ) = msg.sender.call{value: amount}("");\nrequire(ok, "transfer failed");\nbalances[msg.sender] -= amount;'
material = "v12-fp-v1\n" + "contracts/Vault.sol" + "\n" + " ".join(toks) + "\n" + re.sub(r"\s+", "", snippet)
print(hashlib.sha256(material.encode()).hexdigest()[:16])
PY
)
  [ "$(rep '.findings[] | select(.uid == 101) | .fingerprint')" = "$expected" ]
  [[ "$(rep '.findings[] | select(.uid == 101) | .ruleId')" == v12/critical/caller-drain-lets-reentrancy-vault-withdraw-* ]]
}

@test "locations, blob links, language and in-diff flags are derived" {
  use_shared_run
  run_script collect-findings
  [ "$(rep '.findings[] | select(.uid == 101) | .blobUrl')" = "https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/contracts/Vault.sol#L118-L121" ]
  [ "$(rep '.findings[] | select(.uid == 101) | .location.lang')" = "solidity" ]
  [ "$(rep '.findings[] | select(.uid == 101) | .inDiff')" = "true" ]
  [ "$(rep '.findings[] | select(.uid == 113) | .inDiff')" = "true" ]
  [ "$(rep '.findings[] | select(.uid == 109) | .inDiff')" = "false" ]
  [ "$(rep '.findings[] | select(.uid == 108) | .hasLocation')" = "false" ]
  [ "$(rep '.findings[] | select(.uid == 108) | .blobUrl')" = "null" ]
  [ "$(rep '.findings[] | select(.uid == 119) | .location.endLine')" = "44" ]
  [ "$(rep '.findings[] | select(.uid == 122) | .blobUrl')" = "https://github.com/acme/vault/blob/1111111111111111111111111111111111111111/src/m%C3%B3dulo/file%20name.sol#L7-L9" ]
}

@test "exclude globs hide findings in matching files" {
  use_shared_run V12_INPUT_EXCLUDE_PATHS='**/test/**'
  run_script collect-findings
  [ "$(rep '.hidden.excludedPath')" = "2" ]
  [ "$(rep '.findings | map(.uid) | index(112)')" = "null" ]
  [ "$(rep '.findings | map(.uid) | index(115)')" = "null" ]
}

@test "pagination follows totalMatching across three pages" {
  use_shared_run
  V12_FINDINGS_PAGE_SIZE=10 run_script collect-findings
  [ "$status" -eq 0 ]
  local offsets
  offsets=$(stub_requests GET '/api/v1/runs/42/findings$' | jq -r 'select(.query.limit[0] == "10") | .query.offset[0]' | tr '\n' ',')
  [ "$offsets" = "0,10,20," ]
  [ "$(rep .totals.fetched)" = "25" ]
  [ "$(rep .totals.totalMatching)" = "25" ]
}

@test "a summary-only list triggers detail fetches for surviving findings only" {
  make_config V12_INPUT_MIN_SEVERITY=qa
  make_refs_diff acme/summary-list
  bash "$SCRIPTS/estimate.sh" >/dev/null
  bash "$SCRIPTS/create-and-wait.sh" >/dev/null
  V12_DETAIL_PAUSE=0 run_script collect-findings
  [ "$status" -eq 0 ]
  [ "$(rep .detail.needed)" = "true" ]
  read -r total _ < <(python3 "$ROOT/test/oracle.py" "$FIXTURES/findings-run-42.json" none valid,unreviewed false qa)
  [ "$(rep .detail.fetched)" = "$total" ]
  [ "$(stub_requests GET '/api/v1/runs/46/findings/[0-9]+$' | wc -l | tr -d ' ')" = "$total" ]
  [ -z "$(stub_requests GET '/api/v1/runs/46/findings/106$')" ]
  [ "$(rep '.findings[] | select(.uid == 101) | .description | length > 0')" = "true" ]
  [ "$(rep '.findings[] | select(.uid == 101) | .detailFetched')" = "true" ]
}

@test "max-findings-detail caps the fan-out most-severe first" {
  make_config V12_INPUT_MIN_SEVERITY=qa V12_INPUT_MAX_FINDINGS_DETAIL=3
  make_refs_diff acme/summary-list
  bash "$SCRIPTS/estimate.sh" >/dev/null
  bash "$SCRIPTS/create-and-wait.sh" >/dev/null
  V12_DETAIL_PAUSE=0 run_script collect-findings
  [ "$status" -eq 0 ]
  [ "$(rep .detail.capped)" = "true" ]
  [ "$(rep .detail.fetched)" = "3" ]
  [[ "$output" == *"fetching the 3 most severe"* ]]
  [ "$(rep '[.findings[] | select(.detailFetched)] | map(.severity) | unique | join(",")')" = "critical" ]
}

@test "a failed run produces a report without findings" {
  make_config
  make_refs_diff acme/failing
  bash "$SCRIPTS/estimate.sh" >/dev/null
  bash "$SCRIPTS/create-and-wait.sh" >/dev/null
  run_script collect-findings
  [ "$status" -eq 0 ]
  [ "$(rep .run.state)" = "failed" ]
  [ "$(rep .counts.total)" = "0" ]
  [ "$(rep .conclusion)" = "failure" ]
  [ "$(rep .jobShouldFail)" = "false" ]
}

@test "a skipped target produces a skipped report" {
  make_config V12_INPUT_MAX_COST_CENTS=1
  make_refs_diff acme/vault
  bash "$SCRIPTS/estimate.sh" >/dev/null
  run_script collect-findings
  [ "$status" -eq 0 ]
  [ "$(rep .skipped.reason)" = "over-budget" ]
  [ "$(rep .conclusion)" = "skipped" ]
  [ "$(rep .estimate.quoteCents)" = "1250" ]
}

@test "300 findings paginate and count correctly" {
  make_config V12_INPUT_MIN_SEVERITY=qa V12_INPUT_INCLUDE_VALIDITY=valid,invalid,unreviewed,acknowledged
  make_refs_diff acme/many
  bash "$SCRIPTS/estimate.sh" >/dev/null
  bash "$SCRIPTS/create-and-wait.sh" >/dev/null
  run_script collect-findings
  [ "$status" -eq 0 ]
  [ "$(rep .counts.total)" = "300" ]
  [ "$(rep .counts.critical)" = "50" ]
  [ "$(stub_requests GET '/api/v1/runs/48/findings$' | wc -l | tr -d ' ')" = "3" ]
}

@test "gate counts match the oracle across fail-on x include-validity x ignore-auto-invalidated" {
  local fail_on validity ignore expected actual
  for fail_on in none critical high medium low info qa; do
    for validity in "valid,unreviewed" "valid" "valid,unreviewed,acknowledged" "valid,invalid,unreviewed,acknowledged" "unreviewed"; do
      for ignore in true false; do
        use_shared_run V12_INPUT_FAIL_ON="$fail_on" V12_INPUT_INCLUDE_VALIDITY="$validity" V12_INPUT_IGNORE_AUTO_INVALIDATED="$ignore" V12_INPUT_MIN_SEVERITY=qa
        bash "$SCRIPTS/collect-findings.sh" >/dev/null
        expected=$(python3 "$ROOT/test/oracle.py" "$FIXTURES/findings-run-42.json" "$fail_on" "$validity" "$ignore" qa)
        actual=$(rep '[.counts.total, .gate.count, .counts.critical, .counts.high, .counts.medium, .counts.low, .counts.info, .counts.qa] | map(tostring) | join(" ")')
        if [ "$expected" != "$actual" ]; then
          echo "fail-on=$fail_on validity=$validity ignore=$ignore: expected '$expected' got '$actual'" >&2
          return 1
        fi
        [ "$(rep .gate.failing)" = "$( [ "${actual#* }" != "0 "* ] && [ "$(cut -d' ' -f2 <<<"$actual")" != "0" ] && echo true || echo false )" ]
      done
    done
  done
}

@test "min-severity hides lower severities and reports how many" {
  use_shared_run V12_INPUT_MIN_SEVERITY=high
  run_script collect-findings
  read -r total _ < <(python3 "$ROOT/test/oracle.py" "$FIXTURES/findings-run-42.json" none valid,unreviewed false high)
  [ "$(rep .counts.total)" = "$total" ]
  # 25 findings, 4 hidden by validity first, the rest below high
  [ "$(rep '.hidden.belowMinSeverity')" = "$((21 - total))" ]
}
