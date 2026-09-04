#!/usr/bin/env bash
# Offline tests for the adaptation packages. No device, no root, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPT="$(dirname "$HERE")"
FIX="$HERE/fixtures"
pass=0; fail=0

check() {   # check <name> <expected-file> <actual-file>
    if diff -u "$2" "$3" > /tmp/hhp-diff.$$ 2>&1; then
        echo "  PASS  $1"; pass=$((pass+1))
    else
        echo "  FAIL  $1"; sed 's/^/        /' /tmp/hhp-diff.$$; fail=$((fail+1))
    fi
    rm -f /tmp/hhp-diff.$$
}

expect_contains() {   # expect_contains <name> <file> <string>
    if grep -qF -- "$3" "$2"; then
        echo "  PASS  $1"; pass=$((pass+1))
    else
        echo "  FAIL  $1: expected to find: $3"; fail=$((fail+1))
    fi
}

expect_absent() {   # expect_absent <name> <file> <string>
    if grep -qF -- "$3" "$2"; then
        echo "  FAIL  $1: should not contain: $3"; fail=$((fail+1))
    else
        echo "  PASS  $1"; pass=$((pass+1))
    fi
}

# A fake reachability probe: exits 0 when the node is listed in the fixture.
# $1 is quoted in every *_CMD because the generator substitutes it textually,
# and an unquoted /dev/input/* would be glob-expanded by eval against THIS host.
export HHP_REACH_CMD="grep -qxF \"\$1\" $FIX/reachable.txt"
export HHP_UEVENTD_FILES="$FIX/vendor-ueventd.rc $FIX/ueventd.rc"
# A fake glob expander backed by a fixture, so the tests give the same answer on
# every machine. The real one expands against the device's own /dev at boot.
export FIX
export HHP_EXPAND_CMD="$HERE/fake-expand \"\$1\""

echo ">>> adaptation tests"
# Task 2+ append their cases below this line.

GEN="$ADAPT/halium-hostdev-perms/usr/lib/halium-hostdev-perms/generate-rules"
export HHP_POLICY_DIRS=""            # no policy yet; Task 3 adds deny handling
"$GEN" > /tmp/hhp-out.$$ 2>/dev/null

expect_contains "hwbinder is fixed (declared, unreachable)" /tmp/hhp-out.$$ \
    'KERNEL=="hwbinder", OWNER="root", GROUP="root", MODE="0666"'
expect_contains "kgsl-3d0 is fixed" /tmp/hhp-out.$$ \
    'KERNEL=="kgsl-3d0", OWNER="system", GROUP="system", MODE="0666"'
expect_contains "ion is fixed" /tmp/hhp-out.$$ \
    'KERNEL=="ion", OWNER="system", GROUP="system", MODE="0664"'
expect_absent "binder untouched (already reachable)" /tmp/hhp-out.$$ 'KERNEL=="binder"'
expect_absent "input untouched (already reachable)" /tmp/hhp-out.$$ 'event0'
expect_absent "dri card0 untouched (already reachable)" /tmp/hhp-out.$$ 'card0'
expect_absent "no inline comment after a rule" /tmp/hhp-out.$$ '" # '

# Globs must expand, and expand from the FIXTURE, not this host's /dev.
expect_contains "glob declaration expands (/dev/subsys_*)" /tmp/hhp-out.$$ \
    'KERNEL=="subsys_modem"'
expect_absent "expansion did not leak this host's /dev" /tmp/hhp-out.$$ 'event20'

# udev matches KERNEL against the sysname. A subdirectory node must emit its
# basename; KERNEL=="dri/renderD128" would match nothing and fail silently.
expect_contains "subdir node emits bare sysname" /tmp/hhp-out.$$ \
    'KERNEL=="renderD128", OWNER="root", GROUP="graphics", MODE="0666"'
expect_absent "KERNEL is never a path" /tmp/hhp-out.$$ 'KERNEL=="dri/'

# /dev/diag is declared in both files; the vendor file is read first and wins.
expect_contains "vendor declaration wins for diag" /tmp/hhp-out.$$ \
    'KERNEL=="diag", OWNER="system", GROUP="oem_2901"'
rm -f /tmp/hhp-out.$$

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
