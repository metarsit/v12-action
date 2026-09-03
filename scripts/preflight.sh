#!/usr/bin/env bash
# scripts/preflight.sh - runs first: masks the token, checks tools, creates the
# working directory, records the event facts every later step reads, and
# handles the fork-PR-without-secrets case.
#
# Env in:  V12_TOKEN, V12_INPUT_PR_NUMBER, GITHUB_* (event, repository, ...)
# Outputs: work-dir, skipped, skipped-reason, conclusion, is-fork
# Files:   $V12_WORK_DIR/event.json

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

mask "${V12_TOKEN:-}"
require_tools

base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
V12_WORK_DIR=$(mktemp -d "${base%/}/v12-action.XXXXXX")
export V12_WORK_DIR
set_output work-dir "$V12_WORK_DIR"
log_debug "work dir: $V12_WORK_DIR"

payload="$(work_file event-payload.json)"
if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH}" ]; then
  cp "${GITHUB_EVENT_PATH}" "$payload"
else
  printf '{}\n' >"$payload"
fi
if ! jq -e 'type == "object"' "$payload" >/dev/null 2>&1; then
  printf '{}\n' >"$payload"
fi

event_json="$(work_file event.json)"
jqx -n \
  --slurpfile ev "$payload" \
  --arg eventName "${GITHUB_EVENT_NAME:-}" \
  --arg repository "${GITHUB_REPOSITORY:-}" \
  --arg serverUrl "${GITHUB_SERVER_URL:-https://github.com}" \
  --arg apiUrl "${GITHUB_API_URL:-https://api.github.com}" \
  --arg sha "${GITHUB_SHA:-}" \
  --arg ref "${GITHUB_REF:-}" \
  --arg refName "${GITHUB_REF_NAME:-}" \
  --arg refType "${GITHUB_REF_TYPE:-}" \
  --arg runId "${GITHUB_RUN_ID:-}" \
  --arg runAttempt "${GITHUB_RUN_ATTEMPT:-}" \
  --arg workflowRef "${GITHUB_WORKFLOW_REF:-}" \
  --arg actor "${GITHUB_ACTOR:-}" \
  --arg workspace "${GITHUB_WORKSPACE:-$PWD}" \
  --arg prNumberInput "${V12_INPUT_PR_NUMBER:-}" \
  '
  include "common";
  ($ev[0] // {}) as $e
  | ($e.pull_request // null) as $pr
  | ($repository | ascii_downcase) as $repoLower
  | {
      eventName: $eventName,
      repository: $repository,
      serverUrl: $serverUrl,
      apiUrl: $apiUrl,
      sha: $sha,
      ref: $ref,
      refName: $refName,
      refType: $refType,
      runId: $runId,
      runAttempt: $runAttempt,
      actor: $actor,
      workspace: $workspace,
      workflowPath: ($workflowRef | if test("@") then (split("@")[0] | ltrimstr($repository + "/")) else "" end),
      pr: (if $pr == null then null else {
        number: ($pr.number | to_int_or_null),
        url: ($pr.html_url | str),
        title: ($pr.title | str),
        draft: (($pr.draft // false) | to_bool),
        headSha: ($pr.head.sha | str),
        baseSha: ($pr.base.sha | str),
        headRef: ($pr.head.ref | str),
        baseRef: ($pr.base.ref | str),
        headRepo: ($pr.head.repo.full_name | str),
        baseRepo: ($pr.base.repo.full_name | str),
        isFork: (($pr.head.repo == null) or (($pr.head.repo.full_name | str | ascii_downcase) != $repoLower))
      } end),
      mergeGroup: (if $e.merge_group == null then null else {
        headSha: ($e.merge_group.head_sha | str),
        baseSha: ($e.merge_group.base_sha | str),
        headRef: ($e.merge_group.head_ref | str),
        baseRef: ($e.merge_group.base_ref | str)
      } end),
      push: (if $eventName == "push" then {
        before: ($e.before | str),
        after: ($e.after | str),
        created: (($e.created // false) | to_bool),
        deleted: (($e.deleted // false) | to_bool)
      } else null end),
      release: (if $e.release == null then null else { tagName: ($e.release.tag_name | str) } end),
      commentPrNumber: (
        if $pr != null and ($pr.number | to_int_or_null) != null then ($pr.number | to_int_or_null)
        elif ($prNumberInput | to_int_or_null) != null then ($prNumberInput | to_int_or_null)
        else null end)
    }
  | .isFork = ((.pr != null) and .pr.isFork)
  ' >"$event_json"

is_fork=$(jq -r '.isFork' "$event_json")
event_name=$(jq -r '.eventName' "$event_json")
set_output is-fork "$is_fork"

if [ -z "${V12_TOKEN:-}" ]; then
  if [ "$is_fork" = "true" ]; then
    log_notice "V12 audit skipped: this pull request comes from a fork, and GitHub does not pass secrets to workflows triggered by forks, so no V12 token is available. Maintainers can review the change after merge, on a schedule, or with pull_request_target (read the security notes in the README before using it)."
    set_output skipped "true"
    set_output skipped-reason "fork-pr"
    set_output conclusion "skipped"
    exit 0
  fi
  die "v12-token is empty. Store a V12 personal access token as a repository secret (for example V12_TOKEN) and pass it with 'v12-token: secrets.V12_TOKEN'. Create the token at https://v12.sh/settings (Settings -> Developer) while switched to the organization that owns the repository, and tick runs:read and runs:write in the scope picker; new tokens default to read-only scopes."
fi

case "${V12_TOKEN}" in
  v12p_*) ;;
  v12a_*) log_warning "The V12 token looks like an OAuth access token (v12a_*), which expires after one hour. Use a personal access token (v12p_*) from Settings -> Developer for CI." ;;
  *) log_debug "The V12 token does not carry a known prefix (v12p_/v12a_); continuing." ;;
esac

if [ "$is_fork" = "true" ] && [ "$event_name" = "pull_request_target" ]; then
  log_warning "Running on pull_request_target for a fork pull request: this job has the base repository's secrets. Never check out or execute the pull request's head code in this workflow. The audit itself is performed by V12 from the commits on GitHub, not from this checkout."
fi

set_output skipped "false"
log_debug "event: $(cat "$event_json")"
