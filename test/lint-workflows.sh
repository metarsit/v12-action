#!/usr/bin/env bash
# test/lint-workflows.sh - the security rules this repository enforces on
# its own action.yml, workflows and examples:
#   1. no `${{ }}` expression inside any `run:` body (command injection)
#   2. every third-party `uses:` pinned to a 40-hex commit SHA with a
#      version comment
#   3. examples reference metarsit/v12-action@v<major> from VERSION
#   4. every workflow job has permissions and timeout-minutes
# Needs yq (mikefarah v4). Exit 1 on any violation.

set -o errexit -o nounset -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
status=0
fail() {
  printf 'workflow lint: %s\n' "$1"
  status=1
}

major="v$(cut -d. -f1 <VERSION)"
files=(action.yml)
for f in .github/workflows/*.yml examples/*.yml; do
  [ -f "$f" ] && files+=("$f")
done

for f in "${files[@]}"; do
  # 1. expressions inside run: bodies (yq walks every "run" key)
  if yq '.. | select(type == "!!map" and has("run")) | .run' "$f" 2>/dev/null | grep -n '\${{' >/dev/null; then
    fail "$f: a run: body contains \${{ }} (pass values through env: instead):"
    yq '.. | select(type == "!!map" and has("run")) | .run' "$f" | grep -n '\${{' | sed 's/^/    /'
  fi

  # 2. uses: pinning (raw text so the version comment can be checked)
  while IFS= read -r line; do
    ref=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'"'"']//; s/["'"'"']$//')
    case "$ref" in
      ./* | docker://*) continue ;;
      metarsit/v12-action@*) continue ;;
      your-org/*) continue ;; # placeholder organization in the reusable-workflow example
    esac
    if ! printf '%s' "$ref" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@]+)?@[0-9a-f]{40}$'; then
      fail "$f: uses is not pinned to a 40-character commit SHA: $ref"
    fi
    if ! printf '%s' "$line" | grep -Eq '@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v?[0-9]'; then
      fail "$f: pinned uses lacks a version comment (e.g. # v4.2.2): $ref"
    fi
  done < <(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "$f" | sed -E 's/^[0-9]+://')
done

# 3. examples reference the current major tag
for f in examples/*.yml; do
  [ -f "$f" ] || continue
  if grep -q 'metarsit/v12-action@' "$f" && ! grep -q "metarsit/v12-action@${major}\b" "$f"; then
    fail "$f: must reference metarsit/v12-action@${major} (VERSION is $(cat VERSION))"
  fi
done

# 4. workflow hygiene: permissions and timeouts on every job
for f in .github/workflows/*.yml; do
  [ -f "$f" ] || continue
  top_perm=$(yq '.permissions // "" | tostring' "$f")
  for job in $(yq '.jobs | keys | .[]' "$f"); do
    if [ "$(yq ".jobs.\"$job\" | has(\"timeout-minutes\")" "$f")" != "true" ] && [ "$(yq ".jobs.\"$job\" | has(\"uses\")" "$f")" != "true" ]; then
      fail "$f: job '$job' has no timeout-minutes"
    fi
    if [ -z "$top_perm" ] && [ "$(yq ".jobs.\"$job\" | has(\"permissions\")" "$f")" != "true" ]; then
      fail "$f: job '$job' has no permissions block (and the workflow sets none)"
    fi
  done
done

if [ "$status" -eq 0 ]; then
  printf 'workflow lint: OK (%s file(s))\n' "${#files[@]}"
fi
exit "$status"
