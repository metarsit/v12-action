#!/usr/bin/env bash
# scripts/lib.sh - shared helpers for v12-action.
#
# Sourced by every script. Written to the bash 3.2 floor (macOS runners):
# no associative arrays, no mapfile, no ${var,,}, no |&, no &>>, no negative
# array indexes, and possibly-empty arrays are expanded with the
# ${arr[@]+"${arr[@]}"} idiom because bash 3.2 treats "${arr[@]}" on an
# empty array as an unbound variable under set -u.
#
# External tools: bash, curl, jq (1.6+), git. Nothing GNU-specific: no
# sed -i, grep -P, date -d, base64 -w, readlink -f, stat -c, xargs -r.

if [ -n "${V12_LIB_LOADED:-}" ]; then
  # shellcheck disable=SC2317 # the exit only runs when lib.sh is executed, not sourced
  return 0 2>/dev/null || exit 0
fi
V12_LIB_LOADED=1

set -o errexit
set -o nounset
set -o pipefail

V12_API_URL="${V12_API_URL:-https://v12.sh}"
V12_ACTION_VERSION="${V12_ACTION_VERSION:-dev}"
V12_USER_AGENT="v12-action/${V12_ACTION_VERSION} (+https://github.com/metarsit/v12-action)"
V12_HTTP_TIMEOUT="${V12_HTTP_TIMEOUT:-120}"
V12_MAX_ATTEMPTS="${V12_MAX_ATTEMPTS:-5}"
V12_MAX_RETRY_AFTER="${V12_MAX_RETRY_AFTER:-120}"
V12_BACKOFF_BASE="${V12_BACKOFF_BASE:-2}"
V12_JQ_LIB="${V12_JQ_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/jq}"

# ---------------------------------------------------------------------------
# Logging (GitHub workflow commands)
# ---------------------------------------------------------------------------

# Escape a message for use as workflow-command data (%, CR, LF).
escape_command_data() {
  local s="$1"
  s="${s//%/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

log_debug() {
  if [ "${RUNNER_DEBUG:-0}" = "1" ] || [ "${V12_DEBUG:-0}" = "1" ]; then
    printf '::debug::%s\n' "$(escape_command_data "$*")"
  fi
}
log_info() { printf '%s\n' "$*"; }
log_notice() { printf '::notice::%s\n' "$(escape_command_data "$*")"; }
log_warning() { printf '::warning::%s\n' "$(escape_command_data "$*")"; }
log_error() { printf '::error::%s\n' "$(escape_command_data "$*")"; }
group_start() { printf '::group::%s\n' "$*"; }
group_end() { printf '::endgroup::\n'; }

# die MESSAGE - print an error annotation and exit 1.
# Never call die inside an `if` condition or a `&&` chain that expects to
# continue: exit inside a condition still terminates the script.
die() {
  log_error "$*"
  exit 1
}

mask() {
  if [ -n "${1:-}" ]; then
    printf '::add-mask::%s\n' "$1"
  fi
}

# ---------------------------------------------------------------------------
# Outputs and state
# ---------------------------------------------------------------------------

# set_output NAME VALUE - write a step output (multiline safe).
set_output() {
  local name="$1" value="$2" delim
  if [ -z "${GITHUB_OUTPUT:-}" ]; then
    log_debug "output (no GITHUB_OUTPUT): $name=$value"
    return 0
  fi
  case "$value" in
    *$'\n'*)
      delim="v12EOF${RANDOM}${RANDOM}"
      printf '%s<<%s\n%s\n%s\n' "$name" "$delim" "$value" "$delim" >>"$GITHUB_OUTPUT"
      ;;
    *)
      printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
      ;;
  esac
}

# set_outputs_from_json FILE - every top-level key of the object becomes an
# output. Values that are objects/arrays are emitted as compact JSON.
set_outputs_from_json() {
  local file="$1" name value
  # Tab-separated name/value pairs; values are JSON-encoded for safety, then
  # decoded here so that strings come out raw.
  while IFS=$'\t' read -r name value; do
    [ -n "$name" ] || continue
    value=$(printf '%s' "$value" | jq -r 'if type == "string" then . else tojson end')
    set_output "$name" "$value"
  done < <(jq -r 'to_entries[] | [.key, (.value | tojson)] | @tsv' "$file")
}

# work_file NAME - absolute path of a file in the working directory.
work_file() {
  printf '%s/%s' "${V12_WORK_DIR:?V12_WORK_DIR is not set}" "$1"
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    true | yes | 1 | on) return 0 ;;
    *) return 1 ;;
  esac
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# sha256_hex - hex digest of stdin. Prefers sha256sum, then shasum (macOS),
# then openssl (LibreSSL and OpenSSL 1.1/3 output formats both handled).
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then # bash32-lint: allow
    sha256sum | cut -d' ' -f1                   # bash32-lint: allow
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | sed -E 's/^.*= *//'
  else
    die "No SHA-256 tool found (need sha256sum, shasum or openssl)." # bash32-lint: allow
  fi
}

file_size() {
  # Portable byte count (wc -c pads with spaces on macOS).
  wc -c <"$1" | tr -d ' '
}

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# money CENTS - "$12.50" (n/a for empty).
money() {
  printf '%s' "${1:-null}" | jq -L "$V12_JQ_LIB" -r 'include "common"; money_cents'
}

# jq wrapper that always has the shared library on its search path.
jqx() {
  jq -L "$V12_JQ_LIB" "$@"
}

# json_get FILE EXPR - raw value of a jq expression, empty for null.
json_get() {
  jq -r "$2 // empty" "$1"
}

require_tools() {
  local missing="" t
  for t in curl jq git; do
    if ! command -v "$t" >/dev/null 2>&1; then
      missing="$missing $t"
    fi
  done
  if [ -n "$missing" ]; then
    die "Missing required tool(s):${missing}. v12-action needs curl, jq (1.6 or newer) and git on the runner. Install them (apt-get install curl jq git / brew install curl jq git) or use a GitHub-hosted runner, which has all three."
  fi
  local jqv
  jqv=$(jq --version 2>/dev/null || echo "jq-0")
  log_debug "tools: $(curl --version | head -1); ${jqv}; $(git --version); bash ${BASH_VERSION}"
  case "$jqv" in
    jq-1.[0-5]*) die "jq ${jqv#jq-} is too old; v12-action needs jq 1.6 or newer." ;;
  esac
}

# ---------------------------------------------------------------------------
# V12 REST client
# ---------------------------------------------------------------------------
#
# v12_api METHOD PATH [BODY_FILE] [ACCEPT]
#   Performs one logical request with retries. On return:
#     V12_STATUS   HTTP status (000 when the transport failed)
#     V12_RESP     path to the response body file
#   Returns 0 on 2xx and 1 otherwise. It never exits on a non-2xx status so
#   callers can treat an expected 404 (report, PoC) as a normal branch. Use
#   v12_fail STATUS RESP PATH to turn a failure into an actionable error.
#
#   Retries: 429 honours Retry-After (capped at V12_MAX_RETRY_AFTER seconds),
#   5xx and transport errors back off exponentially. Other 4xx fail fast.

V12_STATUS=""
V12_RESP=""

_v12_header() {
  # _v12_header FILE NAME - value of a response header, case-insensitive.
  tr -d '\r' <"$1" | awk -v name="$(lower "$2")" -F': *' 'tolower($1) == name { print $2; exit }'
}

v12_api() {
  local method="$1" path="$2" body_file="${3:-}" accept="${4:-application/json}"
  local url="${V12_API_URL%/}/api/v1${path}"
  local attempt=0 delay="$V12_BACKOFF_BASE" rc status retry_after headers
  local stamp="${RANDOM}${RANDOM}"
  V12_RESP="$(work_file "http-${stamp}.body")"
  headers="$(work_file "http-${stamp}.headers")"
  : "${V12_TOKEN:?V12_TOKEN is not set}"

  while :; do
    attempt=$((attempt + 1))
    rc=0
    status=""
    if [ -n "$body_file" ]; then
      log_debug "-> $method $url body=$(cat "$body_file")"
      status=$(curl -sS --max-time "$V12_HTTP_TIMEOUT" -o "$V12_RESP" -D "$headers" -w '%{http_code}' \
        -X "$method" -H "Authorization: Bearer ${V12_TOKEN}" -H "Accept: ${accept}" \
        -H "Content-Type: application/json" -H "User-Agent: ${V12_USER_AGENT}" \
        --data-binary "@${body_file}" "$url") || rc=$?
    else
      log_debug "-> $method $url"
      status=$(curl -sS --max-time "$V12_HTTP_TIMEOUT" -o "$V12_RESP" -D "$headers" -w '%{http_code}' \
        -X "$method" -H "Authorization: Bearer ${V12_TOKEN}" -H "Accept: ${accept}" \
        -H "User-Agent: ${V12_USER_AGENT}" "$url") || rc=$?
    fi
    [ -f "$V12_RESP" ] || : >"$V12_RESP"
    if [ "$rc" -ne 0 ] || [ -z "$status" ]; then
      status="000"
    fi
    V12_STATUS="$status"
    log_debug "<- $status $(head -c 4000 "$V12_RESP" 2>/dev/null || true)"

    case "$status" in
      2[0-9][0-9])
        return 0
        ;;
      429)
        retry_after=$(_v12_header "$headers" "Retry-After" 2>/dev/null || true)
        case "$retry_after" in
          '' | *[!0-9]*) retry_after="$delay" ;;
        esac
        if [ "$retry_after" -gt "$V12_MAX_RETRY_AFTER" ]; then
          log_warning "V12 rate limit on $method $path: Retry-After is ${retry_after}s, above the ${V12_MAX_RETRY_AFTER}s wait cap; giving up."
          return 1
        fi
        if [ "$attempt" -ge "$V12_MAX_ATTEMPTS" ]; then
          return 1
        fi
        log_warning "V12 rate limit (429) on $method $path; waiting ${retry_after}s before retry $((attempt + 1))/${V12_MAX_ATTEMPTS}."
        sleep "$retry_after"
        ;;
      000 | 5[0-9][0-9])
        if [ "$attempt" -ge "$V12_MAX_ATTEMPTS" ]; then
          return 1
        fi
        log_warning "V12 request $method $path failed (HTTP $status); retrying in ${delay}s ($((attempt + 1))/${V12_MAX_ATTEMPTS})."
        sleep "$delay"
        delay=$((delay * 2))
        ;;
      *)
        return 1
        ;;
    esac
  done
}

# v12_scope_for METHOD PATH - the scope a request needs (for 403 messages).
v12_scope_for() {
  local method="$1" path="$2"
  case "$method $path" in
    "POST /runs/estimate") printf 'runs:read' ;;
    "POST /runs" | "POST /zips") printf 'runs:write' ;;
    POST\ /runs/*/cancel | PUT\ /runs/*/share) printf 'runs:manage' ;;
    PATCH\ /runs/*/findings/* | POST\ /runs/*/findings/*/comments) printf 'findings:write' ;;
    "GET /me") printf 'user:read' ;;
    "GET /repos") printf 'repos:read' ;;
    *) printf 'runs:read' ;;
  esac
}

# v12_bucket_for METHOD PATH - the rate-limit bucket (for 429 messages).
v12_bucket_for() {
  local method="$1" path="$2"
  case "$method $path" in
    "POST /runs/estimate") printf 'runs:estimate (30 per user per hour)' ;;
    "POST /runs" | "POST /zips") printf 'runs:write (20 per user per hour)' ;;
    POST\ /runs/*/cancel | PUT\ /runs/*/share) printf 'runs:manage (60 per minute)' ;;
    GET\ /runs/*/findings/* | GET\ /runs/*/report) printf 'reads:artifact (300 per minute)' ;;
    "GET /repos") printf 'reads:github (300 per minute)' ;;
    *) printf 'reads (1200 per minute)' ;;
  esac
}

# v12_error_message STATUS RESP_FILE METHOD PATH - human explanation.
v12_error_message() {
  local status="$1" file="$2" method="$3" path="$4" msg scope bucket
  msg=$(jq -r 'if type == "object" then (.message // .error // empty) else empty end' "$file" 2>/dev/null || true)
  if [ -z "$msg" ] && [ -s "$file" ]; then
    msg=$(head -c 300 "$file" | tr '\n' ' ')
  fi
  case "$status" in
    401)
      printf 'V12 rejected the token (401) on %s %s. The token is invalid, expired, or its user is no longer a member of the organization the token is bound to. Create a new personal access token at https://v12.sh/settings (Settings -> Developer) while switched to the right organization, and store it as the V12_TOKEN secret.' "$method" "$path"
      ;;
    403)
      scope=$(v12_scope_for "$method" "$path")
      printf "V12 refused %s %s (403): the token lacks the '%s' scope. New tokens default to runs:read, user:read and repos:read only; writes are opt-in. Create a new token and tick '%s' in the scope picker (this action needs runs:read and runs:write, plus runs:manage to cancel runs)." "$method" "$path" "$scope" "$scope"
      ;;
    429)
      bucket=$(v12_bucket_for "$method" "$path")
      printf 'V12 rate limit reached (429) on %s %s, bucket %s. Buckets are per user and shared across REST, MCP and the CLI. A matrix over many repositories exhausts runs:write (20 per hour) and runs:estimate (30 per hour): spread runs out, or use one token per team.' "$method" "$path" "$bucket"
      ;;
    400 | 422)
      printf 'V12 rejected the request %s %s as invalid (HTTP %s).' "$method" "$path" "$status"
      ;;
    404)
      printf 'V12 returned not found (404) for %s %s.' "$method" "$path"
      ;;
    409)
      printf 'V12 returned a conflict (409) for %s %s.' "$method" "$path"
      ;;
    000)
      printf 'Could not reach V12 at %s for %s %s after %s attempts (network error or timeout).' "$V12_API_URL" "$method" "$path" "$V12_MAX_ATTEMPTS"
      ;;
    5*)
      printf 'V12 returned a server error (HTTP %s) for %s %s after %s attempts.' "$status" "$method" "$path" "$V12_MAX_ATTEMPTS"
      ;;
    *)
      printf 'V12 request %s %s failed with HTTP %s.' "$method" "$path" "$status"
      ;;
  esac
  if [ -n "$msg" ]; then
    printf ' Server message: %s' "$msg"
  fi
}

# v12_fail METHOD PATH - die with the explanation for the last v12_api call.
v12_fail() {
  die "$(v12_error_message "$V12_STATUS" "$V12_RESP" "$1" "$2")"
}

# v12_get_json PATH OUT_FILE - GET a JSON document or die.
v12_get_json() {
  local path="$1" out="$2"
  if v12_api GET "$path"; then
    cp "$V12_RESP" "$out"
    return 0
  fi
  v12_fail GET "$path"
}
