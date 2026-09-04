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

expect_json() {   # expect_json <name> <file>
    if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$2" 2>/dev/null; then
        echo "  PASS  $1"; pass=$((pass+1))
    else
        echo "  FAIL  $1: not valid JSON"; fail=$((fail+1))
    fi
}

echo ">>> build.sh tests"
# These cover decisions build.sh makes -- ordering, refusal, provenance.
# They deliberately do not re-assert the contents of the target table: that is
# data, and a test that restates it only fails when someone edits it on purpose.

out=$("$BUILD" --list 2>&1); rc=$?
echo "$out" > /tmp/b-list.$$
expect_rc "--list exits 0" 0 "$rc"
expect_contains "--list shows deps and output" /tmp/b-list.$$ 'camera adaptation'

out=$("$BUILD" nosuchtarget 2>&1); rc=$?
echo "$out" > /tmp/b-bad.$$
expect_rc "unknown target fails" 1 "$rc"
expect_contains "unknown target names itself" /tmp/b-bad.$$ 'nosuchtarget'
rm -f /tmp/b-list.$$ /tmp/b-bad.$$

# Dependency order, checked as an order. The previous form passed a multi-line
# string to grep -F, which matches any one of those lines, so it asserted a set
# and would have held even if the order were reversed. It also named kernel,
# which rootfs does not depend on, and left artifacts in the repo's own out/.
rm -rf /tmp/b-out.$$ /tmp/b-log.$$
out=$(OUT=/tmp/b-out.$$ FAKE_BUILD="$ROOT/tests/fixtures/fake-target" \
      FT_LOG=/tmp/b-log.$$ FT_RC=0 "$BUILD" rootfs 2>&1); rc=$?
expect_rc "rootfs builds" 0 "$rc"
python3 - /tmp/b-log.$$ > /tmp/b-ord.$$ 2>&1 <<'PY'
import sys
seen = [l.strip() for l in open(sys.argv[1]) if l.strip()]
print("deps_first=" + str(all(d in seen and seen.index(d) < seen.index("rootfs")
                              for d in ("camera", "adaptation"))))
print("no_extras=" + str("kernel" not in seen))
PY
expect_contains "dependencies build before their dependent" /tmp/b-ord.$$ 'deps_first=True'
expect_contains "only the requested subgraph builds"        /tmp/b-ord.$$ 'no_extras=True'
rm -rf /tmp/b-out.$$ /tmp/b-log.$$ /tmp/b-ord.$$

# A real, clean git source tree, so staleness is decided by real git state
# rather than by a stubbed commit that could never disagree with itself.
srcrepo=/tmp/b-src.$$
rm -rf "$srcrepo"; mkdir -p "$srcrepo"/kernel "$srcrepo"/camera \
    "$srcrepo"/adaptation "$srcrepo"/droidian
git -C "$srcrepo" init -q
printf 'v1\n' > "$srcrepo/kernel/f"
git -C "$srcrepo" add -A
git -C "$srcrepo" -c user.email=t@t -c user.name=t commit -qm one

bout=/tmp/b-sout.$$
rm -rf "$bout"
ftlog=/tmp/b-slog.$$
build_once() {   # build_once <target...> -- fake build into $bout from $srcrepo
    : > "$ftlog"
    SRC="$srcrepo" OUT="$bout" FAKE_BUILD="$ROOT/tests/fixtures/fake-target" \
        FT_LOG="$ftlog" FT_RC=0 "$BUILD" "$@" 2>&1
}

manifest="$bout/manifest.json"
build_once rootfs > /tmp/b-m1.$$ 2>&1; rc=$?
expect_rc "manifest build" 0 "$rc"
expect_json "manifest is valid JSON" "$manifest"

# Contract 1: artifacts keyed by output path. provision.sh and lib/phases.sh
# both index this map by path, so a flat per-target object cannot be consumed.
python3 -c "
import json
d = json.load(open('$manifest'))
a = d.get('artifacts', {})
u = a.get('droidian/userdata.img', {})
c = a.get('droidian/out-camera', {})
print('userdata_target=' + str(u.get('target')))
print('userdata_commit=' + str(bool(u.get('source_commit'))))
print('userdata_sha=' + str(bool(u.get('sha256'))))
print('dep_kept=' + str(c.get('target')))
" > /tmp/b-man.$$ 2>&1
expect_contains "manifest keys artifacts by output path" /tmp/b-man.$$ 'userdata_target=rootfs'
expect_contains "manifest records a source commit"       /tmp/b-man.$$ 'userdata_commit=True'
expect_contains "manifest records a sha256"              /tmp/b-man.$$ 'userdata_sha=True'
# rootfs pulls in camera and adaptation; every target built this run must
# survive in the manifest, which a per-target file would not have done.
expect_contains "manifest keeps all targets from one run" /tmp/b-man.$$ 'dep_kept=camera'

# Unchanged clean source: nothing rebuilds.
build_once rootfs > /tmp/b-m2.$$ 2>&1
expect_absent  "an up-to-date target is skipped" "$ftlog" 'rootfs'
expect_contains "the skip is reported"           /tmp/b-m2.$$ 'up to date'

# The source moved: it must rebuild, and say why. kernel is not a dependency
# of rootfs, so it needs its own build first to have anything recorded.
build_once kernel > /dev/null 2>&1
printf 'v2\n' > "$srcrepo/kernel/f"
git -C "$srcrepo" add -A
git -C "$srcrepo" -c user.email=t@t -c user.name=t commit -qm two
build_once kernel > /tmp/b-m3.$$ 2>&1
expect_contains "a moved source commit rebuilds" "$ftlog" 'kernel'
expect_contains "the reason is reported"         /tmp/b-m3.$$ 'source moved'

# A deleted artifact rebuilds even though the commit still matches.
rm -f "$bout/droidian/out/images/boot.img"
build_once kernel > /tmp/b-m4.$$ 2>&1
expect_contains "a missing artifact rebuilds" "$ftlog" 'kernel'
expect_contains "the missing reason is reported" /tmp/b-m4.$$ 'missing'

# FORCE overrides a correct up-to-date decision.
build_once kernel > /dev/null 2>&1
FORCE=1 build_once kernel > /tmp/b-m5.$$ 2>&1
expect_contains "FORCE rebuilds regardless" "$ftlog" 'kernel'

rm -rf "$bout" "$srcrepo" "$ftlog" /tmp/b-m1.$$ /tmp/b-m2.$$ /tmp/b-m3.$$ \
       /tmp/b-m4.$$ /tmp/b-m5.$$ /tmp/b-man.$$

echo
echo ">>> provision.sh tests"

PROV="$ROOT/provision.sh"

# A complete probe with a manifest that has all targets should request nothing.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\n' > /tmp/pr-ok.$$
"$PROV" --plan-only --probe-file /tmp/pr-ok.$$ --manifest "$ROOT/tests/fixtures/manifest.json" \
    > /tmp/pl-ok.$$ 2>/dev/null
expect_json "plan-only emits valid JSON" /tmp/pl-ok.$$
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
