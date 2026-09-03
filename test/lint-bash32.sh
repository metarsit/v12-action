#!/usr/bin/env bash
# test/lint-bash32.sh - rejects bash 4+ features and known footguns in the
# scripts that must run on macOS's bash 3.2. Exit 1 on any hit.
#
# Usage: test/lint-bash32.sh [FILE...]   (defaults to scripts/*.sh)

set -o errexit -o nounset -o pipefail

if [ "$#" -eq 0 ]; then
  set -- scripts/*.sh
fi

status=0
files=("$@")
# Lines are checked with comments stripped; a line carrying the marker
# "bash32-lint: allow" is skipped (used for the sha256sum fallback in lib.sh).
run_check() {
  local regex="$1" msg="$2" f hits
  for f in "${files[@]}"; do
    hits=$(sed -e '/bash32-lint: allow/s/.*//' -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#[^"'"'"']*$//' "$f" | grep -nE -- "$regex" || true)
    if [ -n "$hits" ]; then
      printf 'bash 3.2 lint: %s\n%s\n\n' "$msg" "$(printf '%s\n' "$hits" | sed "s#^#$f:#")"
      status=1
    fi
  done
}

run_check 'declare -[a-zA-Z]*[Ag]' 'declare -A / -g need bash 4'
run_check 'local -[a-zA-Z]*A' 'associative arrays need bash 4'
run_check '\b(mapfile|readarray)\b' 'mapfile/readarray need bash 4'
run_check '\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^|,|\^)\}' '${var,,} / ${var^^} case conversion needs bash 4'
run_check '\|&' '|& needs bash 4'
run_check '&>>' '&>> needs bash 4'
run_check '\bcoproc\b' 'coproc needs bash 4'
run_check ';;&' ';;& needs bash 4'
run_check '\$\{[A-Za-z_][A-Za-z0-9_]*@[QEPAa]\}' '${var@Q} transformations need bash 4.4'
run_check '\b(EPOCHSECONDS|EPOCHREALTIME|BASHPID)\b' 'EPOCHSECONDS/EPOCHREALTIME/BASHPID need bash 4+/5'
run_check 'printf .*%\(' 'printf %(...)T needs bash 4.2'
run_check '\bread -[a-zA-Z]*N' 'read -N needs bash 4.1'
run_check '\bwait -n\b' 'wait -n needs bash 4.3'
run_check 'shopt -s globstar' 'globstar needs bash 4'
run_check '\[\[ -v ' '[[ -v var ]] needs bash 4.2'
run_check '\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]+\]\}' 'negative array indexes need bash 4.3'
run_check '\blocal [A-Za-z_][A-Za-z0-9_]*=\$\(' 'local x=$(cmd) hides the command failure under set -e; declare then assign'
run_check '\b(sed -i|grep -P|date -d |readlink -f|stat -c|base64 -w|xargs -r|sort -V|find [^|]* -printf)\b' 'GNU-only tool flag; macOS ships BSD userland'
run_check '\bsha256sum\b' 'sha256sum is not on macOS; use sha256_hex from lib.sh'

if [ "$status" -eq 0 ]; then
  printf 'bash 3.2 lint: OK (%s file(s))\n' "${#files[@]}"
fi
exit "$status"
