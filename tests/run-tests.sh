#!/usr/bin/env bash
# Offline tests for build.sh and provision.sh.
# No phone, no worker, no network, no real builds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BUILD="$ROOT/build.sh"
pass=0; fail=0

expect_contains() {   # expect_contains <name> <file> <string>
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        echo "  PASS  $1"; pass=$((pass+1))
    else
        echo "  FAIL  $1: expected to find: $3"
        sed 's/^/        /' "$2" 2>/dev/null | head -20
        fail=$((fail+1))
    fi
}

expect_absent() {   # expect_absent <name> <file> <string>
    if grep -qF -- "$3" "$2" 2>/dev/null; then
        echo "  FAIL  $1: should not contain: $3"; fail=$((fail+1))
    else
        echo "  PASS  $1"; pass=$((pass+1))
    fi
}

expect_rc() {   # expect_rc <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  PASS  $1"; pass=$((pass+1))
    else
        echo "  FAIL  $1: expected rc=$2 got rc=$3"; fail=$((fail+1))
    fi
}

echo ">>> build.sh tests"
# Task 2+ append their cases below this line.

out=$("$BUILD" --list 2>&1); rc=$?
echo "$out" > /tmp/b-list.$$
expect_rc "--list exits 0" 0 "$rc"
expect_contains "lists kernel"     /tmp/b-list.$$ 'kernel'
expect_contains "lists camera"     /tmp/b-list.$$ 'camera'
expect_contains "lists adaptation" /tmp/b-list.$$ 'adaptation'
expect_contains "lists rootfs"     /tmp/b-list.$$ 'rootfs'
expect_contains "shows the rootfs dependency" /tmp/b-list.$$ 'camera adaptation'
expect_contains "shows an output path" /tmp/b-list.$$ 'droidian/userdata.img'

out=$("$BUILD" nosuchtarget 2>&1); rc=$?
echo "$out" > /tmp/b-bad.$$
expect_rc "unknown target fails" 1 "$rc"
expect_contains "unknown target names itself" /tmp/b-bad.$$ 'nosuchtarget'
rm -f /tmp/b-list.$$ /tmp/b-bad.$$

rm -rf /tmp/b-out.$$ && mkdir -p /tmp/b-out.$$
out=$(FAKE_BUILD="$ROOT/tests/fixtures/fake-target" FT_LOG=/tmp/b-log.$$ FT_RC=0 \
      "$BUILD" rootfs 2>&1); rc=$?
echo "$out" > /tmp/b-order.$$
expect_rc "rootfs builds" 0 "$rc"
expect_contains "builds dependencies first" /tmp/b-order.$$ 'built: kernel
built: camera
built: adaptation
built: rootfs'
expect_contains "independent targets build in parallel" /tmp/b-order.$$ 'built: camera
built: kernel'
rm -f /tmp/b-order.$$ /tmp/b-log.$$

rm -rf /tmp/b-mout.$$ && mkdir -p /tmp/b-mout.$$
out=$(OUT=/tmp/b-mout.$$ FAKE_BUILD="$ROOT/tests/fixtures/fake-target" FT_LOG=/tmp/b-log.$$ FT_RC=0 \
      "$BUILD" rootfs 2>&1); rc=$?
manifest="/tmp/b-mout.$$/manifest.json"
expect_rc "manifest build" 0 "$rc"
[ -f "$manifest" ] || { echo "  FAIL  manifest written: missing $manifest"; fail=$((fail+1)); }
expect_contains "manifest names the target"    "$manifest" '"name": "rootfs"'
expect_contains "manifest records the commit"  "$manifest" '"commit": "'
expect_contains "manifest records the source"  "$manifest" '"source": "'
expect_contains "manifest records the output"  "$manifest" '"output": "droidian/userdata.img"'
rm -rf /tmp/b-mout.$$ /tmp/b-log.$$

echo
echo ">>> lib/probe.sh tests"

PROBE="$ROOT/lib/probe.sh"

# Droidian: everything readable over ssh.
PROBE_STATE=droidian PROBE_SSH_FIXTURE="$HERE/fixtures/probe-droidian.txt" \
    bash "$PROBE" probe_all > /tmp/p-dro.$$ 2>&1
expect_contains "state is reported"        /tmp/p-dro.$$ 'state=droidian'
expect_contains "fingerprint is parsed"    /tmp/p-dro.$$ 'vendor_fp=halium/lineage_halium_arm64'
expect_contains "package versions parsed"  /tmp/p-dro.$$ 'pkg_halium-hostdev-perms=1.0.0'
expect_contains "probe is complete"        /tmp/p-dro.$$ 'probe_complete=yes'

# fastboot: less is readable, and what is missing must say so.
PROBE_STATE=fastboot PROBE_FB_FIXTURE="$HERE/fixtures/probe-fastboot.txt" \
    bash "$PROBE" probe_all > /tmp/p-fb.$$ 2>&1
expect_contains "slot is parsed in fastboot" /tmp/p-fb.$$ 'slot=a'
expect_contains "unreadable facts say unknown" /tmp/p-fb.$$ '=unknown'
expect_contains "an incomplete probe says so"  /tmp/p-fb.$$ 'probe_complete=no'

# A powered-off phone must not produce confident answers.
PROBE_STATE=off bash "$PROBE" probe_all > /tmp/p-off.$$ 2>&1
expect_contains "off reports its state"   /tmp/p-off.$$ 'state=off'
expect_contains "off is never complete"   /tmp/p-off.$$ 'probe_complete=no'
rm -f /tmp/p-dro.$$ /tmp/p-fb.$$ /tmp/p-off.$$

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
