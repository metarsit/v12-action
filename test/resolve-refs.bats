#!/usr/bin/env bats
# scripts/resolve-refs.sh against a synthetic git repository with backdated
# commits: time windows, shallow clones, detached HEAD, tags, merge queues,
# pull requests (merge-base), pushes and path expansion.

load test_helper

# Repository layout (dates relative to now):
#   root (30d)  c1 (20d)  c2 (10d)  c3 (2d)   <- main, tag v1.0.0 on c3
#                 \-- f1 (5d)                 <- feature
commit_days_ago() { # commit_days_ago DAYS FILE MESSAGE
  local ts
  ts=$(($(date +%s) - $1 * 86400))
  mkdir -p "$REPO/$(dirname "$2")"
  printf 'content %s\n' "$RANDOM" >"$REPO/$2"
  git -C "$REPO" add -A
  GIT_AUTHOR_DATE="$ts +0000" GIT_COMMITTER_DATE="$ts +0000" git -C "$REPO" commit -q -m "$3"
  git -C "$REPO" rev-parse HEAD
}

make_repo() {
  REPO="$BATS_TEST_TMPDIR/repo"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  git init -q "$REPO"
  git -C "$REPO" checkout -q -b main
  git -C "$REPO" config user.email "t@example.com"
  git -C "$REPO" config user.name "t"
  ROOT_SHA=$(commit_days_ago 30 README.md root)
  C1=$(commit_days_ago 20 contracts/Vault.sol c1)
  git -C "$REPO" checkout -q -b feature
  F1=$(commit_days_ago 5 contracts/Feature.sol f1)
  git -C "$REPO" checkout -q main
  C2=$(commit_days_ago 10 src/crypto/sign.rs c2)
  C3=$(commit_days_ago 2 test/mocks/Mock.sol c3)
  git -C "$REPO" tag v1.0.0
  git clone -q --bare "$REPO" "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  export REPO ORIGIN ROOT_SHA C1 C2 C3 F1
}

setup() {
  new_work
  make_repo
  export GITHUB_WORKSPACE="$REPO"
  export GITHUB_REPOSITORY="acme/vault"
  export GITHUB_SERVER_URL="https://github.com"
}

# event NAME [jq-object-of-extra-fields] - writes event.json directly. The
# second argument is a jq object expression merged over the defaults.
event() {
  local name="$1" extra="${2:-}"
  # bash 3.2 keeps the backslash in "${2:-{\}}", so build the default here
  [ -n "$extra" ] || extra='{}'
  jq -n --arg name "$name" --arg sha "$(git -C "$REPO" rev-parse HEAD)" \
    '{eventName: $name, repository: "acme/vault", serverUrl: "https://github.com", sha: $sha, ref: "refs/heads/main",
      refName: "main", refType: "branch", pr: null, mergeGroup: null, push: null, release: null, commentPrNumber: null, isFork: false} + ('"$extra"')' >"$V12_WORK_DIR/event.json"
}

refs() { jq -r "$1" "$V12_WORK_DIR/refs.json"; }

@test "schedule + since resolves the window from git history" {
  make_config V12_INPUT_SINCE="7 days ago"
  event schedule
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .mode)" = "diff" ]
  [ "$(refs .fromSha)" = "$C2" ]
  [ "$(refs .toSha)" = "$C3" ]
  [ "$(refs .changedFiles)" = "1" ]
  [ "$(refs .since.fallbackToRoot)" = "false" ]
  [ "$(output_value audit-kind)" = "diff" ]
  [ "$(output_value commit-range)" = "${C2:0:7}..${C3:0:7}" ]
  [[ "$output" == *"Window: since '7 days ago'"* ]]
}

@test "exclude globs can turn a window into an empty diff" {
  make_config V12_INPUT_SINCE="7 days ago" V12_INPUT_EXCLUDE_PATHS='**/test/**'
  event schedule
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(output_value skipped)" = "true" ]
  [ "$(output_value skipped-reason)" = "empty-diff" ]
  [[ "$output" == *"none match the configured paths"* ]]
}

@test "a window with no new commits is skipped as empty" {
  make_config V12_INPUT_SINCE="1 hour ago"
  event schedule
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(output_value skipped-reason)" = "empty-diff" ]
  [[ "$output" == *"resolves to a single commit"* ]]
}

@test "a window predating the repository falls back to the root commit with a warning" {
  make_config V12_INPUT_SINCE="2 years ago"
  event schedule
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .fromSha)" = "$ROOT_SHA" ]
  [ "$(refs .since.fallbackToRoot)" = "true" ]
  [[ "$output" == *"::warning::The window 'since: 2 years ago' predates the first commit"* ]]
}

@test "garbage since expressions are rejected instead of silently meaning now" {
  make_config V12_INPUT_SINCE="not a real date"
  event schedule
  run_script resolve-refs
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a date expression git understands"* ]]
}

@test "shallow clones are unshallowed with a warning" {
  SHALLOW="$BATS_TEST_TMPDIR/shallow"
  git clone -q --depth 1 "file://$ORIGIN" "$SHALLOW"
  export GITHUB_WORKSPACE="$SHALLOW"
  make_config V12_INPUT_SINCE="7 days ago"
  event schedule
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::The checkout is shallow"* ]]
  [[ "$output" == *"fetch-depth: 0"* ]]
  [ "$(refs .fromSha)" = "$C2" ]
  [ "$(refs .shallow.was)" = "true" ]
  [ "$(refs .shallow.unshallowed)" = "true" ]
}

@test "a shallow clone that cannot be unshallowed fails clearly for time windows" {
  SHALLOW="$BATS_TEST_TMPDIR/shallow"
  git clone -q --depth 1 "file://$ORIGIN" "$SHALLOW"
  git -C "$SHALLOW" remote set-url origin "file:///nonexistent/origin.git"
  export GITHUB_WORKSPACE="$SHALLOW"
  make_config V12_INPUT_SINCE="7 days ago"
  event schedule
  run_script resolve-refs
  [ "$status" -eq 1 ]
  [[ "$output" == *"Cannot resolve 'since: 7 days ago' on a shallow clone"* ]]
}

@test "tag pushes are full audits of the tagged commit" {
  make_config
  event push "{refName: \"v1.0.0\", refType: \"tag\", ref: \"refs/tags/v1.0.0\"}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .mode)" = "full" ]
  [ "$(refs .branch)" = "v1.0.0" ]
  [ "$(refs .sha)" = "$C3" ]
  [ "$(refs .runName)" = "Full audit v1.0.0 @ ${C3:0:7}" ]
  [ "$(output_value commit-range)" = "${C3:0:7}" ]
}

@test "release events name the run after the tag" {
  make_config
  event release "{refName: \"v1.0.0\", refType: \"tag\", release: {tagName: \"v1.0.0\"}}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .runName)" = "Release v1.0.0" ]
}

@test "detached HEAD full audit uses the event ref name and sha" {
  git -C "$REPO" checkout -q "$C2"
  make_config
  event workflow_dispatch "{refName: \"main\", sha: \"$C2\"}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .kind)" = "full" ]
  [ "$(refs .sha)" = "$C2" ]
  [ "$(refs .branch)" = "main" ]
}

@test "full audit without any branch information fails with guidance" {
  git -C "$REPO" checkout -q "$C2"
  make_config
  event workflow_dispatch "{refName: \"\", sha: \"$C2\"}"
  run_script resolve-refs
  [ "$status" -eq 1 ]
  [[ "$output" == *"set the 'branch' input"* ]]
}

@test "pull requests review from the merge base, not the base branch tip" {
  make_config
  event pull_request "{pr: {number: 12, url: \"u\", title: \"t\", draft: false, headSha: \"$F1\", baseSha: \"$C3\", headRef: \"feature\", baseRef: \"main\", headRepo: \"acme/vault\", baseRepo: \"acme/vault\", isFork: false}, commentPrNumber: 12}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .mode)" = "pr" ]
  [ "$(refs .fromSha)" = "$C1" ]
  [ "$(refs .toSha)" = "$F1" ]
  [ "$(refs .blobSha)" = "$F1" ]
  [ "$(refs .mergeBaseNote)" = "null" ]
  [ "$(refs '.changedFiles')" = "1" ]
  [ "$(jq -r '.all[0]' "$V12_WORK_DIR/changed-files.json")" = "contracts/Feature.sol" ]
  [ "$(refs .runName)" = "PR #12 t" ]
}

@test "pull request on a shallow checkout still finds the merge base after unshallowing" {
  SHALLOW="$BATS_TEST_TMPDIR/shallow"
  git clone -q --depth 1 "file://$ORIGIN" "$SHALLOW"
  export GITHUB_WORKSPACE="$SHALLOW"
  make_config
  event pull_request "{pr: {number: 12, url: \"u\", title: \"t\", draft: false, headSha: \"$F1\", baseSha: \"$C3\", headRef: \"feature\", baseRef: \"main\", headRepo: \"acme/vault\", baseRepo: \"acme/vault\", isFork: false}, commentPrNumber: 12}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .fromSha)" = "$C1" ]
}

@test "pull request without a usable checkout falls back to the base tip with a warning" {
  export GITHUB_WORKSPACE="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$GITHUB_WORKSPACE"
  make_config
  event pull_request "{pr: {number: 12, url: \"u\", title: \"t\", draft: false, headSha: \"$F1\", baseSha: \"$C3\", headRef: \"feature\", baseRef: \"main\", headRepo: \"acme/vault\", baseRepo: \"acme/vault\", isFork: false}, commentPrNumber: 12}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .fromSha)" = "$C3" ]
  [[ "$output" == *"::warning::Could not compute the merge base"* ]]
  [ "$(refs .changedFilesKnown)" = "false" ]
}

@test "merge_group reviews the queue's base..head" {
  make_config
  event merge_group "{mergeGroup: {headSha: \"$C3\", baseSha: \"$C1\", headRef: \"refs/heads/gh-readonly-queue/main/pr-12-abc\", baseRef: \"refs/heads/main\"}}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .mode)" = "pr" ]
  [ "$(refs .fromSha)" = "$C1" ]
  [ "$(refs .toSha)" = "$C3" ]
  [[ "$(refs .runName)" == "Merge queue gh-readonly-queue/main/pr-12-abc"* ]]
}

@test "pushes review before..after and skip new branches" {
  make_config
  event push "{push: {before: \"$C2\", after: \"$C3\", created: false, deleted: false}}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .mode)" = "diff" ]
  [ "$(refs .fromSha)" = "$C2" ]
  [ "$(refs .toSha)" = "$C3" ]
  new_work
  make_config
  event push "{push: {before: \"0000000000000000000000000000000000000000\", after: \"$C3\", created: true, deleted: false}}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(output_value skipped-reason)" = "no-previous-commit" ]
}

@test "explicit base-ref and head-ref win" {
  make_config V12_INPUT_BASE_REF="$C1" V12_INPUT_HEAD_REF="feature"
  event workflow_dispatch
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .fromSha)" = "$C1" ]
  [ "$(refs .toSha)" = "$F1" ]
}

@test "mode pr outside a pull request context is an error" {
  make_config V12_INPUT_MODE=pr
  event schedule
  run_script resolve-refs
  [ "$status" -eq 1 ]
  [[ "$output" == *"mode 'pr' needs a pull_request"* ]]
}

@test "schedule without since is a full audit" {
  make_config
  event schedule
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .kind)" = "full" ]
  [ "$(refs .sha)" = "$C3" ]
}

@test "include globs become V12 path prefixes or are expanded against the tree" {
  make_config V12_INPUT_PATHS=$'contracts/**\n**/*.rs'
  event schedule
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs '.apiPaths | join(",")')" = "contracts/,src/crypto/sign.rs" ]
  [[ "$output" == *"Paths sent to V12: contracts/, src/crypto/sign.rs"* ]]
}

@test "wildcard paths matching nothing skip the run" {
  make_config V12_INPUT_PATHS='**/*.go'
  event schedule
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(output_value skipped-reason)" = "no-matching-paths" ]
}

@test "a merge commit inside the window is handled like any other" {
  git -C "$REPO" merge -q --no-ff -m "merge feature" feature
  M=$(git -C "$REPO" rev-parse HEAD)
  make_config V12_INPUT_SINCE="7 days ago"
  event schedule "{sha: \"$M\"}"
  run_script resolve-refs
  [ "$status" -eq 0 ]
  [ "$(refs .toSha)" = "$M" ]
  [ "$(refs .fromSha)" = "$C2" ]
  jq -e '.all | index("contracts/Feature.sol") != null' "$V12_WORK_DIR/changed-files.json"
}
