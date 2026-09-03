#!/usr/bin/env bash
# scripts/resolve-refs.sh - decides what to audit.
#
# Turns the event context and configuration into an exact target: either a
# diff review (fromRef..toRef, both commit SHAs) or a full audit (branch +
# sha). Handles merge-base for pull requests, time windows resolved from git
# history, shallow clones, detached HEAD, tags, merge queues, and the
# empty-diff skip. Also expands path globs into V12 `paths` entries.
#
# Env in:  V12_WORK_DIR (with event.json, config.json), GITHUB_WORKSPACE
# Files:   $V12_WORK_DIR/refs.json, changed-files.json
# Outputs: skipped, skipped-reason, conclusion, mode, audit-kind, commit-range

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set}"

event_json="$(work_file event.json)"
config_json="$(work_file config.json)"
refs_json="$(work_file refs.json)"
changed_json="$(work_file changed-files.json)"
workspace="${GITHUB_WORKSPACE:-$PWD}"

cfg() { json_get "$config_json" "$1"; }
ev() { json_get "$event_json" "$1"; }

mode=""
kind=""
repository=""
from_sha=""
to_sha=""
blob_sha=""

skip() {
  # skip REASON MESSAGE - record a skip and exit 0.
  local reason="$1" message="$2"
  log_notice "V12 audit skipped ($reason): $message"
  local existing='{}'
  if [ -s "$refs_json" ] && jq -e 'type == "object"' "$refs_json" >/dev/null 2>&1; then
    existing=$(cat "$refs_json")
  fi
  jq -n --arg reason "$reason" --arg message "$message" --argjson existing "$existing" \
    --arg mode "$mode" --arg kind "$kind" --arg repository "$repository" \
    --arg fromSha "$from_sha" --arg toSha "$to_sha" --arg blobSha "$blob_sha" \
    --slurpfile ev "$event_json" \
    '$existing + {mode: $mode, kind: $kind, repository: $repository, serverUrl: $ev[0].serverUrl, pr: $ev[0].pr,
      commentPrNumber: $ev[0].commentPrNumber, blobSha: (if $blobSha == "" then null else $blobSha end),
      fromSha: (if $fromSha == "" then null else $fromSha end), toSha: (if $toSha == "" then null else $toSha end),
      displayRange: (if $fromSha != "" and $toSha != "" then "\($fromSha[0:7])..\($toSha[0:7])" else null end),
      empty: true, skippedReason: $reason, skippedMessage: $message}' >"$(work_file refs.tmp)"
  mv "$(work_file refs.tmp)" "$refs_json"
  set_output skipped "true"
  set_output skipped-reason "$reason"
  set_output conclusion "skipped"
  exit 0
}

# --- git helpers (workspace may not be a repository) -------------------------

have_git_repo=false
if git -C "$workspace" rev-parse --git-dir >/dev/null 2>&1; then
  have_git_repo=true
fi

g() { git -C "$workspace" "$@"; }

is_shallow() {
  [ "$have_git_repo" = true ] || return 1
  [ "$(g rev-parse --is-shallow-repository 2>/dev/null || echo false)" = "true" ]
}

was_shallow=false
unshallowed=false
unshallow_repo() {
  # unshallow_repo WHY - best effort; returns 0 when the repository has full history.
  if ! is_shallow; then
    return 0
  fi
  was_shallow=true
  log_warning "The checkout is shallow (actions/checkout defaults to fetch-depth: 1), which cannot resolve $1. Fetching full history now; set 'fetch-depth: 0' on actions/checkout to avoid this."
  if g fetch --unshallow --no-tags --quiet origin 2>/dev/null; then
    unshallowed=true
    return 0
  fi
  log_warning "Could not unshallow the repository (no network, or credentials were not persisted). Continuing with the shallow history."
  return 1
}

have_commit() {
  [ "$have_git_repo" = true ] || return 1
  g cat-file -e "$1^{commit}" 2>/dev/null
}

fetch_ref() {
  # fetch_ref REFSPEC - best effort fetch of a ref or SHA.
  [ "$have_git_repo" = true ] || return 1
  g fetch --no-tags --quiet origin "$1" 2>/dev/null
}

resolve_local() {
  # resolve_local REF - prints the commit SHA for a local ref, empty otherwise.
  [ "$have_git_repo" = true ] || return 0
  g rev-parse --verify --quiet "$1^{commit}" 2>/dev/null || true
}

# --- mode ------------------------------------------------------------------

mode=$(cfg .mode)
event_name=$(ev .eventName)
ref_type=$(ev .refType)
since=$(cfg .since)
base_ref_in=$(cfg .baseRef)
head_ref_in=$(cfg .headRef)
has_pr=false
if [ "$(jq -r '.pr != null' "$event_json")" = "true" ]; then has_pr=true; fi
has_mg=false
if [ "$(jq -r '.mergeGroup != null' "$event_json")" = "true" ]; then has_mg=true; fi

if [ "$mode" = "auto" ]; then
  case "$event_name" in
    pull_request | pull_request_target | merge_group) mode="pr" ;;
    schedule) if [ -n "$since" ] || [ -n "$base_ref_in" ]; then mode="diff"; else mode="full"; fi ;;
    push) if [ "$ref_type" = "tag" ]; then mode="full"; elif [ -n "$since" ] || [ -n "$base_ref_in" ]; then mode="diff"; else mode="push-diff"; fi ;;
    release) mode="full" ;;
    *) if [ -n "$since" ] || [ -n "$base_ref_in" ]; then mode="diff"; elif [ "$has_pr" = true ]; then mode="pr"; else mode="full"; fi ;;
  esac
fi
log_info "Audit mode: $mode (event: ${event_name:-none})"

repository=$(cfg .repository)
kind="diff"
from_sha=""
to_sha=""
branch=""
sha=""
blob_sha=""
run_name=$(cfg .name)
pr_number=$(ev .pr.number)
since_info="null"
mb_note=""

case "$mode" in
  pr)
    if [ "$has_pr" = true ]; then
      base_sha=$(ev .pr.baseSha)
      head_sha=$(ev .pr.headSha)
      if [ -z "$base_sha" ] || [ -z "$head_sha" ]; then
        die "The pull request payload has no base/head SHA; cannot run a PR review."
      fi
      if [ "$have_git_repo" = true ]; then
        unshallow_repo "the merge base of the pull request" || true
        have_commit "$head_sha" || fetch_ref "refs/pull/${pr_number}/head" || fetch_ref "$head_sha" || true
        have_commit "$base_sha" || fetch_ref "$base_sha" || true
        if have_commit "$base_sha" && have_commit "$head_sha"; then
          from_sha=$(g merge-base "$base_sha" "$head_sha" 2>/dev/null || true)
        fi
      fi
      if [ -z "$from_sha" ]; then
        from_sha="$base_sha"
        mb_note="merge-base unavailable; using the base branch tip"
        log_warning "Could not compute the merge base of ${base_sha} and ${head_sha}; reviewing against the base branch tip instead. Set 'fetch-depth: 0' on actions/checkout for an exact PR diff."
      fi
      to_sha="$head_sha"
      blob_sha="$head_sha"
      branch=$(ev .pr.headRef)
      if [ -z "$run_name" ]; then
        run_name=$(jq -r '"PR #\(.pr.number | tostring) " + (.pr.title | .[0:100])' "$event_json")
      fi
    elif [ "$has_mg" = true ]; then
      from_sha=$(ev .mergeGroup.baseSha)
      to_sha=$(ev .mergeGroup.headSha)
      if [ -z "$from_sha" ] || [ -z "$to_sha" ]; then
        die "The merge_group payload has no base/head SHA."
      fi
      blob_sha="$to_sha"
      branch=$(ev .mergeGroup.headRef)
      if [ -z "$run_name" ]; then
        run_name="Merge queue $(ev .mergeGroup.headRef | sed -E 's#^refs/heads/##') ($(printf '%s' "$to_sha" | cut -c1-7))"
      fi
    else
      die "mode 'pr' needs a pull_request, pull_request_target or merge_group event (got '${event_name:-none}'). Use mode: diff with base-ref/head-ref, or mode: auto."
    fi
    ;;

  push-diff)
    before=$(ev .push.before)
    after=$(ev .push.after)
    if [ "$(ev .push.deleted)" = "true" ]; then
      skip "branch-deleted" "the push deleted the branch."
    fi
    case "$before" in
      '' | 0000000000000000000000000000000000000000)
        skip "no-previous-commit" "this push created the branch, so there is no previous commit to diff against. Use mode: full to audit the whole tree, or mode: diff with since: to review a time window."
        ;;
    esac
    if [ "$have_git_repo" = true ]; then
      have_commit "$before" || fetch_ref "$before" || true
      have_commit "$after" || fetch_ref "$after" || true
    fi
    from_sha="$before"
    to_sha="$after"
    blob_sha="$after"
    branch=$(ev .refName)
    mode="diff"
    if [ -z "$run_name" ]; then
      run_name="Push ${branch} $(printf '%s' "$before" | cut -c1-7)..$(printf '%s' "$after" | cut -c1-7)"
    fi
    ;;

  diff)
    [ "$have_git_repo" = true ] || die "mode 'diff' needs a git checkout of the repository (add actions/checkout with fetch-depth: 0 before this action)."
    branch=$(cfg .branch)
    [ -n "$branch" ] || branch=$(ev .refName)
    if [ -n "$head_ref_in" ]; then
      to_sha=$(resolve_local "$head_ref_in")
      if [ -z "$to_sha" ]; then
        if fetch_ref "$head_ref_in"; then
          to_sha=$(resolve_local "FETCH_HEAD")
        fi
      fi
      [ -n "$to_sha" ] || die "head-ref '${head_ref_in}' does not resolve to a commit in this checkout."
    else
      to_sha=$(resolve_local HEAD)
      [ -n "$to_sha" ] || to_sha=$(ev .sha)
    fi
    [ -n "$to_sha" ] || die "Cannot determine the head commit for the diff review."
    if [ -n "$base_ref_in" ]; then
      from_sha=$(resolve_local "$base_ref_in")
      if [ -z "$from_sha" ]; then
        if fetch_ref "$base_ref_in"; then
          from_sha=$(resolve_local "FETCH_HEAD")
        fi
      fi
      [ -n "$from_sha" ] || die "base-ref '${base_ref_in}' does not resolve to a commit in this checkout."
      if [ -z "$run_name" ]; then
        run_name="Diff ${base_ref_in}..${head_ref_in:-$(printf '%s' "$to_sha" | cut -c1-7)}"
      fi
    elif [ -n "$since" ]; then
      if ! unshallow_repo "a time window ('since: ${since}')"; then
        if is_shallow; then
          die "Cannot resolve 'since: ${since}' on a shallow clone. Set 'fetch-depth: 0' on actions/checkout."
        fi
      fi
      # git's approximate-date parser silently treats garbage as "now", so
      # sanity-check the expression first: it must contain a digit or a
      # relative-date keyword ("7 days ago", "yesterday", "last month",
      # "2026-01-31", "@1700000000").
      case "$(lower "$since")" in
        *[0-9]* | *now* | *last* | *ago* | *week* | *month* | *year* | *day* | *hour* | *minute* | *noon* | *midnight* | *tea*) ;;
        *) die "since: '${since}' is not a date expression git understands. Use forms such as '7 days ago', '2 weeks ago', 'yesterday' or '2026-01-31'." ;;
      esac
      from_sha=$(g rev-list -1 --before="$since" "$to_sha" 2>/dev/null || true)
      window_note=$(g log -1 --format='%h (%cI)' "$to_sha" 2>/dev/null || true)
      log_info "Window: since '${since}' -> $(if [ -n "$from_sha" ]; then g log -1 --format='%h committed %cI' "$from_sha"; else printf 'no commit before the window start'; fi); head ${window_note}"
      fallback_root=false
      if [ -z "$from_sha" ]; then
        from_sha=$(g rev-list --max-parents=0 "$to_sha" | tail -1)
        fallback_root=true
        log_warning "The window 'since: ${since}' predates the first commit reachable from ${to_sha}; reviewing from the root commit $(printf '%s' "$from_sha" | cut -c1-7) instead."
      fi
      since_info=$(jq -n --arg since "$since" --arg from "$from_sha" --argjson root "$fallback_root" '{since: $since, resolvedFrom: $from, fallbackToRoot: $root}')
      if [ -z "$run_name" ]; then
        run_name="Diff ${branch} since ${since}"
      fi
    else
      die "mode 'diff' needs either 'since' (for example '7 days ago') or base-ref/head-ref."
    fi
    blob_sha="$to_sha"
    ;;

  full)
    kind="full"
    branch=$(cfg .branch)
    sha=$(cfg .sha)
    if [ -z "$branch" ]; then
      branch=$(ev .refName)
    fi
    if [ -z "$branch" ] && [ "$have_git_repo" = true ]; then
      branch=$(g symbolic-ref --short -q HEAD 2>/dev/null || true)
    fi
    [ -n "$branch" ] || die "Cannot determine the branch or tag to audit: set the 'branch' input (a branch or tag name)."
    if [ -z "$sha" ]; then
      sha=$(ev .sha)
    fi
    if [ -z "$sha" ] && [ "$have_git_repo" = true ]; then
      sha=$(resolve_local HEAD)
    fi
    if [ -n "$sha" ] && [ "$have_git_repo" = true ] && ! have_commit "$sha"; then
      resolved=$(resolve_local "$sha")
      [ -n "$resolved" ] && sha="$resolved"
    fi
    blob_sha="$sha"
    if [ -z "$run_name" ]; then
      tag_name=$(ev .release.tagName)
      if [ -n "$tag_name" ]; then
        run_name="Release ${tag_name}"
      else
        run_name="Full audit ${branch}${sha:+ @ $(printf '%s' "$sha" | cut -c1-7)}"
      fi
    fi
    ;;
  *)
    die "Unknown mode '$mode'."
    ;;
esac

# --- changed files and the empty-diff skip ---------------------------------

printf 'null\n' >"$changed_json"
changed_known=false
if [ "$kind" = "diff" ] && [ "$have_git_repo" = true ] && have_commit "$from_sha" && have_commit "$to_sha"; then
  if g diff --name-only "$from_sha" "$to_sha" >"$(work_file changed-files.txt)" 2>/dev/null; then
    changed_known=true
    jqx -R -s --slurpfile cfg "$config_json" '
      include "common";
      ($cfg[0]) as $c
      | split("\n") | map(select(length > 0))
      | {
          all: .,
          filtered: (map(select(
              (($c.paths | length) == 0 or glob_match($c.paths))
              and (($c.excludePaths | length) == 0 or (glob_match($c.excludePaths) | not))
            )))
        }' "$(work_file changed-files.txt)" >"$changed_json"
  fi
fi

if [ "$kind" = "diff" ] && [ "$from_sha" = "$to_sha" ]; then
  printf '{}\n' >"$refs_json"
  skip "empty-diff" "the range ${from_sha} resolves to a single commit, so there is nothing to review."
fi

# --- V12 paths from include globs ------------------------------------------

api_paths='[]'
if [ "$(jq -r '.paths | length' "$config_json")" != "0" ]; then
  tree_sha="$to_sha"
  [ "$kind" = "full" ] && tree_sha="$sha"
  tree_file="$(work_file tree-files.txt)"
  : >"$tree_file"
  if [ "$have_git_repo" = true ] && [ -n "$tree_sha" ] && have_commit "$tree_sha"; then
    g ls-tree -r --name-only "$tree_sha" >"$tree_file" 2>/dev/null || : >"$tree_file"
  fi
  api_paths=$(jqx -n --slurpfile cfg "$config_json" --rawfile tree "$tree_file" '
    include "common";
    ($cfg[0]) as $c
    | ($tree | split("\n") | map(select(length > 0))) as $files
    | [ $c.paths[] | . as $p | ($p | glob_to_api_path) as $prefix
        | if $prefix != null then $prefix
          else ($files | map(select(glob_match([$p]))) | map(select(($c.excludePaths | length) == 0 or (glob_match($c.excludePaths) | not))) | .[])
          end ]
    | unique')
  n_paths=$(printf '%s' "$api_paths" | jq 'length')
  if [ "$n_paths" -gt 500 ]; then
    die "paths expand to ${n_paths} entries, above V12's limit of 500. Use directory prefixes (for example contracts/ or contracts/**) instead of file globs."
  fi
  if [ "$n_paths" -eq 0 ]; then
    if [ -z "$(head -c1 "$tree_file")" ] && [ "$have_git_repo" = true ]; then
      die "paths contain wildcard patterns that need the git tree of ${tree_sha:-the audited commit} to expand, but it is not available in this checkout."
    fi
    printf '{}\n' >"$refs_json"
    skip "no-matching-paths" "no files match the configured paths ($(jq -r '.paths | join(", ")' "$config_json"))."
  fi
fi

if [ "$kind" = "diff" ] && [ "$changed_known" = true ] && [ "$(cfg .skipIfUnchanged)" = "true" ]; then
  n_changed=$(jq -r '.filtered | length' "$changed_json")
  n_all=$(jq -r '.all | length' "$changed_json")
  if [ "$n_changed" -eq 0 ]; then
    printf '{}\n' >"$refs_json"
    if [ "$n_all" -eq 0 ]; then
      skip "empty-diff" "no files changed between $(printf '%s' "$from_sha" | cut -c1-7) and $(printf '%s' "$to_sha" | cut -c1-7)."
    else
      skip "empty-diff" "${n_all} file(s) changed between $(printf '%s' "$from_sha" | cut -c1-7) and $(printf '%s' "$to_sha" | cut -c1-7), but none match the configured paths/exclude-paths."
    fi
  fi
fi

# --- write refs.json --------------------------------------------------------

jq -n \
  --arg mode "$mode" --arg kind "$kind" --arg repository "$repository" \
  --arg fromSha "$from_sha" --arg toSha "$to_sha" --arg branch "$branch" --arg sha "$sha" \
  --arg blobSha "$blob_sha" --arg runName "$run_name" --arg mbNote "$mb_note" \
  --argjson since "$since_info" --argjson apiPaths "$api_paths" \
  --argjson wasShallow "$was_shallow" --argjson unshallowed "$unshallowed" --argjson changedKnown "$changed_known" \
  --slurpfile ev "$event_json" --slurpfile changed "$changed_json" '
  {
    mode: $mode, kind: $kind, repository: $repository,
    fromSha: (if $kind == "diff" then $fromSha else null end),
    toSha: (if $kind == "diff" then $toSha else null end),
    fromRef: (if $kind == "diff" then $fromSha else null end),
    toRef: (if $kind == "diff" then $toSha else null end),
    branch: $branch,
    sha: (if $kind == "full" then $sha else null end),
    blobSha: $blobSha,
    displayRange: (if $kind == "diff" then "\($fromSha[0:7])..\($toSha[0:7])" else $sha[0:7] end),
    runName: ($runName | .[0:200]),
    mergeBaseNote: (if $mbNote == "" then null else $mbNote end),
    since: $since,
    apiPaths: $apiPaths,
    shallow: {was: $wasShallow, unshallowed: $unshallowed},
    changedFilesKnown: $changedKnown,
    changedFiles: (if $changedKnown then ($changed[0].filtered | length) else null end),
    changedFilesTotal: (if $changedKnown then ($changed[0].all | length) else null end),
    pr: $ev[0].pr,
    commentPrNumber: $ev[0].commentPrNumber,
    serverUrl: $ev[0].serverUrl,
    empty: false
  }' >"$refs_json"

set_output skipped "false"
set_output mode "$mode"
set_output audit-kind "$kind"
set_output commit-range "$(jq -r '.displayRange' "$refs_json")"
log_info "Target: $(jq -r 'if .kind == "diff" then "diff review \(.fromSha)..\(.toSha) on \(.repository)" else "full audit of \(.repository) \(.branch) @ \(.sha)" end' "$refs_json")"
if [ "$(jq -r '.apiPaths | length' "$refs_json")" != "0" ]; then
  log_info "Paths sent to V12: $(jq -r '.apiPaths | join(", ")' "$refs_json")"
fi
log_debug "refs: $(cat "$refs_json")"
