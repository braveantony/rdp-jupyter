#!/usr/bin/env bash
# Unit tests for images/rdp-jupyter/rootfs/opt/rdp-jupyter/sesman-config.sh
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
CFG=images/rdp-jupyter/rootfs/opt/rdp-jupyter/sesman-config.sh
FIXTURE=test/unit/fixtures/sesman.ini

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ini=$work/sesman.ini

# fresh: copy the fixture to $ini
fresh() { cp "$FIXTURE" "$ini"; }

say "all four values changed"
fresh
bash "$CFG" "$ini" 5 600 >/dev/null 2>&1
rc=$?
got=$(grep -E '^(Policy|KillDisconnected|DisconnectedTimeLimit|MaxSessions)=' "$ini" | sort)
want='DisconnectedTimeLimit=600
KillDisconnected=true
MaxSessions=5
Policy=Default'
[ "$rc" -eq 0 ] && [ "$got" = "$want" ] && pass "four keys set" || bad "four keys: rc=$rc got: $got"

say "only those four lines differ"
fresh
bash "$CFG" "$ini" 5 600 >/dev/null 2>&1
diffs=$(diff "$FIXTURE" "$ini" | grep -E '^[<>]' | sort)
want_diffs='< DisconnectedTimeLimit=0
< KillDisconnected=false
< MaxSessions=50
< Policy=Separate
> DisconnectedTimeLimit=600
> KillDisconnected=true
> MaxSessions=5
> Policy=Default'
[ "$diffs" = "$(sort <<<"$want_diffs")" ] && pass "diff is the four lines" || bad "diff: $diffs"

say "missing key exits 1 and leaves the file unchanged"
for key in Policy KillDisconnected DisconnectedTimeLimit MaxSessions; do
  grep -v "^$key=" "$FIXTURE" > "$ini"
  before=$(cat "$ini")
  err=$(bash "$CFG" "$ini" 5 600 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" -eq 1 ] && [ "$(cat "$ini")" = "$before" ] && grep -q "missing $key in $ini" <<<"$err"; then
    pass "missing $key"
  else
    bad "missing $key: rc=$rc err=$err"
  fi
done

say "a commented key does not count as present"
grep -v '^Policy=' "$FIXTURE" > "$ini"
sed 's/^;Policy=UBDI/;Policy=Default/' "$ini" > "$ini.tmp" && mv "$ini.tmp" "$ini"
bash "$CFG" "$ini" 5 600 >/dev/null 2>&1
[ $? -eq 1 ] && pass "commented Policy is not a match" || bad "commented Policy was accepted"

say "running twice gives the same file"
fresh
bash "$CFG" "$ini" 5 600 >/dev/null 2>&1
once=$(cat "$ini")
bash "$CFG" "$ini" 5 600 >/dev/null 2>&1
[ "$(cat "$ini")" = "$once" ] && pass "idempotent" || bad "second run changed the file"

say "wrong argument count exits 1"
fresh
bash "$CFG" "$ini" 5 >/dev/null 2>&1; rc1=$?
bash "$CFG" "$ini" 5 600 extra >/dev/null 2>&1; rc2=$?
bash "$CFG" >/dev/null 2>&1; rc3=$?
if [ "$rc1" -eq 1 ] && [ "$rc2" -eq 1 ] && [ "$rc3" -eq 1 ]; then
  pass "2, 4 and 0 arguments"
else
  bad "arg count: rc=$rc1,$rc2,$rc3"
fi
cmp -s "$FIXTURE" "$ini" && pass "file untouched by bad usage" || bad "file changed on bad usage"

finish
