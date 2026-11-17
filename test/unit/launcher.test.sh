#!/usr/bin/env bash
# Tests for the attached-mode launcher, run inside the image:
#   bash test/unit/launcher.test.sh [image]
# The launcher listens on a unix socket and starts a program as the account
# that connected (the kernel reports it; the request carries only a display).
# A stub program stands in for JupyterLab Desktop, so no X server is needed.
# shellcheck disable=SC1091,SC2015,SC2016  # pass() never fails; single-quoted scripts expand inside the container
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
IMG=${1:-localhost/rdp-jupyter:dev}

# Runs one scenario in a fresh container. Sets up accounts alice (1000) and
# bob (1001), gives alice a cookie for display :10 only, starts the launcher
# with a stub that records who ran it, then runs the scenario.
#   ask <account> <request line>  prints the launcher's reply
scenario() {
  podman run --rm --entrypoint bash "$IMG" -c '
    printf "alice:a\nbob:b\n" >/tmp/u; /opt/rdp-jupyter/accounts.sh /tmp/u >/dev/null || exit 90
    su alice -c "xauth -f ~/.Xauthority add :10 . 00112233445566778899aabbccddeeff" 2>/dev/null || exit 91
    install -d -m 1777 /tmp/rec
    printf "%s\n" "#!/bin/sh" "{ id -un; echo \$DISPLAY; echo \$HOME; echo \$XAUTHORITY; pwd; } > /tmp/rec/\$(id -un)" > /tmp/stub
    chmod 755 /tmp/stub
    install -d /run/t
    /opt/rdp-jupyter/launcher.pl /run/t/app.sock /tmp/stub >/tmp/launcher.log 2>&1 &
    for _ in $(seq 50); do [ -S /run/t/app.sock ] && break; sleep 0.1; done
    [ -S /run/t/app.sock ] || { cat /tmp/launcher.log >&2; exit 92; }
    ask() {
      su "$1" -s /bin/sh -c "perl -MIO::Socket::UNIX -e '\''
        \$s = IO::Socket::UNIX->new(Peer => \"/run/t/app.sock\") or die \"connect: \$!\";
        print \$s \$ARGV[0], \"\\n\"; print scalar <\$s>;'\'' -- \"\$0\"" "$2"
    }
    settle() { for _ in $(seq 30); do [ -e "/tmp/rec/$1" ] && return 0; sleep 0.1; done; return 1; }
    '"$1"
}

say runs-as-caller
scenario 'r=$(ask alice :10); [ "$r" = OK ] || { echo "reply: $r" >&2; exit 2; }
          settle alice || exit 3
          [ "$(cat /tmp/rec/alice)" = "$(printf "alice\n:10\n/home/alice\n/home/alice/.Xauthority\n/home/alice")" ] || { cat /tmp/rec/alice >&2; exit 4; }' \
  && pass "program runs as the connecting account, on the requested display" || bad "runs-as-caller (rc=$?)"

say program-can-start-dbus
# startwm.sh starts a session bus with dbus-launch. Under a launcher that
# hands its own signal setup to the program, dbus-launch prints nothing.
scenario 'printf "%s\n" "#!/bin/bash" "dbus-launch --sh-syntax > /tmp/rec/dbus 2>/tmp/rec/dbus.err; id -un > /tmp/rec/\$(id -un)" > /tmp/stub
          r=$(ask alice :10); [ "$r" = OK ] || exit 2
          settle alice || exit 3
          grep -q "^DBUS_SESSION_BUS_PID=" /tmp/rec/dbus || { echo "dbus-launch said: [$(cat /tmp/rec/dbus)] [$(cat /tmp/rec/dbus.err)]" >&2; exit 4; }' \
  && pass "the program can start a session bus" || bad "program-can-start-dbus (rc=$?)"

say socket-open-to-accounts
scenario '[ "$(stat -c %a /run/t/app.sock)" = 666 ]' \
  && pass "any account in the pod may connect (socket is 0666)" || bad "socket mode (rc=$?)"

say no-cookie-no-launch
# bob has no cookie for alice's display :10: refuse instead of starting a
# program that would die at once, so the button can show a real error
scenario 'r=$(ask bob :10); case $r in ERR*) ;; *) echo "reply: $r" >&2; exit 2 ;; esac
          sleep 1; [ ! -e /tmp/rec/bob ] || exit 3' \
  && pass "refuses a display the account has no cookie for" || bad "no-cookie-no-launch (rc=$?)"

say bad-request
scenario 'for req in ":10; id" "10" ":abc" "" ":10 x"; do
            r=$(ask alice "$req"); case $r in ERR*) ;; *) echo "request [$req] reply: $r" >&2; exit 2 ;; esac
          done
          sleep 1; [ ! -e /tmp/rec/alice ] || exit 3' \
  && pass "refuses anything that is not a display like :10" || bad "bad-request (rc=$?)"

say system-account
# Accounts below UID 1000 (daemons, nobody is 65534 but has no home) never get a program
scenario 'r=$(ask daemon :10); case $r in ERR*) ;; *) echo "reply: $r" >&2; exit 2 ;; esac
          r=$(ask nobody :10); case $r in ERR*) ;; *) echo "reply: $r" >&2; exit 3 ;; esac' \
  && pass "refuses system accounts" || bad "system-account (rc=$?)"

say survives-clients
# A client that connects and says nothing must not block the next one
scenario 'su bob -s /bin/sh -c "perl -MIO::Socket::UNIX -e '\''\$s = IO::Socket::UNIX->new(Peer => \"/run/t/app.sock\"); sleep 30'\''" &
          sleep 0.5
          r=$(timeout 10 bash -c "$(declare -f ask); ask alice :10"); [ "$r" = OK ] || { echo "reply: $r" >&2; exit 2; }' \
  && pass "a silent client does not block others" || bad "survives-clients (rc=$?)"

finish
