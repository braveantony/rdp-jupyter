#!/usr/bin/env bash
# Unit tests for images/rdp-jupyter/rootfs/opt/rdp-jupyter/server-env.sh
# shellcheck disable=SC1091,SC2015  # pass() never fails, so A && B || C is safe here
set -u
cd "$(dirname "$0")/../.." || exit 1
. test/lib.sh
GEN=images/rdp-jupyter/rootfs/opt/rdp-jupyter/server-env.sh
unset OPENBLAS_NUM_THREADS OMP_NUM_THREADS MKL_NUM_THREADS KERNEL_THREADS KERNEL_MEMORY_LIMIT_KB
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

f=$tmp/good.env; printf 'KERNEL_MEMORY_LIMIT_KB=1572864\nKERNEL_THREADS=3\n' > "$f"
big=$tmp/big.env; printf 'KERNEL_MEMORY_LIMIT_KB=4194304\nKERNEL_THREADS=2\n' > "$big"

say "limits and threads"
out=$(RDP_JUPYTER_SESSION_ENV=$f GEN=$GEN bash -c '. $GEN; ulimit -S -d; ulimit -H -d; echo $OPENBLAS_NUM_THREADS $OMP_NUM_THREADS $MKL_NUM_THREADS')
[ "$out" = $'1572864\n1572864\n3 3 3' ] && pass "limits and threads" || bad "got: $out"
# hard limit cannot be raised again
RDP_JUPYTER_SESSION_ENV=$f GEN=$GEN bash -c '. $GEN; ulimit -S -d 3000000' 2>/dev/null && bad "raised above hard limit" || pass "hard limit holds"
# missing file falls back to defaults
out=$(RDP_JUPYTER_SESSION_ENV=/nonexistent GEN=$GEN bash -c '. $GEN; ulimit -H -d; echo $OPENBLAS_NUM_THREADS')
[ "$out" = $'2097152\n2' ] && pass "defaults" || bad "got: $out"

say "invalid values use defaults"
bad_cfg=$tmp/bad.env; printf 'KERNEL_MEMORY_LIMIT_KB=abc\nKERNEL_THREADS=0\n' > "$bad_cfg"
out=$(RDP_JUPYTER_SESSION_ENV=$bad_cfg GEN=$GEN bash -c '. $GEN; ulimit -H -d; echo $OPENBLAS_NUM_THREADS')
[ "$out" = $'2097152\n2' ] && pass "garbage is default" || bad "got: $out"
neg_cfg=$tmp/neg.env; printf 'KERNEL_MEMORY_LIMIT_KB=-5\nKERNEL_THREADS=08\n' > "$neg_cfg"
out=$(RDP_JUPYTER_SESSION_ENV=$neg_cfg GEN=$GEN bash -c '. $GEN; ulimit -H -d; echo $OPENBLAS_NUM_THREADS')
[ "$out" = $'2097152\n8' ] && pass "negative memory is default, leading zero is base-10" || bad "got: $out"

say "caller survives"
# sourcing never exits the caller
RDP_JUPYTER_SESSION_ENV=/nonexistent GEN=$GEN bash -c '. $GEN; echo alive' 2>/dev/null | grep -q alive && pass "caller survives" || bad "caller exited"
out=$(RDP_JUPYTER_SESSION_ENV=/nonexistent GEN=$GEN bash -euc '. "$GEN"; echo alive' 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = alive ] && pass "survives set -eu" || bad "set -eu: rc=$rc out=$out"
out=$(RDP_JUPYTER_SESSION_ENV=$bad_cfg GEN=$GEN bash -euc '. "$GEN"; echo alive' 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = alive ] && pass "invalid values survive set -eu" || bad "invalid set -eu: rc=$rc out=$out"
out=$(RDP_JUPYTER_SESSION_ENV=$f GEN=$GEN bash -euc '. "$GEN"; . "$GEN"; echo alive; ulimit -H -d' 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = $'alive\n1572864' ] && pass "sourced twice, same config" || bad "twice: rc=$rc out=$out"
out=$(RDP_JUPYTER_SESSION_ENV=$f BIG=$big GEN=$GEN bash -euc '. "$GEN"; RDP_JUPYTER_SESSION_ENV=$BIG; . "$GEN"; echo alive; ulimit -H -d' 2>"$tmp/err"); rc=$?
err=$(cat "$tmp/err")
[ "$rc" -eq 0 ] && [ "$out" = $'alive\n1572864' ] && pass "sourced twice, raise refused, hard limit kept" || bad "raise refused: rc=$rc out=$out"
grep -q '^\[server-env\]' <<<"$err" && pass "raise refusal notes on stderr" || bad "no stderr note: $err"

say "only the two values are taken"
out=$(RDP_JUPYTER_SESSION_ENV=$f GEN=$GEN bash -c '. $GEN; echo "${KERNEL_MEMORY_LIMIT_KB-unset} ${KERNEL_THREADS-unset} $(type -t _rdp_int) $(ulimit -H -d)"' 2>/dev/null)
[ "$out" = "unset unset  1572864" ] && pass "no leaked variables or functions" || bad "got: $out"

finish
