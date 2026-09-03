#!/usr/bin/env bash
# test/lint-inputs.sh - drift check between action.yml and the scripts:
#   - every input declared in action.yml is consumed (as V12_INPUT_<NAME>
#     read by a script, or as inputs.<name> used by a step)
#   - every V12_INPUT_<NAME> a script reads is declared in action.yml
#   - every action-provided V12_* variable a script reads is set in action.yml
# Needs yq (mikefarah v4). Exit 1 on drift.

set -o errexit -o nounset -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
status=0
fail() {
  printf 'inputs lint: %s\n' "$1"
  status=1
}

upper() { printf '%s' "$1" | tr 'a-z-' 'A-Z_'; }

# Names scripts read: literal V12_INPUT_X plus config.jq's input("X") calls.
read_names=$( (
  grep -rhoE 'V12_INPUT_[A-Z0-9_]+' scripts/ || true
  grep -hoE '(input|has_input|pick|pick_list)\("[A-Z0-9_]+"' scripts/jq/config.jq | sed -E 's/.*\("//; s/"$//' | sed 's/^/V12_INPUT_/'
) | sort -u)

for input in $(yq '.inputs | keys | .[]' action.yml); do
  env_name="V12_INPUT_$(upper "$input")"
  consumed=false
  if printf '%s\n' "$read_names" | grep -qx "$env_name"; then
    consumed=true
  elif grep -E "inputs\.${input}([^a-z-]|$)" action.yml | grep -vq "${env_name}:"; then
    consumed=true
  fi
  [ "$consumed" = true ] || fail "input '$input' is declared in action.yml but never consumed (expected $env_name in a script, or inputs.$input in a step)"
  if printf '%s\n' "$read_names" | grep -qx "$env_name" && ! grep -q "^ *${env_name}: " action.yml; then
    fail "input '$input' is read as $env_name by a script but action.yml never sets it in env:"
  fi
done

for name in $read_names; do
  input=$(printf '%s' "${name#V12_INPUT_}" | tr 'A-Z_' 'a-z-')
  if [ "$(yq ".inputs | has(\"$input\")" action.yml)" != "true" ]; then
    fail "scripts read $name but action.yml declares no input '$input'"
  fi
  if ! grep -q "^ *${name}: " action.yml; then
    fail "scripts read $name but action.yml never sets it in env:"
  fi
done

# Action-provided variables (not inputs) the scripts rely on.
for name in V12_TOKEN V12_API_URL V12_WORK_DIR V12_ACTION_PATH V12_ACTION_VERSION V12_PRIOR_STATE V12_SLACK_WEBHOOK V12_SLACK_BOT_TOKEN V12_SLACK_TS V12_SLACK_CHANNEL V12_SURFACE_COMMENT V12_SURFACE_CHECK V12_SURFACE_SARIF V12_SURFACE_SLACK; do
  if grep -rq "\${${name}[:?}-]" scripts/ && ! grep -q "${name}" action.yml; then
    fail "scripts read $name but action.yml never provides it"
  fi
done

if [ "$status" -eq 0 ]; then
  printf 'inputs lint: OK (%s inputs, %s env names)\n' "$(yq '.inputs | length' action.yml)" "$(printf '%s\n' "$read_names" | grep -c .)"
fi
exit "$status"
