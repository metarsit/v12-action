#!/usr/bin/env bats
# Unit tests for scripts/lib.sh: outputs, hashing, escaping and the API
# client's retry and error-message behaviour against the stub server.

load test_helper

setup_file() { start_stub; }
teardown_file() { stop_stub; }
setup() { new_work; }

@test "set_output writes single-line and multiline values" {
  . "$SCRIPTS/lib.sh"
  set_output name "value"
  set_output multi $'line1\nline2'
  [ "$(output_value name)" = "value" ]
  [ "$(output_value multi)" = $'line1\nline2' ]
}

@test "sha256_hex matches python's hashlib" {
  . "$SCRIPTS/lib.sh"
  local got want
  got=$(printf 'v12-fp-v1\nsrc/a.sol\nreentrancy withdraw\nabc' | sha256_hex)
  want=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(b"v12-fp-v1\nsrc/a.sol\nreentrancy withdraw\nabc").hexdigest())')
  [ "$got" = "$want" ]
}

@test "escape_command_data encodes percent, CR and LF" {
  . "$SCRIPTS/lib.sh"
  [ "$(escape_command_data $'100% done\r\nnext')" = '100%25 done%0D%0Anext' ]
}

@test "is_true accepts true/yes/1/on case-insensitively" {
  . "$SCRIPTS/lib.sh"
  is_true TRUE && is_true yes && is_true 1 && is_true On
  ! is_true false
  ! is_true ""
  ! is_true maybe
}

@test "v12_api returns 0 on 2xx and stores the body" {
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_ok
  v12_api GET /me
  [ "$V12_STATUS" = "200" ]
  [ "$(jq -r .orgName "$V12_RESP")" = "Acme" ]
}

@test "v12_api retries a 429 honouring Retry-After" {
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_ratelimit
  run v12_api GET /me
  [ "$status" -eq 0 ]
  [ "$(stub_requests GET /api/v1/me | grep -c v12p_ratelimit)" -eq 2 ]
  [[ "$output" == *"rate limit (429)"* ]]
}

@test "v12_api retries a 500 with backoff" {
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_flaky
  run v12_api GET /me
  [ "$status" -eq 0 ]
  [[ "$output" == *"HTTP 500"* ]]
}

@test "v12_api gives up when Retry-After exceeds the wait cap" {
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_retryafter
  run v12_api GET /me
  [ "$status" -eq 1 ]
  [[ "$output" == *"above the ${V12_MAX_RETRY_AFTER}s wait cap"* ]]
}

@test "v12_api fails fast on 401 and explains org binding" {
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_bad
  run v12_api GET /me
  [ "$status" -eq 1 ]
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_bad
  v12_api GET /me || true
  local msg
  msg=$(v12_error_message "$V12_STATUS" "$V12_RESP" GET /me)
  [[ "$msg" == *"401"* ]]
  [[ "$msg" == *"organization"* ]]
  [[ "$msg" == *"Server message: invalid or missing token"* ]]
}

@test "403 message names the missing scope for POST /runs" {
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_readonly
  printf '{"source":"github","repoFullName":"acme/vault","name":"t","branch":"main"}' >"$V12_WORK_DIR/b.json"
  v12_api POST /runs "$V12_WORK_DIR/b.json" || true
  [ "$V12_STATUS" = "403" ]
  local msg
  msg=$(v12_error_message "$V12_STATUS" "$V12_RESP" POST /runs)
  [[ "$msg" == *"'runs:write' scope"* ]]
  [[ "$msg" == *"scope picker"* ]]
}

@test "429 message names the runs:write bucket and the 20/hour limit" {
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_ok
  printf '{}' >"$V12_WORK_DIR/empty.json"
  local msg
  msg=$(v12_error_message 429 "$V12_WORK_DIR/empty.json" POST /runs)
  [[ "$msg" == *"runs:write (20 per user per hour)"* ]]
  [[ "$msg" == *"matrix"* ]]
}

@test "network failure yields status 000 after retries" {
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_ok
  V12_API_URL="http://127.0.0.1:1"
  V12_MAX_ATTEMPTS=2
  run v12_api GET /me
  [ "$status" -eq 1 ]
  . "$SCRIPTS/lib.sh"
  V12_TOKEN=v12p_ok V12_API_URL="http://127.0.0.1:1" V12_MAX_ATTEMPTS=2
  v12_api GET /me || true
  [ "$V12_STATUS" = "000" ]
  [[ "$(v12_error_message 000 "$V12_RESP" GET /me)" == *"Could not reach V12"* ]]
}

@test "require_tools passes on this machine" {
  . "$SCRIPTS/lib.sh"
  require_tools
}

@test "json_get prints nothing for null or missing fields (jq -r prints 'null' otherwise)" {
  . "$SCRIPTS/lib.sh"
  printf '{"a": null, "b": "x", "n": 0}' >"$V12_WORK_DIR/j.json"
  [ -z "$(json_get "$V12_WORK_DIR/j.json" '.a')" ]
  [ -z "$(json_get "$V12_WORK_DIR/j.json" '.missing')" ]
  [ "$(json_get "$V12_WORK_DIR/j.json" '.b')" = "x" ]
  [ "$(json_get "$V12_WORK_DIR/j.json" '.n')" = "0" ]
  [ "$(jq -r '.a' "$V12_WORK_DIR/j.json")" = "null" ]
}

@test "the '[ test ] && cmd && break' footgun is rejected by the bash 3.2 lint" {
  printf '#!/usr/bin/env bash\nset -e\nwhile :; do\n  [ -n "$x" ] && [ "$y" -ge "$z" ] && break\ndone\n' >"$V12_WORK_DIR/bad.sh"
  run bash "$ROOT/test/lint-bash32.sh" "$V12_WORK_DIR/bad.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exits the script under set -e"* ]]
  printf '#!/usr/bin/env bash\nset -e\nif [ -n "$x" ] && [ "$y" -ge "$z" ]; then break; fi\n' >"$V12_WORK_DIR/good.sh"
  run bash "$ROOT/test/lint-bash32.sh" "$V12_WORK_DIR/good.sh"
  [ "$status" -eq 0 ]
}

@test "die inside a subshell does not kill the caller (footgun regression)" {
  . "$SCRIPTS/lib.sh"
  local out
  out=$( (die "inner") 2>&1 || true)
  [[ "$out" == *"::error::inner"* ]]
  echo "still alive"
}
