#!/usr/bin/env bash
# scripts/config.sh - builds the effective configuration.
#
# Layers, lowest to highest: built-in defaults, the repository config file
# (.github/v12-audit.yml by default, validated), then action inputs. An input
# wins only when it is non-empty, which is why config-overridable inputs have
# an empty default in action.yml.
#
# Env in:  V12_WORK_DIR, V12_INPUT_* (all inputs), GITHUB_WORKSPACE, GITHUB_REPOSITORY
# Files:   $V12_WORK_DIR/config.json (never contains secrets)
# Outputs: config-file-loaded

set -o errexit -o nounset -o pipefail
# shellcheck source=scripts/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
: "${V12_WORK_DIR:?V12_WORK_DIR must be set (run preflight.sh first)}"

workspace="${GITHUB_WORKSPACE:-$PWD}"
config_input="${V12_INPUT_CONFIG_FILE:-}"
config_rel="${config_input:-.github/v12-audit.yml}"
case "$config_rel" in
  /*) config_path="$config_rel" ;;
  *) config_path="${workspace%/}/${config_rel}" ;;
esac

raw_json="$(work_file config-file.json)"
loaded="false"

# yaml_to_json IN OUT - converts with whichever YAML tool the runner has.
yaml_to_json() {
  local in="$1" out="$2" yqv=""
  if command -v yq >/dev/null 2>&1; then
    yqv=$(yq --version 2>&1 || true)
    case "$yqv" in
      *mikefarah* | *"version v4"* | *"version 4"*)
        yq -o=json -I=0 '.' "$in" >"$out"
        return 0
        ;;
    esac
  fi
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "$in" "$out" <<'PY'
import json, sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    data = yaml.safe_load(f)
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(data, f, default=str)
PY
    return 0
  fi
  if [ -n "$yqv" ]; then
    # kislyuk/yq (Python) prints JSON with a jq filter.
    yq '.' "$in" >"$out"
    return 0
  fi
  return 1
}

if [ -f "$config_path" ]; then
  if ! yaml_to_json "$config_path" "$raw_json"; then
    die "Cannot parse ${config_rel}: no YAML parser found. v12-action reads its config file with yq (https://github.com/mikefarah/yq, preinstalled on GitHub-hosted runners) or python3 with PyYAML. Install one of them on this runner, or remove the config file and use action inputs."
  fi
  if ! jq -e 'type == "object" or . == null' "$raw_json" >/dev/null 2>&1; then
    die "Invalid config file ${config_rel}: the top level must be a YAML mapping (keys: defaults, paths, context-documents, suppressions, notifications)."
  fi
  if jq -e '. == null' "$raw_json" >/dev/null 2>&1; then
    printf '{}\n' >"$raw_json"
  fi
  loaded="true"
  log_info "Loaded config file ${config_rel}"
else
  if [ -n "$config_input" ]; then
    die "config-file '${config_rel}' was set explicitly but does not exist in the checkout (${workspace})."
  fi
  printf '{}\n' >"$raw_json"
fi

merged="$(work_file config-merge.json)"
jqx -n \
  --slurpfile file "$raw_json" \
  --arg loaded "$loaded" \
  --arg configFile "$config_rel" \
  --arg repository "${GITHUB_REPOSITORY:-}" \
  --arg today "$(date -u +%Y-%m-%d)" \
  'include "config"; build($file[0]; $loaded == "true"; $configFile; $repository; $today)' >"$merged"

if [ "$(jq -r '.errors | length' "$merged")" != "0" ]; then
  log_info "Invalid v12-action configuration (${config_rel} and/or action inputs):"
  jq -r '.errors[] | "  - " + .' "$merged"
  die "Invalid v12-action configuration: $(jq -r '.errors | join("; ")' "$merged"). Schema: https://raw.githubusercontent.com/metarsit/v12-action/v1/schema/v12-audit.schema.json"
fi

jq '.config' "$merged" >"$(work_file config.json)"
set_output config-file-loaded "$loaded"
log_debug "effective config: $(jq -c . "$(work_file config.json)")"
