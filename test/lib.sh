# shellcheck shell=bash
# Minimal test helpers: source this file, call pass/bad/say, end with finish.
_fails=0
_passes=0
say()    { printf '\n== %s\n' "$*"; }
pass()   { _passes=$((_passes + 1)); printf 'PASS %s\n' "$*"; }
bad()    { _fails=$((_fails + 1)); printf 'FAIL %s\n' "$*"; }
finish() {
  printf '\n%d passed, %d failed\n' "$_passes" "$_fails"
  [ "$_fails" -eq 0 ] || exit 1
}
