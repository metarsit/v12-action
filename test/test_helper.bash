# test/test_helper.bash - shared setup for the bats suites.
# Load with:  load test_helper

ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FIXTURES="$ROOT/test/fixtures"
export ROOT SCRIPTS FIXTURES
export V12_JQ_LIB="$SCRIPTS/jq"
export V12_ACTION_VERSION="test"
export V12_NOW="2026-04-26T18:30:00Z"
export V12_POLL_INTERVAL_OVERRIDE="0.2"
export V12_BACKOFF_BASE="1"
export V12_MAX_RETRY_AFTER="5"
export GITHUB_SERVER_URL="https://github.com"
unset RUNNER_DEBUG || true

# ---------------------------------------------------------------------------
# Stub API server (one per test file; call from setup_file / teardown_file)
# ---------------------------------------------------------------------------
start_stub() {
  STUB_DIR="$(mktemp -d "${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}/stub.XXXXXX")"
  STUB_LOG="$STUB_DIR/requests.jsonl"
  : >"$STUB_LOG"
  python3 "$ROOT/test/stub-api.py" --port-file "$STUB_DIR/port" --log "$STUB_LOG" >"$STUB_DIR/stub.err" 2>&1 3>&- &
  STUB_PID=$!
  # A cold Python start on a fresh macOS runner can take several seconds.
  local waited=0
  while [ ! -s "$STUB_DIR/port" ] && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ ! -s "$STUB_DIR/port" ]; then
    echo "stub API did not start within 30s; stderr:" >&2
    cat "$STUB_DIR/stub.err" >&2 || true
    return 1
  fi
  STUB_PORT="$(cat "$STUB_DIR/port")"
  V12_API_URL="http://127.0.0.1:${STUB_PORT}"
  export STUB_DIR STUB_LOG STUB_PID STUB_PORT V12_API_URL
}

stop_stub() {
  if [ -n "${STUB_PID:-}" ]; then
    kill "$STUB_PID" 2>/dev/null || true
    wait "$STUB_PID" 2>/dev/null || true
  fi
}

# stub_requests [METHOD] [PATH_REGEX] - JSON lines of logged requests.
stub_requests() {
  local method="${1:-}" path="${2:-}"
  jq -c --arg m "$method" --arg p "$path" 'select(($m == "" or .method == $m) and ($p == "" or (.path | test($p))))' "$STUB_LOG"
}

# ---------------------------------------------------------------------------
# Per-test working directory and outputs
# ---------------------------------------------------------------------------
new_work() {
  V12_WORK_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/work.XXXXXX")"
  GITHUB_OUTPUT="$V12_WORK_DIR/outputs.txt"
  : >"$GITHUB_OUTPUT"
  export V12_WORK_DIR GITHUB_OUTPUT
}

# output_value NAME - the last value written for a step output.
output_value() {
  awk -v name="$1" '
    BEGIN { val = ""; found = 0 }
    inblock == 1 { if ($0 == delim) { inblock = 0 } else { val = (val == "" && first) ? $0 : val "\n" $0; first = 0 } ; next }
    {
      if (index($0, name "<<") == 1) { delim = substr($0, length(name) + 3); inblock = 1; val = ""; first = 1; found = 1; next }
      if (index($0, name "=") == 1) { val = substr($0, length(name) + 2); found = 1 }
    }
    END { if (found) printf "%s", val }' "$GITHUB_OUTPUT"
}

# run_script NAME [ARGS] - runs scripts/NAME.sh under bats `run`.
run_script() {
  local name="$1"
  shift
  run bash "$SCRIPTS/${name}.sh" "$@"
}

# write_json FILE JSON
write_json() {
  printf '%s\n' "$2" | jq . >"$1"
}

# make_config [ENV=VALUE ...] - builds config.json in the work dir through the
# real config.sh with the given V12_INPUT_* variables.
make_config() {
  local ws="$V12_WORK_DIR/ws"
  mkdir -p "$ws"
  env "$@" GITHUB_WORKSPACE="${GITHUB_WORKSPACE:-$ws}" GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-acme/vault}" \
    V12_WORK_DIR="$V12_WORK_DIR" GITHUB_OUTPUT="$GITHUB_OUTPUT" bash "$SCRIPTS/config.sh" >/dev/null
}

# make_refs_diff / make_refs_full - refs.json for stub scenarios.
make_refs_diff() {
  local repo="${1:-acme/vault}"
  write_json "$V12_WORK_DIR/refs.json" "$(jq -n --arg repo "$repo" '{
    mode: "pr", kind: "diff", repository: $repo, serverUrl: "https://github.com",
    fromSha: "2222222222222222222222222222222222222222", toSha: "1111111111111111111111111111111111111111",
    fromRef: "2222222222222222222222222222222222222222", toRef: "1111111111111111111111111111111111111111",
    branch: "fix/withdraw", sha: null, blobSha: "1111111111111111111111111111111111111111",
    displayRange: "2222222..1111111", runName: "PR #12 Fix withdraw | reentrancy", mergeBaseNote: null, since: null,
    apiPaths: [], shallow: {was: false, unshallowed: false}, changedFilesKnown: true, changedFiles: 3, changedFilesTotal: 3,
    pr: {number: 12, url: "https://github.com/acme/vault/pull/12", title: "Fix withdraw | reentrancy", draft: false,
         headSha: "1111111111111111111111111111111111111111", baseSha: "2222222222222222222222222222222222222222",
         headRef: "fix/withdraw", baseRef: "main", headRepo: $repo, baseRepo: $repo, isFork: false},
    commentPrNumber: 12, empty: false}')"
  write_json "$V12_WORK_DIR/changed-files.json" '{"all":["contracts/Vault.sol","src/crypto/sign.rs","contracts/Permit.sol"],"filtered":["contracts/Vault.sol","src/crypto/sign.rs","contracts/Permit.sol"]}'
}

make_refs_full() {
  local repo="${1:-acme/vault}"
  write_json "$V12_WORK_DIR/refs.json" "$(jq -n --arg repo "$repo" '{
    mode: "full", kind: "full", repository: $repo, serverUrl: "https://github.com",
    fromSha: null, toSha: null, fromRef: null, toRef: null,
    branch: "main", sha: "3333333333333333333333333333333333333333", blobSha: "3333333333333333333333333333333333333333",
    displayRange: "3333333", runName: "Full audit main @ 3333333", mergeBaseNote: null, since: null,
    apiPaths: [], shallow: {was: false, unshallowed: false}, changedFilesKnown: false, changedFiles: null, changedFilesTotal: null,
    pr: null, commentPrNumber: null, empty: false}')"
  printf 'null\n' >"$V12_WORK_DIR/changed-files.json"
}

# run_pipeline_to_report REPO [config env...] - estimate + create + collect.
run_pipeline_to_report() {
  local repo="$1"
  shift
  make_config "$@"
  make_refs_diff "$repo"
  bash "$SCRIPTS/estimate.sh" >/dev/null
  bash "$SCRIPTS/create-and-wait.sh" >/dev/null
  bash "$SCRIPTS/collect-findings.sh" >/dev/null
}

assert_json_eq() {
  # assert_json_eq FILE JQ_EXPR EXPECTED
  local actual
  actual="$(jq -r "$2" "$1")"
  if [ "$actual" != "$3" ]; then
    echo "expected $2 == '$3' but got '$actual' in $1" >&2
    return 1
  fi
}
