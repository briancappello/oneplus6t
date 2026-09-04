#!/usr/bin/env bash
# Offline tests for build.sh and provision.sh.
# No phone, no worker, no network, no real builds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BUILD="$ROOT/build.sh"
pass=0; fail=0

# No test may reach a real phone. Fake fastboot/edl/device-ssh shadow the real
# ones for every child process, so this is a property of the environment rather
# than a flag each test has to remember. Whether a device is attached and ready
# is a readiness question, answered by ./device.sh state, never by this suite.
export PATH="$HERE/fixtures/bin:$PATH"
export HW_LOG=/tmp/hw-log.$$
: > "$HW_LOG"
trap 'rm -f "$HW_LOG"' EXIT

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
echo ">>> provision.sh tests"

PROV="$ROOT/provision.sh"

# A complete probe with a manifest that has all targets should request nothing.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\n' > /tmp/pr-ok.$$
"$PROV" --plan-only --probe-file /tmp/pr-ok.$$ --manifest "$ROOT/tests/fixtures/manifest.json" \
    > /tmp/pl-ok.$$ 2>/dev/null
python3 -c "import json;json.load(open('/tmp/pl-ok.$$'))" \
    && { echo "  PASS  plan-only emits valid JSON"; pass=$((pass+1)); } \
    || { echo "  FAIL  plan-only emits valid JSON"; fail=$((fail+1)); }
expect_contains "plan has a build list" /tmp/pl-ok.$$ '"build"'

# An incomplete probe must request everything, never skip.
printf 'state=fastboot\nprobe_complete=no\n' > /tmp/pr-part.$$
"$PROV" --plan-only --probe-file /tmp/pr-part.$$ --manifest "$ROOT/tests/fixtures/manifest.json" \
    > /tmp/pl-part.$$ 2>/dev/null
expect_contains "incomplete probe requests kernel" /tmp/pl-part.$$ 'kernel'
expect_contains "incomplete probe requests rootfs" /tmp/pl-part.$$ 'rootfs'

# A missing artifact is always requested.
printf '{"artifacts":{},"repo_commit":"x"}\n' > /tmp/m-empty.$$
"$PROV" --plan-only --probe-file /tmp/pr-ok.$$ --manifest /tmp/m-empty.$$ \
    > /tmp/pl-empty.$$ 2>/dev/null
expect_contains "an absent artifact is requested" /tmp/pl-empty.$$ 'kernel'

rm -f /tmp/pr-ok.$$ /tmp/pl-ok.$$ /tmp/pr-part.$$ /tmp/pl-part.$$ /tmp/m-empty.$$ /tmp/pl-empty.$$

# Skip detection: boot phase skips when sha matches
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nboot_sha=aaaa\n' > /tmp/pr-boot-match.$$
. "$ROOT/lib/phases.sh"
if skip_boot /tmp/pr-boot-match.$$ "$ROOT/tests/fixtures/manifest.json"; then
    echo "  PASS  boot phase skips when sha matches"; pass=$((pass+1))
else
    echo "  FAIL  boot phase skips when sha matches"; fail=$((fail+1))
fi

# Skip detection: boot phase runs when sha differs
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nboot_sha=bbbb\n' > /tmp/pr-boot-diff.$$
if skip_boot /tmp/pr-boot-diff.$$ "$ROOT/tests/fixtures/manifest.json"; then
    echo "  FAIL  boot phase runs when sha differs"; fail=$((fail+1))
else
    echo "  PASS  boot phase runs when sha differs"; pass=$((pass+1))
fi

# Skip detection: data phase skips when package versions match
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\npkg_camera=1.0.0\npkg_adaptation=1.0.0\n' > /tmp/pr-data-match.$$
if skip_data /tmp/pr-data-match.$$ "$ROOT/tests/fixtures/manifest.json"; then
    echo "  PASS  data phase skips when versions match"; pass=$((pass+1))
else
    echo "  FAIL  data phase skips when versions match"; fail=$((fail+1))
fi

# Skip detection: data phase runs when package version differs
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\npkg_camera=2.0.0\npkg_adaptation=1.0.0\n' > /tmp/pr-data-diff.$$
if skip_data /tmp/pr-data-diff.$$ "$ROOT/tests/fixtures/manifest.json"; then
    echo "  FAIL  data phase runs when version differs"; fail=$((fail+1))
else
    echo "  PASS  data phase runs when version differs"; pass=$((pass+1))
fi

rm -f /tmp/pr-boot-match.$$ /tmp/pr-boot-diff.$$ /tmp/pr-data-match.$$ /tmp/pr-data-diff.$$

# Flash phases: boot phase flashes boot and vbmeta
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nboot_sha=bbbb\n' > /tmp/pr-flash-boot.$$
mkdir -p /tmp/artifacts-test/droidian/out/images
touch /tmp/artifacts-test/droidian/out/images/boot.img
touch /tmp/artifacts-test/droidian/out/images/vbmeta.img
timeout 30 "$PROV" --artifacts /tmp/artifacts-test --probe-file /tmp/pr-flash-boot.$$ --phase boot > /tmp/p-flash-boot.$$ 2>&1; rc=$?
expect_rc "boot phase exits 0" 0 "$rc"
expect_contains "boot phase flashes boot" /tmp/p-flash-boot.$$ 'boot: flashing'
rm -rf /tmp/artifacts-test /tmp/pr-flash-boot.$$ /tmp/p-flash-boot.$$

# Flash phases: data phase flashes userdata
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\npkg_camera=2.0.0\npkg_adaptation=1.0.0\n' > /tmp/pr-flash-data.$$
mkdir -p /tmp/artifacts-test/droidian
touch /tmp/artifacts-test/droidian/userdata.img
timeout 10 "$PROV" --artifacts /tmp/artifacts-test --probe-file /tmp/pr-flash-data.$$ --manifest "$ROOT/tests/fixtures/manifest.json" --phase data > /tmp/p-flash-data.$$ 2>/tmp/p-flash-data-err.$$; rc=$?
expect_rc "data phase exits 0" 0 "$rc"
expect_contains "data phase flashes userdata" /tmp/p-flash-data.$$ 'data: installing rootfs'
rm -rf /tmp/artifacts-test /tmp/pr-flash-data.$$ /tmp/p-flash-data.$$

# --artifacts mode accepts a path and runs all phases
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nboot_sha=bbbb\npkg_camera=2.0.0\npkg_adaptation=1.0.0\n' > /tmp/pr-ok.$$
mkdir -p /tmp/artifacts-test/droidian/out/images
touch /tmp/artifacts-test/droidian/out/images/boot.img
touch /tmp/artifacts-test/droidian/out/images/vbmeta.img
touch /tmp/artifacts-test/droidian/userdata.img
: > "$HW_LOG"
FAKE_SSH_FIXTURE="$HERE/fixtures/probe-droidian.txt" \
timeout 30 "$PROV" --artifacts /tmp/artifacts-test --probe-file /tmp/pr-ok.$$ > /tmp/p-art.$$ 2>&1; rc=$?
expect_rc "--artifacts mode exits 0" 0 "$rc"
# rc=124 would mean a phase blocked waiting for a device. Bounded so that a
# regression fails the suite instead of hanging it.
expect_contains "the boot flash names the slot" "$HW_LOG" 'fastboot flash boot_a'
expect_contains "the userdata flash is issued" "$HW_LOG" 'fastboot flash userdata'
expect_contains "--artifacts echoes the path" /tmp/p-art.$$ '/tmp/artifacts-test'
expect_contains "edl phase runs" /tmp/p-art.$$ 'edl:'
expect_contains "boot phase runs" /tmp/p-art.$$ 'boot:'
expect_contains "data phase runs" /tmp/p-art.$$ 'data:'
expect_contains "activate phase runs" /tmp/p-art.$$ 'activate:'
expect_contains "verify phase runs" /tmp/p-art.$$ 'verify:'
rm -rf /tmp/artifacts-test /tmp/p-art.$$

# --phase flag runs only that phase
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nboot_sha=bbbb\n' > /tmp/pr-phase.$$
mkdir -p /tmp/artifacts-test/droidian/out/images
touch /tmp/artifacts-test/droidian/out/images/boot.img
touch /tmp/artifacts-test/droidian/out/images/vbmeta.img
timeout 30 "$PROV" --artifacts /tmp/artifacts-test --probe-file /tmp/pr-phase.$$ --phase boot > /tmp/p-phase.$$ 2>&1; rc=$?
expect_rc "--phase boot exits 0" 0 "$rc"
expect_contains "only boot phase runs" /tmp/p-phase.$$ 'boot:'
expect_absent "edl phase is skipped" /tmp/p-phase.$$ 'edl:'
expect_absent "data phase is skipped" /tmp/p-phase.$$ 'data:'
rm -rf /tmp/artifacts-test /tmp/pr-phase.$$ /tmp/p-phase.$$

echo
echo ">>> lib/probe.sh tests"

PROBE="$ROOT/lib/probe.sh"

# Droidian: everything readable over ssh.
PROBE_STATE=droidian PROBE_SSH_FIXTURE="$ROOT/tests/fixtures/probe-droidian.txt" \
    bash "$PROBE" probe_all > /tmp/p-dro.$$ 2>&1
expect_contains "state is reported"        /tmp/p-dro.$$ 'state=droidian'
expect_contains "fingerprint is parsed"    /tmp/p-dro.$$ 'vendor_fp=halium/lineage_halium_arm64'
expect_contains "package versions parsed"  /tmp/p-dro.$$ 'pkg_halium-hostdev-perms=1.0.0'
expect_contains "probe is complete"        /tmp/p-dro.$$ 'probe_complete=yes'

# fastboot: less is readable, and what is missing must say so.
PROBE_STATE=fastboot PROBE_FB_FIXTURE="$ROOT/tests/fixtures/probe-fastboot.txt" \
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
