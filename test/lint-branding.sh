#!/usr/bin/env bash
# test/lint-branding.sh - branding.icon must be a Feather icon GitHub accepts
# and branding.color one of the allowed names; an invalid value blocks
# Marketplace publishing. The icon list comes from GitHub's metadata-syntax
# documentation (test/fixtures/marketplace-icons.txt).

set -o errexit -o nounset -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
icon=$(yq '.branding.icon // ""' action.yml)
color=$(yq '.branding.color // ""' action.yml)
status=0
if ! grep -qx "$icon" test/fixtures/marketplace-icons.txt; then
  printf "branding lint: icon '%s' is not in the Marketplace icon list\n" "$icon"
  status=1
fi
case "$color" in
  white | black | yellow | blue | green | orange | red | purple | gray-dark) ;;
  *)
    printf "branding lint: color '%s' is not one of white, black, yellow, blue, green, orange, red, purple, gray-dark\n" "$color"
    status=1
    ;;
esac
[ "$status" -eq 0 ] && printf 'branding lint: OK (icon %s, color %s)\n' "$icon" "$color"
exit "$status"
