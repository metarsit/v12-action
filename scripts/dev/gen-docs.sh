#!/usr/bin/env bash
# scripts/dev/gen-docs.sh - keeps the Markdown docs in sync with the sources
# of truth. Developer tooling, not part of the action.
#
#   gen-docs.sh --write   refresh the generated sections in place
#   gen-docs.sh --check   exit 1 when a generated section is out of date (CI)
#
# Generated sections, delimited by HTML comment markers:
#   <!-- inputs:start --> / <!-- inputs:end -->     input table from action.yml
#   <!-- outputs:start --> / <!-- outputs:end -->   output table from action.yml
#   <!-- example:NAME:start --> / :end             examples/NAME in a yaml fence
# Files processed: README.md and docs/for-agents/SETUP.md. Needs yq (mikefarah v4).

set -o errexit -o nounset -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
mode="${1:---check}"

esc() { sed -e 's/|/\\|/g' -e 's/\r//g' | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/ $//'; }

inputs_table() {
  printf '| Input | Description | Required | Default |\n|---|---|---|---|\n'
  local name desc req def
  for name in $(yq '.inputs | keys | .[]' action.yml); do
    desc=$(yq ".inputs.\"$name\".description" action.yml | esc)
    req=$(yq ".inputs.\"$name\".required // false" action.yml)
    def=$(yq ".inputs.\"$name\".default // \"\"" action.yml | esc)
    if [ -n "$def" ]; then
      def="\`$def\`"
    fi
    printf '| `%s` | %s | %s | %s |\n' "$name" "$desc" "$req" "$def"
  done
}

outputs_table() {
  printf '| Output | Description |\n|---|---|\n'
  local name desc
  for name in $(yq '.outputs | keys | .[]' action.yml); do
    desc=$(yq ".outputs.\"$name\".description" action.yml | esc)
    printf '| `%s` | %s |\n' "$name" "$desc"
  done
}

render() {
  # render FILE - prints FILE with every generated section refreshed.
  awk -v inputs="$(inputs_table)" -v outputs="$(outputs_table)" -v root="$ROOT" '
    /<!-- inputs:start -->/ { print; print ""; print inputs; print ""; skip = 1; next }
    /<!-- outputs:start -->/ { print; print ""; print outputs; print ""; skip = 1; next }
    /<!-- example:[A-Za-z0-9._-]+:start -->/ {
      print
      name = $0
      sub(/.*<!-- example:/, "", name)
      sub(/:start -->.*/, "", name)
      print ""
      print "```yaml"
      file = root "/examples/" name
      while ((getline line < file) > 0) print line
      close(file)
      print "```"
      print ""
      skip = 1
      next
    }
    /<!-- (inputs|outputs|example:[A-Za-z0-9._-]+):end -->/ { skip = 0 }
    skip != 1 { print }
  ' "$1"
}

grep -q '<!-- inputs:start -->' README.md || {
  echo "README.md lacks the <!-- inputs:start --> marker"
  exit 1
}
status=0
for doc in README.md docs/for-agents/SETUP.md; do
  [ -f "$doc" ] || continue
  tmp="$(mktemp "${TMPDIR:-/tmp}/doc.XXXXXX")"
  render "$doc" >"$tmp"
  case "$mode" in
    --write)
      mv "$tmp" "$doc"
      echo "$doc: generated sections refreshed"
      ;;
    --check)
      if diff -u "$doc" "$tmp" >/dev/null; then
        echo "$doc: generated sections are current"
      else
        diff -u "$doc" "$tmp" || true
        echo "$doc: generated sections are out of date; run 'make docs'"
        status=1
      fi
      rm -f "$tmp"
      ;;
    *)
      rm -f "$tmp"
      echo "usage: $0 --write | --check"
      exit 2
      ;;
  esac
done
exit "$status"
