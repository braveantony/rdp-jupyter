#!/usr/bin/env bash
# Tests for accounts.sh, run inside the image: bash test/unit/accounts.test.sh [image]
# shellcheck disable=SC1091,SC2015,SC2016  # pass() never fails; single-quoted scripts expand inside the container
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
IMG=${1:-localhost/rdp-jupyter:dev}
VOL=rdp-jupyter-test-home
trap 'podman volume rm -f "$VOL" >/dev/null 2>&1' EXIT

# Shell helpers available inside each container run
HELPERS='
pw_ok() {  # pw_ok <user> <password>: the shadow hash matches <password>
  h=$(getent shadow "$1" | cut -d: -f2)
  case $h in "\$6\$"*) ;; *) echo "hash is not SHA-512: $h" >&2; return 1 ;; esac
  salt=$(printf %s "$h" | cut -d\$ -f3)
  [ "$(openssl passwd -6 -salt "$salt" "$2")" = "$h" ]
}
'
in_image() { podman run --rm "$@"; }
run() { in_image --entrypoint bash "$IMG" -c "$HELPERS $1"; }

say default-bigred
run 'RDP_PASSWORD=bigred /opt/rdp-jupyter/accounts.sh /nonexistent >/tmp/o || exit 9
     [ "$(cat /tmp/o)" = bigred ] || exit 2
     [ "$(id -u bigred)" = 1000 ] || exit 3
     [ -f /home/bigred/.bashrc ] || exit 4
     pw_ok bigred bigred || exit 5
     ! pw_ok bigred wrong || exit 6' \
  && pass default-bigred || bad "default-bigred (rc=$?)"

say home-private
run 'printf "alice:a1\nbob:b2\n" >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null || exit 9
     [ "$(stat -c %a /home/alice)" = 700 ] || exit 2
     su bob -c "ls /home/alice" >/dev/null 2>&1 && exit 3
     id -nG bob | grep -qw sudo && exit 4
     command -v sudo >/dev/null && exit 5
     exit 0' \
  && pass home-private || bad "home-private (rc=$?)"

say users-file
run 'printf "# comment\n\nalice:a1\nbob:b:2\n" >/tmp/u; out=$(/opt/rdp-jupyter/accounts.sh /tmp/u) || exit 9
     [ "$out" = "alice bob" ] || exit 2
     [ "$(id -u alice)" = 1000 ] && [ "$(id -u bob)" = 1001 ] || exit 3
     pw_ok bob "b:2" || exit 4
     ! pw_ok bob b || exit 5' \
  && pass users-file || bad "users-file (rc=$?)"

say reject
for content in 'root:x' 'Bad:x' 'alice:' 'alice:a\nalice:b' 'daemon:x' 'xrdp:x'; do
  run "printf '$content\n' >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null 2>/tmp/e; rc=\$?; [ \$rc = 1 ] && grep -q '^\[entrypoint\]' /tmp/e" \
    && pass "reject '$content'" || bad "reject '$content' was accepted or wrong error"
done
run 'unset RDP_PASSWORD; /opt/rdp-jupyter/accounts.sh /nonexistent >/dev/null 2>&1; [ $? = 1 ]' \
  && pass "reject no users file and no RDP_PASSWORD" || bad "missing RDP_PASSWORD accepted"

say keep-home
run 'mkdir -p /home/alice; echo keep >/home/alice/marker; printf "alice:a1\n" >/tmp/u
     /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null || exit 9
     [ "$(cat /home/alice/marker)" = keep ] || exit 2
     [ ! -e /home/alice/.bashrc ] || exit 3' \
  && pass keep-home || bad "keep-home (rc=$?)"

say uid-reorder
podman volume rm -f "$VOL" >/dev/null 2>&1; podman volume create "$VOL" >/dev/null
in_image -v "$VOL:/home" --entrypoint bash "$IMG" -c \
  'printf "alice:a\nbob:b\n" >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null && su alice -c "touch /home/alice/f"' \
  || bad "uid-reorder: first container failed"
in_image -v "$VOL:/home" --entrypoint bash "$IMG" -c \
  'printf "bob:b\nalice:a\n" >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null || exit 9
   [ "$(id -u bob)" = 1000 ] && [ "$(id -u alice)" = 1001 ] || exit 2
   [ "$(stat -c %u /home/alice)" = 1001 ] && [ "$(stat -c %u /home/alice/f)" = 1001 ] || exit 3
   [ "$(stat -c %u /home/bob)" = 1000 ] || exit 4' \
  && pass uid-reorder || bad "uid-reorder (rc=$?)"

say removed-account-home
podman volume rm -f "$VOL" >/dev/null 2>&1; podman volume create "$VOL" >/dev/null
in_image -v "$VOL:/home" --entrypoint bash "$IMG" -c \
  'printf "alice:a\nbob:b\n" >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null && su alice -c "touch /home/alice/secret"' \
  || bad "removed-account-home: first container failed"
in_image -v "$VOL:/home" --entrypoint bash "$IMG" -c \
  'printf "bob:b\n" >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null || exit 9
   [ "$(id -u bob)" = 1000 ] || exit 2
   su bob -c "ls /home/alice" >/dev/null 2>&1 && exit 3
   [ "$(stat -c %u:%a /home/alice)" = 0:700 ] || exit 4
   [ -e /home/alice/secret ] || exit 5' \
  && pass "removed account's home is locked to root" || bad "removed-account-home (rc=$?)"

say crlf-users-file
run 'printf "alice:a1\r\nbob:b2\r\n" >/tmp/u; out=$(/opt/rdp-jupyter/accounts.sh /tmp/u) || exit 9
     [ "$out" = "alice bob" ] || exit 2
     pw_ok alice a1 || exit 3
     pw_ok bob b2 || exit 4' \
  && pass "CRLF users file" || bad "crlf-users-file (rc=$?)"

finish
