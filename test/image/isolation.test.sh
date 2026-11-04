#!/usr/bin/env bash
# Cross-account isolation tests against a local server container:
#   bash test/image/isolation.test.sh [image]
# Proves spec section 6's threat model: with two accounts (alice 1000, bob 1001)
# in one pod, alice cannot read bob's token, environ, files, kernel or ptrace
# bob's processes. bob logs in with the Task 10 RDP client and starts a kernel;
# every verification step below runs as alice. Each threat-model row is one
# pass/bad line. See test/image/fixtures/attack.py for the attacker itself.
# shellcheck disable=SC1091,SC2015,SC2016  # lib.sh is sourced; single-quoted wait_for conditions are eval'd later; pass/bad never fail
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
IMG=${1:-localhost/rdp-jupyter:dev}
CLIENT=localhost/rdp-jupyter-e2e-client:dev
PORT=33392
OUT=$PWD/test/e2e/out
FIX=$PWD/test/image/fixtures   # on the host
CFIX=/fixtures                 # where FIX is mounted in the container
ATTACK=$CFIX/attack.py
# Every container this run starts carries this prefix; the trap removes them all
P=rdpj-isolation-$$
SERVER=$P-server
VENV=/opt/jupyter/venv/bin/python
SERVER_RE='python[0-9.]* -m jupyterlab'
ALICE_UID=1000
BOB_UID=1001
# Paths inside the container, shared via the sticky /tmp (alice writes the
# verdict; root/bob write the token and stop files the poller reads).
TOKENFILE=/tmp/iso-token
STOPFILE=/tmp/iso-stop
VERDICT=/tmp/iso-verdict.json
PWNED=/tmp/pwned
PWNED_CONTROL=/tmp/pwned-control
USERS=$(mktemp)
printf 'alice:alicepw\nbob:bobpw\n' > "$USERS"
mkdir -p "$OUT"

cleanup() {
  podman ps -aq --filter "name=^$P-" | xargs -r podman rm -f -t 0 >/dev/null 2>&1
  rm -f "$USERS"
}
trap cleanup EXIT

# wait_for <seconds> <bash condition>: poll until the condition holds or the deadline passes
wait_for() {
  local end=$((SECONDS + $1))
  while :; do
    eval "$2" && return 0
    [ "$SECONDS" -ge "$end" ] && return 1
    sleep 1
  done
}

px() { podman exec "$SERVER" bash -c "$1"; }                 # as root
pxpy() { podman exec --user "$1" "$SERVER" "$VENV" -I "$ATTACK" "${@:2}"; }
bob_server_pid() { px "pgrep -u bob -f '$SERVER_RE' || true"; }

podman image exists "$IMG" || { bad "image $IMG not found"; finish; }
podman build -q -t "$CLIENT" test/e2e/client >/dev/null || { bad "client build"; finish; }
rm -f "$OUT"/isolation-*

# Server with two accounts; mount the users file and the attack fixture read-only
podman rm -f -t 0 "$SERVER" >/dev/null 2>&1
podman run -d --name "$SERVER" --shm-size=1g -e RDP_PASSWORD=unused \
  -e USERS_FILE=/etc/rdp-jupyter/users \
  -v "$USERS:/etc/rdp-jupyter/users:ro,Z" -v "$FIX:$CFIX:ro,Z" \
  -p "$PORT:3389" "$IMG" >/dev/null || { bad "server did not start"; finish; }
wait_for 30 'px "grep -q \"listening to port 3389\" /var/log/xrdp.log" 2>/dev/null' \
  || { bad "server not listening within 30s"; finish; }

say poll-start
# Start alice's cmdline poller BEFORE bob logs in, so it covers bob's whole
# login and kernel start. It stops when the harness touches $STOPFILE.
px "rm -f $TOKENFILE $STOPFILE $VERDICT $PWNED $PWNED_CONTROL"
podman exec -d --user alice "$SERVER" "$VENV" -I "$ATTACK" poll \
  --bob-uid "$BOB_UID" --tokenfile "$TOKENFILE" --stopfile "$STOPFILE" \
  --out "$VERDICT" >/dev/null
pass "cmdline poller started as alice (uid $ALICE_UID)"

say bob-login
podman run -d --name "$P-bob" --network host -v "$OUT:/out:Z" \
  "$CLIENT" "127.0.0.1:$PORT" bob bobpw isolation-bob :92 >/dev/null
if wait_for 90 '[ -n "$(bob_server_pid)" ]'; then
  BOB_PID=$(bob_server_pid)
  pass "bob's jupyterlab server running (pid $BOB_PID)"
else
  bad "bob's jupyterlab server did not start within 90s"
  finish
fi

# Hand the token to the poller as soon as the server exists (setup rewrites it
# too), so the poller's token-value match covers the login window, not only the
# post-kernel window. A setup action, not a threat-model assertion: no pass/bad.
pxpy bob token --server-pid "$BOB_PID" --tokenfile "$TOKENFILE" >/dev/null 2>&1 \
  || echo "  note: early token copy failed; poller relies on setup's copy" >&2

say kernel-setup
# As bob: start a kernel in his own server and copy his token to $TOKENFILE for
# the poller. Prints "<connfile>\t<http port>".
if raw=$(pxpy bob setup --server-pid "$BOB_PID" --tokenfile "$TOKENFILE" 2>&1); then
  info=$(printf '%s\n' "$raw" | tail -1)
  CONNFILE=${info%%$'\t'*}
  HTTP_PORT=${info##*$'\t'}
  pass "bob started a kernel: connfile $CONNFILE, http port $HTTP_PORT"
else
  bad "could not start bob's kernel: $raw"
  finish
fi
KERNEL_T0=$SECONDS

# bob's kernel shell ROUTER port, read from his connection file. Handed to the
# attacker so the unsigned-delivery assertion can target the shell channel
# precisely (alice can also see this port in /proc/net/tcp, just not which one).
SHELL_PORT=$(px "python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"shell_port\"])' $CONNFILE")

say positive-control
# As bob, with a correctly signed request, the payload DOES create its marker.
if pxpy bob control --connfile "$CONNFILE" --touch "$PWNED_CONTROL" >/dev/null 2>&1 \
   && px "test -e $PWNED_CONTROL"; then
  pass "signed execute_request created $PWNED_CONTROL (payload works when signed)"
else
  bad "positive control failed: signed request did not create $PWNED_CONTROL"
fi

say attacks
# Run every alice-side verification. Kernel-ZMQ waits 5s internally, so give it
# room. attack.py emits one RESULT line per threat-model row.
out=$(pxpy alice attack --bob-uid "$BOB_UID" --server-pid "$BOB_PID" \
  --http-port "$HTTP_PORT" --shell-port "$SHELL_PORT" --connfile "$CONNFILE" \
  --pwned "$PWNED" --pwned-control "$PWNED_CONTROL" 2>&1) || true
printf '%s\n' "$out" | sed 's/^/  attack.py: /'
res() { printf '%s\n' "$out" | awk -F'\t' -v k="$1" '$1=="RESULT"&&$2==k{print $3"\t"$4; found=1} END{if(!found)print "MISSING\t"}'; }
check() {  # check <threat-row label> <result key>
  local r; r=$(res "$2"); local ok=${r%%$'\t'*}; local detail=${r#*$'\t'}
  [ "$ok" = 1 ] && pass "$1: $detail" || bad "$1 ($detail)"
}
check "cmdline->environ: alice cannot read bob's /proc/<pid>/environ" environ
check "jupyter server: GET /api/kernels without token returns 403" api_kernels
check "kernel ZMQ: unsigned execute_request did not create $PWNED" kernel_zmq
check "connection file: alice cannot read bob's kernel-*.json" connfile
check "home dir: alice cannot list /home/bob" home
check "session dir \$S: alice cannot list /tmp/sess/*.$BOB_UID" sess
check "shared venv: alice cannot write /opt/jupyter/venv/lib" write_venv
check "shared extra: alice cannot write /opt/jupyter/extra" write_extra
check "ptrace: alice cannot PTRACE_ATTACH bob's server (EPERM)" ptrace
check "positive control confirmed by attacker" control

say cmdline-poll
# Let the poller run 60s past the kernel start (spec: catch the token flashing
# into any argv during login + kernel launch), then stop it and read its verdict.
wait_for 60 "[ $((SECONDS - KERNEL_T0)) -ge 60 ]" || true
px "touch $STOPFILE"
wait_for 20 "px 'test -s $VERDICT'" || bad "poller wrote no verdict"
verdict=$(px "cat $VERDICT 2>/dev/null")
jget() { printf '%s' "$verdict" | python3 -I -c "import json,sys; print(json.load(sys.stdin).get('$1'))" 2>/dev/null; }
saw_needle=$(jget saw_needle); saw_value=$(jget saw_value)
saw_server=$(jget saw_server); had_token=$(jget had_token)
[ "$saw_server" = True ] \
  && pass "poller saw bob's server cmdline (the 'never saw token' checks are not vacuous)" \
  || bad "poller never saw bob's server cmdline; token checks would be vacuous (verdict: $verdict)"
[ "$saw_needle" = False ] \
  && pass "cmdline poll: 'token=' never appeared in any /proc/*/cmdline" \
  || bad "cmdline poll: 'token=' appeared in a cmdline (verdict: $verdict)"
[ "$had_token" = True ] && [ "$saw_value" = False ] \
  && pass "cmdline poll: bob's token value never appeared in any /proc/*/cmdline" \
  || bad "cmdline poll: token value seen, or poller never got the token (verdict: $verdict)"

finish
