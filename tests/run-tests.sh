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

# The suite is sealed against reaching a phone. It must equally not write into
# the working tree: a fetch test once replaced a 4 GB rootfs image with a
# 22-byte fixture, because the code under test writes to real paths by default.
# Snapshotting the tree beats enumerating what may change, which is exactly the
# list nobody keeps up to date.
TREE_BEFORE=/tmp/tree-before.$$
git -C "$ROOT" status --porcelain --ignored > "$TREE_BEFORE" 2>/dev/null || : > "$TREE_BEFORE"
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
expect_contains "--list names the command that builds each target" /tmp/b-list.$$ 'build-rootfs.sh'

# Every declared command must be a real executable. The table once held a bare
# tree name in the command column, so a real build ran `bash -c adaptation` and
# the only thing that ever exercised the path was FAKE_BUILD. Nothing failed
# until a worker tried it.
"$BUILD" --check-commands > /tmp/b-cmd.$$ 2>&1; rc=$?
expect_rc "every target's build command exists" 0 "$rc"

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
u = a.get('droidian/linuxroot.img', {})
c = a.get('droidian/out-camera', {})
print('rootfs_target=' + str(u.get('target')))
print('rootfs_commit=' + str(bool(u.get('source_commit'))))
print('rootfs_sha=' + str(bool(u.get('sha256'))))
print('dep_kept=' + str(c.get('target')))
" > /tmp/b-man.$$ 2>&1
expect_contains "manifest keys artifacts by output path" /tmp/b-man.$$ 'rootfs_target=rootfs'
expect_contains "manifest records a source commit"       /tmp/b-man.$$ 'rootfs_commit=True'
expect_contains "manifest records a sha256"              /tmp/b-man.$$ 'rootfs_sha=True'

# The rootfs is flashed to linuxroot, so the kernel must tell the initramfs to
# look there. Read from the packaging the way the build does, so an edit that
# drops the token fails here instead of at the first boot.
grep '^KERNEL_BOOTIMAGE_CMDLINE = ' "$ROOT/droidian/packaging/debian/kernel-info.mk" \
    | grep -o 'datapart=[^ ]*' > /tmp/b-cmd.$$
expect_contains "the kernel cmdline points the initramfs at linuxroot" /tmp/b-cmd.$$ 'datapart=/dev/disk/by-partlabel/linuxroot'
rm -f /tmp/b-cmd.$$
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

# --plan: Contract 2, the file provision.sh --plan-only emits.
printf '{"build":["camera"],"force":false}\n' > /tmp/b-plan.$$
build_once --plan /tmp/b-plan.$$ > /tmp/b-p1.$$ 2>&1; rc=$?
expect_rc "a plan builds" 0 "$rc"
expect_contains "a plan selects its targets" "$ftlog" 'camera'
expect_absent  "a plan builds nothing else"  "$ftlog" 'rootfs'

printf '{"build":["nosuch"]}\n' > /tmp/b-bad1.$$
build_once --plan /tmp/b-bad1.$$ > /tmp/b-p2.$$ 2>&1; rc=$?
expect_rc "a plan naming an unknown target fails" 1 "$rc"
expect_contains "the unknown target is named" /tmp/b-p2.$$ 'nosuch'

build_once --plan /tmp/does-not-exist.json > /tmp/b-p3.$$ 2>&1; rc=$?
expect_rc "a missing plan file fails" 1 "$rc"

printf 'not json at all\n' > /tmp/b-junk.$$
build_once --plan /tmp/b-junk.$$ > /tmp/b-p4.$$ 2>&1; rc=$?
expect_rc "a malformed plan fails loudly" 1 "$rc"

# force in the plan overrides an up-to-date decision, for when the phone host
# has evidence the worker cannot see.
printf '{"build":["camera"],"force":true}\n' > /tmp/b-plan2.$$
build_once --plan /tmp/b-plan2.$$ > /dev/null 2>&1
expect_contains "a forcing plan rebuilds" "$ftlog" 'camera'

# A directory output holds the package AND everything dpkg drops beside it, and
# it keeps holding the previous build's packages unless someone clears it. Both
# leak into the manifest, and a manifest naming two versions of one package
# describes a device that cannot exist -- which is exactly what stops skip_data
# from ever skipping again.
dout=/tmp/b-dout.$$
rm -rf "$dout"
: > "$ftlog"
SRC="$srcrepo" OUT="$dout" FAKE_BUILD="$ROOT/tests/fixtures/fake-target-dir" \
    FT_LOG="$ftlog" FT_RC=0 FT_DEB_VERSION=1.0.0 "$BUILD" camera > /dev/null 2>&1
python3 -c "
import json
a = json.load(open('$dout/manifest.json'))['artifacts']
print('deb=' + str(any(p.endswith('thing_1.0.0_arm64.deb') for p in a)))
print('junk=' + str(any(p.endswith(('.changes', '.dsc', 'build.log')) for p in a)))
" > /tmp/b-d1.$$ 2>&1
expect_contains "a directory output records its packages" /tmp/b-d1.$$ 'deb=True'
expect_contains "and not the build detritus beside them" /tmp/b-d1.$$ 'junk=False'

FORCE=1 SRC="$srcrepo" OUT="$dout" FAKE_BUILD="$ROOT/tests/fixtures/fake-target-dir" \
    FT_LOG="$ftlog" FT_RC=0 FT_DEB_VERSION=2.0.0 "$BUILD" camera > /dev/null 2>&1
python3 -c "
import json
a = json.load(open('$dout/manifest.json'))['artifacts']
print('new=' + str(any(p.endswith('thing_2.0.0_arm64.deb') for p in a)))
print('stale=' + str(any(p.endswith('thing_1.0.0_arm64.deb') for p in a)))
" > /tmp/b-d2.$$ 2>&1
expect_contains "a rebuild records the new package" /tmp/b-d2.$$ 'new=True'
expect_contains "and forgets the one it replaced"   /tmp/b-d2.$$ 'stale=False'
[ -e "$dout/droidian/out-camera/thing_1.0.0_arm64.deb" ] \
    && { echo "  FAIL  the output directory is cleared before a rebuild"; fail=$((fail+1)); } \
    || { echo "  PASS  the output directory is cleared before a rebuild"; pass=$((pass+1)); }
rm -rf "$dout" /tmp/b-d1.$$ /tmp/b-d2.$$

rm -rf "$bout" "$srcrepo" "$ftlog" /tmp/b-m1.$$ /tmp/b-m2.$$ /tmp/b-m3.$$ \
       /tmp/b-m4.$$ /tmp/b-m5.$$ /tmp/b-man.$$ /tmp/b-plan.$$ /tmp/b-plan2.$$ \
       /tmp/b-bad1.$$ /tmp/b-junk.$$ /tmp/b-p1.$$ /tmp/b-p2.$$ /tmp/b-p3.$$ /tmp/b-p4.$$

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

# FORCE=1 asks for everything with force set, so a source change behind a
# complete manifest can be rebuilt through the same seam. Without it the plan
# is empty, build.sh refuses an empty plan, and the remote build just dies.
FORCE=1 "$PROV" --plan-only --probe-file /tmp/pr-ok.$$ --manifest "$ROOT/tests/fixtures/manifest.json" \
    > /tmp/pl-force.$$ 2>/dev/null
expect_contains "FORCE=1 requests every target"  /tmp/pl-force.$$ 'rootfs'
expect_contains "FORCE=1 sets force in the plan" /tmp/pl-force.$$ '"force": true'
rm -f /tmp/pl-force.$$

# The round trip. provision.sh decides from device evidence and emits a plan;
# build.sh consumes exactly that file. These two agreed only on paper until the
# manifest they share was made a single contract, so the seam is worth pinning.
rtsrc=/tmp/rt-src.$$; rtout=/tmp/rt-out.$$
rm -rf "$rtsrc" "$rtout"
mkdir -p "$rtsrc"/kernel "$rtsrc"/camera "$rtsrc"/adaptation "$rtsrc"/droidian
git -C "$rtsrc" init -q
printf 'v1\n' > "$rtsrc/kernel/f"
git -C "$rtsrc" add -A
git -C "$rtsrc" -c user.email=t@t -c user.name=t commit -qm one
SRC="$rtsrc" OUT="$rtout" FAKE_BUILD="$ROOT/tests/fixtures/fake-target" \
    FT_LOG=/tmp/rt-log.$$ FT_RC=0 "$BUILD" --plan /tmp/pl-empty.$$ \
    > /tmp/rt-b.$$ 2>&1; rc=$?
expect_rc "build.sh consumes the plan provision.sh emitted" 0 "$rc"
expect_contains "the round trip builds the rootfs" /tmp/rt-log.$$ 'rootfs'
# And the manifest it produces is the one provision.sh reads back.
"$PROV" --plan-only --probe-file /tmp/pr-ok.$$ --manifest "$rtout/manifest.json" \
    > /tmp/rt-plan2.$$ 2>/dev/null
expect_json "the manifest build.sh wrote is readable by provision.sh" /tmp/rt-plan2.$$
expect_absent "a freshly built target is no longer requested" /tmp/rt-plan2.$$ '"rootfs"'
rm -rf "$rtsrc" "$rtout" /tmp/rt-log.$$ /tmp/rt-b.$$ /tmp/rt-plan2.$$

rm -f /tmp/pr-ok.$$ /tmp/pl-ok.$$ /tmp/pr-part.$$ /tmp/pl-part.$$ /tmp/m-empty.$$ /tmp/pl-empty.$$

expect_pred() {   # expect_pred <name> <skip|run> <predicate> <args...>
    local name=$1 want=$2; shift 2
    local got=run
    "$@" && got=skip
    if [ "$got" = "$want" ]; then
        echo "  PASS  $name"; pass=$((pass+1))
    else
        echo "  FAIL  $name: expected to $want, got $got"; fail=$((fail+1))
    fi
}

. "$ROOT/lib/phases.sh"
MAN="$ROOT/tests/fixtures/manifest.json"   # boot.img: sha256 aaaa, bytes 1

# skip_boot hashes the first N bytes of the partition, N being the image size
# from the manifest -- the partition is larger than the image, so a whole
# partition hash could never match.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\n' > /tmp/pr-boot.$$
FAKE_SSH_OUT='aaaa  -' expect_pred "boot skips when the device already has that image" \
    skip skip_boot /tmp/pr-boot.$$ "$MAN"
FAKE_SSH_OUT='bbbb  -' expect_pred "boot runs when the device has something else" \
    run skip_boot /tmp/pr-boot.$$ "$MAN"
# An unreachable device is not evidence that the flash can be skipped.
expect_pred "boot runs when the device cannot be read" \
    run skip_boot /tmp/pr-boot.$$ "$MAN"
printf 'state=fastboot\nprobe_complete=no\n' > /tmp/pr-noslot.$$
expect_pred "boot runs when the slot is unknown" \
    run skip_boot /tmp/pr-noslot.$$ "$MAN"

# skip_edl inverts the usual polarity: only positive evidence that linuxroot is
# missing may trigger a repartition, because running it erases the device.
for state in yes no unknown; do
    printf 'state=droidian\nprobe_complete=yes\nhas_linuxroot=%s\n' "$state" > /tmp/pr-edl.$$
    case "$state" in
        no) expect_pred "edl runs only when linuxroot is positively absent" \
                run skip_edl /tmp/pr-edl.$$ "$MAN" ;;
        *)  expect_pred "edl skips when linuxroot is $state" \
                skip skip_edl /tmp/pr-edl.$$ "$MAN" ;;
    esac
done
rm -f /tmp/pr-boot.$$ /tmp/pr-noslot.$$ /tmp/pr-edl.$$

# skip_activate: activation is `fastboot reboot`, so a phone that answered the
# probe over ssh as Droidian was never in fastboot and has nothing to activate.
for state in droidian fastboot edl off unknown; do
    printf 'state=%s\nprobe_complete=yes\n' "$state" > /tmp/pr-act.$$
    case "$state" in
        droidian) expect_pred "activate skips when Droidian is already running" \
                      skip skip_activate /tmp/pr-act.$$ "$MAN" ;;
        *)        expect_pred "activate runs from $state" \
                      run skip_activate /tmp/pr-act.$$ "$MAN" ;;
    esac
done
rm -f /tmp/pr-act.$$

# Skip detection: data phase skips when package versions match. One build target
# ships several packages -- adaptation alone ships three -- so every .deb in the
# manifest has to be accounted for, not one representative per target.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=linuxroot\npkg_droidian-camera=1.0.0\npkg_adaptation-oneplus-fajita=1.0.0\npkg_halium-hostdev-perms=1.0.0\n' > /tmp/pr-data-match.$$
if skip_data /tmp/pr-data-match.$$ "$ROOT/tests/fixtures/manifest.json"; then
    echo "  PASS  data phase skips when versions match"; pass=$((pass+1))
else
    echo "  FAIL  data phase skips when versions match"; fail=$((fail+1))
fi

# Skip detection: data phase runs when package version differs
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=linuxroot\npkg_droidian-camera=2.0.0\npkg_adaptation-oneplus-fajita=1.0.0\n' > /tmp/pr-data-diff.$$
if skip_data /tmp/pr-data-diff.$$ "$ROOT/tests/fixtures/manifest.json"; then
    echo "  FAIL  data phase runs when version differs"; fail=$((fail+1))
else
    echo "  PASS  data phase runs when version differs"; pass=$((pass+1))
fi

# A second package from the same target, missing on the device, must still stop
# the skip: checking one .deb per target would have called this a match.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=linuxroot\npkg_droidian-camera=1.0.0\npkg_adaptation-oneplus-fajita=1.0.0\n' > /tmp/pr-data-part.$$
expect_pred "data runs when a sibling package of the same target is absent" \
    run skip_data /tmp/pr-data-part.$$ "$ROOT/tests/fixtures/manifest.json"

rm -f /tmp/pr-boot-match.$$ /tmp/pr-boot-diff.$$ /tmp/pr-data-match.$$ /tmp/pr-data-diff.$$ /tmp/pr-data-part.$$

# Flash phases: boot phase flashes boot and vbmeta
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nboot_sha=bbbb\n' > /tmp/pr-flash-boot.$$
mkdir -p /tmp/artifacts-test/droidian/out/images
touch /tmp/artifacts-test/droidian/out/images/boot.img
touch /tmp/artifacts-test/droidian/out/images/vbmeta.img
timeout 30 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-flash-boot.$$ --phase boot > /tmp/p-flash-boot.$$ 2>&1; rc=$?
expect_rc "boot phase exits 0" 0 "$rc"
expect_contains "boot phase flashes boot" /tmp/p-flash-boot.$$ 'boot: flashing'
rm -rf /tmp/artifacts-test /tmp/pr-flash-boot.$$ /tmp/p-flash-boot.$$

# Flash phases: data phase flashes linuxroot
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\npkg_droidian-camera=2.0.0\npkg_adaptation-oneplus-fajita=1.0.0\n' > /tmp/pr-flash-data.$$
mkdir -p /tmp/artifacts-test/droidian
touch /tmp/artifacts-test/droidian/linuxroot.simg
timeout 10 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-flash-data.$$ --manifest "$ROOT/tests/fixtures/manifest.json" --phase data > /tmp/p-flash-data.$$ 2>/tmp/p-flash-data-err.$$; rc=$?
expect_rc "data phase exits 0" 0 "$rc"
expect_contains "data phase flashes linuxroot" /tmp/p-flash-data.$$ 'data: installing rootfs'
rm -rf /tmp/artifacts-test /tmp/pr-flash-data.$$ /tmp/p-flash-data.$$

# Matching package versions are not a reason to skip while the install is
# still on userdata: the whole point of the data phase is to move it.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=userdata\npkg_droidian-camera=2.0.0\npkg_adaptation-oneplus-fajita=1.0.0\n' > /tmp/pr-move.$$
mkdir -p /tmp/artifacts-test/droidian
touch /tmp/artifacts-test/droidian/linuxroot.simg
timeout 10 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-move.$$ --manifest "$ROOT/tests/fixtures/manifest.json" --phase data > /tmp/p-move.$$ 2>&1; rc=$?
expect_contains "data runs when the install is still on userdata" /tmp/p-move.$$ 'data: installing rootfs'
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=linuxroot\npkg_droidian-camera=1.0.0\npkg_adaptation-oneplus-fajita=1.0.0\npkg_halium-hostdev-perms=1.0.0\n' > /tmp/pr-stay.$$
timeout 10 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-stay.$$ --manifest "$ROOT/tests/fixtures/manifest.json" --phase data > /tmp/p-stay.$$ 2>&1; rc=$?
expect_contains "data skips once the install is on linuxroot" /tmp/p-stay.$$ 'data: skipped'
# FORCE=1 rebuilt the image, so it must also be flashed: the device's package
# versions cannot tell a rebuilt rootfs from the one it has. edl stays gated
# on evidence; FORCE never rewrites the GPT.
FORCE=1 timeout 10 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-stay.$$ --manifest "$ROOT/tests/fixtures/manifest.json" --phase data > /tmp/p-force.$$ 2>&1; rc=$?
expect_contains "FORCE=1 flashes data even when versions match" /tmp/p-force.$$ 'data: installing rootfs'
: > "$HW_LOG"
FORCE=1 timeout 10 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-stay.$$ --manifest "$ROOT/tests/fixtures/manifest.json" --phase edl > /tmp/p-force-edl.$$ 2>&1; rc=$?
expect_absent "FORCE=1 never repartitions on its own" "$HW_LOG" 'repartition-dualboot'
rm -f /tmp/p-force.$$ /tmp/p-force-edl.$$
rm -rf /tmp/artifacts-test /tmp/pr-move.$$ /tmp/p-move.$$ /tmp/pr-stay.$$ /tmp/p-stay.$$

# --artifacts mode accepts a path and runs all phases
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nboot_sha=bbbb\npkg_droidian-camera=2.0.0\npkg_adaptation-oneplus-fajita=1.0.0\n' > /tmp/pr-ok.$$
mkdir -p /tmp/artifacts-test/droidian/out/images
touch /tmp/artifacts-test/droidian/out/images/boot.img
touch /tmp/artifacts-test/droidian/out/images/vbmeta.img
touch /tmp/artifacts-test/droidian/linuxroot.simg
: > "$HW_LOG"
FAKE_SSH_FIXTURE="$HERE/fixtures/verify-healthy.txt" \
timeout 30 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-ok.$$ > /tmp/p-art.$$ 2>&1; rc=$?
expect_rc "--artifacts mode exits 0" 0 "$rc"
# rc=124 would mean a phase blocked waiting for a device. Bounded so that a
# regression fails the suite instead of hanging it.
expect_contains "the boot flash names the slot" "$HW_LOG" 'fastboot flash boot_a'
expect_contains "the linuxroot flash is issued" "$HW_LOG" 'fastboot flash linuxroot'
expect_absent   "userdata is never flashed"       "$HW_LOG" 'fastboot flash userdata'
expect_contains "--artifacts echoes the path" /tmp/p-art.$$ '/tmp/artifacts-test'
expect_contains "edl phase runs" /tmp/p-art.$$ 'edl:'
expect_contains "boot phase runs" /tmp/p-art.$$ 'boot:'
expect_contains "data phase runs" /tmp/p-art.$$ 'data:'
expect_contains "activate phase runs" /tmp/p-art.$$ 'activate:'
expect_contains "verify phase runs" /tmp/p-art.$$ 'verify:'
# Reachability is not an install: the phase must run the real checks and
# report their verdict, not announce success after an echo.
expect_contains "verify asserts the install, not a ping" /tmp/p-art.$$ 'ALL PASS'

# The boot and data phases speak fastboot, which the phone answers only in the
# bootloader. It has to be put there before the first write and taken back out
# afterwards -- the probe that said "droidian" was read before any of this.
expect_contains "the phone is put in the bootloader" "$HW_LOG" 'device-goto fastboot'
python3 - "$HW_LOG" > /tmp/p-gord.$$ <<'PYEOF'
import sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
def idx(prefix):
    for i, l in enumerate(lines):
        if l.startswith(prefix):
            return i
    return -1
goto, flash = idx("device-goto fastboot"), idx("fastboot flash")
print("goto_before_write=" + str(goto >= 0 and flash >= 0 and goto < flash))
PYEOF
expect_contains "before the first write, not after" /tmp/p-gord.$$ 'goto_before_write=True'
expect_contains "and taken back out of it"          /tmp/p-art.$$ 'activate: rebooting out of the bootloader'
expect_contains "leaving the bootloader is waited for" "$HW_LOG" 'device-goto droidian'

# A phone that will not enter the bootloader must stop the run there, with
# nothing flashed, rather than firing fastboot at a device that cannot hear it.
: > "$HW_LOG"
FAKE_GOTO_RC=1 FAKE_SSH_FIXTURE="$HERE/fixtures/verify-healthy.txt" \
    timeout 30 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-ok.$$ \
    --phase boot > /tmp/p-nogoto.$$ 2>&1; rc=$?
expect_rc "a phone that will not enter the bootloader fails the run" 1 "$rc"
expect_absent "and nothing is flashed at it" "$HW_LOG" 'fastboot flash'

# fastboot not answering a reboot is not the same as the phone not rebooting.
# A real run sat on that unanswered read for six minutes; what settles it is the
# state the phone is in, so the run must bound the wait and then go and look.
: > "$HW_LOG"
FAKE_FASTBOOT_HANG=reboot FAKE_SSH_FIXTURE="$HERE/fixtures/verify-healthy.txt" \
    ACTIVATE_TIMEOUT=2 VERIFY_ATTEMPTS=1 VERIFY_DELAY=0 \
    timeout 60 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-ok.$$ \
    > /tmp/p-hang.$$ 2>&1; rc=$?
expect_rc "an unanswered reboot does not hang the run" 0 "$rc"
expect_contains "it says fastboot went quiet" /tmp/p-hang.$$ 'did not confirm the reboot'
expect_contains "and confirms from the phone's state instead" "$HW_LOG" 'device-goto droidian'

rm -f /tmp/p-gord.$$ /tmp/p-nogoto.$$ /tmp/p-hang.$$

# An unreachable device is a failed verification, not a warning. Exiting 0 here
# reported a successful provision of a phone that never came back.
: > "$HW_LOG"
VERIFY_ATTEMPTS=1 VERIFY_DELAY=0 timeout 30 "$PROV" --yes --artifacts /tmp/artifacts-test \
    --probe-file /tmp/pr-ok.$$ --phase verify > /tmp/p-unreach.$$ 2>&1; rc=$?
expect_rc "an unreachable device fails verify" 1 "$rc"
expect_contains "and says nothing was verified" /tmp/p-unreach.$$ 'nothing was verified'

# Reachable but wrong must fail too. This is the case that used to answer an
# echo and call the install successful.
FAKE_SSH_FIXTURE="$HERE/fixtures/probe-droidian.txt" VERIFY_ATTEMPTS=1 VERIFY_DELAY=0 \
    timeout 30 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-ok.$$ \
    --phase verify > /tmp/p-bad.$$ 2>&1; rc=$?
expect_rc "a reachable but incorrect install fails verify" 1 "$rc"
expect_contains "and reports the failing checks" /tmp/p-bad.$$ 'FAILURES'

rm -rf /tmp/artifacts-test /tmp/p-art.$$ /tmp/p-unreach.$$ /tmp/p-bad.$$

# --phase flag runs only that phase
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nboot_sha=bbbb\n' > /tmp/pr-phase.$$
mkdir -p /tmp/artifacts-test/droidian/out/images
touch /tmp/artifacts-test/droidian/out/images/boot.img
touch /tmp/artifacts-test/droidian/out/images/vbmeta.img
timeout 30 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-phase.$$ --phase boot > /tmp/p-phase.$$ 2>&1; rc=$?
expect_rc "--phase boot exits 0" 0 "$rc"
expect_contains "only boot phase runs" /tmp/p-phase.$$ 'boot:'
expect_absent "edl phase is skipped" /tmp/p-phase.$$ 'edl:'
expect_absent "data phase is skipped" /tmp/p-phase.$$ 'data:'
rm -rf /tmp/artifacts-test /tmp/p-phase.$$

# The header documents PHASE as an environment variable, so it has to be one.
# It was initialised to "" unconditionally, which quietly ate the documented
# form and ran every phase instead of the one asked for.
mkdir -p /tmp/artifacts-test/droidian/out/images
touch /tmp/artifacts-test/droidian/out/images/boot.img
touch /tmp/artifacts-test/droidian/out/images/vbmeta.img
PHASE=boot timeout 30 "$PROV" --yes --artifacts /tmp/artifacts-test \
    --probe-file /tmp/pr-phase.$$ > /tmp/p-envphase.$$ 2>&1; rc=$?
expect_rc "PHASE from the environment exits 0" 0 "$rc"
expect_contains "PHASE from the environment selects the phase" /tmp/p-envphase.$$ 'boot:'
expect_absent  "and runs no other"                             /tmp/p-envphase.$$ 'data:'
rm -rf /tmp/artifacts-test /tmp/pr-phase.$$ /tmp/p-envphase.$$

# Destructive work must be explained and confirmed. has_linuxroot=no is the one
# state that authorises a repartition, so it is the state to test refusal in.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nhas_linuxroot=no\n' > /tmp/pr-des.$$
mkdir -p /tmp/artifacts-test/droidian/out/images /tmp/artifacts-test/msm
touch /tmp/artifacts-test/droidian/out/images/boot.img
touch /tmp/artifacts-test/droidian/out/images/vbmeta.img
touch /tmp/artifacts-test/droidian/linuxroot.simg
touch /tmp/artifacts-test/msm/gpt_main0.bin

: > "$HW_LOG"
timeout 30 "$PROV" --artifacts /tmp/artifacts-test --probe-file /tmp/pr-des.$$ \
    < /dev/null > /tmp/p-des.$$ 2>&1; rc=$?
expect_rc "an unconfirmed destructive run refuses" 1 "$rc"
expect_contains "the refusal explains how to proceed" /tmp/p-des.$$ '--yes'
expect_contains "the erase is spelled out before asking" /tmp/p-des.$$ 'ERASES EVERY PARTITION'
# The point of the refusal: nothing was written.
expect_absent "a refused run repartitions nothing" "$HW_LOG" 'repartition-dualboot'
expect_absent "a refused run flashes nothing"      "$HW_LOG" 'fastboot flash'

: > "$HW_LOG"
# The device never answers here, so cap the verify wait; this case is about
# consent, not about how long a real phone takes to come back.
VERIFY_ATTEMPTS=1 VERIFY_DELAY=0 FAKE_SSH_FIXTURE="$HERE/fixtures/verify-healthy.txt" \
timeout 30 "$PROV" --artifacts /tmp/artifacts-test --probe-file /tmp/pr-des.$$ \
    --yes < /dev/null > /tmp/p-yes.$$ 2>&1; rc=$?
expect_rc "--yes proceeds without a terminal" 0 "$rc"
expect_contains "the confirmed run repartitions" "$HW_LOG" 'repartition-dualboot'

# A run with nothing destructive to do must not ask at all.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\nhas_linuxroot=yes\npkg_droidian-camera=1.0.0\npkg_adaptation-oneplus-fajita=1.0.0\n' > /tmp/pr-quiet.$$
: > "$HW_LOG"
FAKE_SSH_OUT='aaaa  -' timeout 30 "$PROV" --artifacts /tmp/artifacts-test \
    --probe-file /tmp/pr-quiet.$$ --manifest "$ROOT/tests/fixtures/manifest.json" \
    --phase boot < /dev/null > /tmp/p-quiet.$$ 2>&1; rc=$?
expect_rc "a run with nothing to write does not ask" 0 "$rc"
expect_absent "no confirmation is demanded when nothing is destroyed" /tmp/p-quiet.$$ 'Type YES'
rm -rf /tmp/artifacts-test /tmp/pr-des.$$ /tmp/p-des.$$ /tmp/p-yes.$$ \
       /tmp/pr-quiet.$$ /tmp/p-quiet.$$

# Remote builds. ssh and scp go through a command seam, so the whole transport
# is exercised without a second machine -- including the two ways the worker is
# put on the right commit, which is the part that would otherwise only ever be
# tested by being wrong on taichi.
rlog=/tmp/rlog.$$
cat > /tmp/fake-ssh.$$ <<FS
#!/usr/bin/env bash
echo "SSH \$*" >> $rlog
# A request to compress an artifact is answered with real compressed bytes, so
# the receiving end's decompress-and-verify is exercised rather than skipped.
case "\$*" in *zstd*) printf 'sparse rootfs fixture\n' | zstd -c ;; esac
exit 0
FS
cat > /tmp/fake-scp.$$ <<FS
#!/usr/bin/env bash
echo "SCP \$*" >> $rlog
exit 0
FS
chmod +x /tmp/fake-ssh.$$ /tmp/fake-scp.$$

printf '{"build":["adaptation"],"force":false}\n' > /tmp/rp.$$
# Fetching writes real files. Point it at a temp tree and give it a throwaway
# copy of the manifest, so exercising a fetch cannot land on the working tree.
fetchroot=/tmp/fetch.$$
rm -rf "$fetchroot"; mkdir -p "$fetchroot"
rman=/tmp/rman.$$
cp "$ROOT/tests/fixtures/manifest.json" "$rman"
export FETCH_ROOT="$fetchroot"
: > "$rlog"; : > "$HW_LOG"
PROV_SSH=/tmp/fake-ssh.$$ PROV_SCP=/tmp/fake-scp.$$ PROV_PUBLISHED=1 \
    timeout 30 "$PROV" --remote-build taichi --plan-file /tmp/rp.$$ \
    --manifest "$rman" > /tmp/rb.$$ 2>&1; rc=$?
expect_rc "remote build succeeds"                 0 "$rc"
expect_contains "the plan is copied over"         "$rlog" 'SCP'
expect_contains "the worker is reset to a commit" "$rlog" 'reset -q --hard'
expect_contains "prerequisites are checked first" "$rlog" 'check-env.sh build'
expect_contains "build.sh runs with the plan"     "$rlog" 'build.sh --plan'
expect_contains "artifacts are fetched back"      "$rlog" 'manifest.json'
# A remote build touches no phone, so it must not require one to be attached.
expect_absent  "a supplied plan probes no device" "$HW_LOG" 'device-ssh'

# The rootfs moves compressed and sparse -- a seventh of the raw bytes -- and
# never as a plain copy of the raw image.
expect_contains "the rootfs is fetched compressed"    "$rlog" 'zstd -c'
expect_contains "and in its sparse form"              "$rlog" 'linuxroot.simg'
expect_absent  "the raw image is never copied over"   "$rlog" 'linuxroot.img'

# A transfer that arrives with the wrong bytes must never reach the phone. This
# is the one artifact big enough that a silent truncation is plausible, and a
# truncated rootfs is a phone that will not boot and does not say why.
cat > /tmp/fake-ssh.$$ <<FS
#!/usr/bin/env bash
echo "SSH \$*" >> $rlog
case "\$*" in *zstd*) printf 'not the rootfs you built\n' | zstd -c ;; esac
exit 0
FS
chmod +x /tmp/fake-ssh.$$
: > "$HW_LOG"
PROV_SSH=/tmp/fake-ssh.$$ PROV_SCP=/tmp/fake-scp.$$ PROV_PUBLISHED=1 \
    timeout 30 "$PROV" --remote-build taichi --plan-file /tmp/rp.$$ \
    --manifest "$rman" > /tmp/rb3.$$ 2>&1; rc=$?
expect_rc "a corrupt rootfs transfer fails the run" 1 "$rc"
expect_contains "and says the hash disagreed" /tmp/rb3.$$ 'arrived corrupt'
expect_absent  "and nothing is flashed"       "$HW_LOG" 'fastboot flash'
[ -e "$fetchroot/droidian/linuxroot.simg.part" ] \
    && { echo "  FAIL  a failed transfer leaves no .part behind"; fail=$((fail+1)); } \
    || { echo "  PASS  a failed transfer leaves no .part behind"; pass=$((pass+1)); }
rm -f /tmp/rb3.$$

# A published commit must go over origin, not by bundle: the bundle path exists
# only for work deliberately kept unpushed.
expect_contains "a published commit fetches from origin" "$rlog" 'git fetch -q origin'
expect_absent  "a published commit sends no bundle"      "$rlog" 'op6t.bundle'

: > "$rlog"
PROV_SSH=/tmp/fake-ssh.$$ PROV_SCP=/tmp/fake-scp.$$ PROV_PUBLISHED=0 \
    timeout 30 "$PROV" --remote-build taichi --plan-file /tmp/rp.$$ \
    --manifest "$rman" > /dev/null 2>&1
expect_contains "unpublished WIP goes by bundle"  "$rlog" 'op6t.bundle'
expect_absent  "unpublished WIP does not ask origin for a commit it lacks" "$rlog" 'git fetch -q origin'

# A worker that fails must fail the run, not silently continue to flashing.
cat > /tmp/fake-ssh.$$ <<'FS'
#!/usr/bin/env bash
exit 3
FS
chmod +x /tmp/fake-ssh.$$
PROV_SSH=/tmp/fake-ssh.$$ PROV_SCP=/tmp/fake-scp.$$ PROV_PUBLISHED=1 \
    timeout 30 "$PROV" --remote-build taichi --plan-file /tmp/rp.$$ \
    --manifest "$rman" > /tmp/rb2.$$ 2>&1
expect_rc "a failing worker fails the run" 1 "$?"
expect_contains "and says which host"      /tmp/rb2.$$ 'taichi'
rm -f /tmp/rb.$$ /tmp/rb2.$$

# Full mode: the default path, with no flag naming what to do. It probes, builds
# on the worker when BUILD_HOST is set, then runs the phases.
cat > /tmp/fake-ssh.$$ <<FS
#!/usr/bin/env bash
echo "SSH \$*" >> $rlog
exit 0
FS
chmod +x /tmp/fake-ssh.$$
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\nslot=a\n' > /tmp/pr-fm.$$
: > "$rlog"; : > "$HW_LOG"
BUILD_HOST=taichi PROV_SSH=/tmp/fake-ssh.$$ PROV_SCP=/tmp/fake-scp.$$ PROV_PUBLISHED=1 \
    VERIFY_ATTEMPTS=1 VERIFY_DELAY=0 FAKE_SSH_FIXTURE="$HERE/fixtures/verify-healthy.txt" \
    timeout 60 "$PROV" --probe-file /tmp/pr-fm.$$ --phase verify \
    --manifest "$ROOT/tests/fixtures/manifest.json" > /tmp/fm.$$ 2>&1; rc=$?
expect_rc "full mode needs no flag to say what to do" 0 "$rc"
expect_contains "BUILD_HOST builds on the worker first" "$rlog" 'build.sh --plan'
expect_contains "and then runs the phases"              /tmp/fm.$$ 'verify:'

# A manifest is the unit of trust every phase decides from. Without one there is
# nothing to compare the device against, so this must stop before any phase
# rather than flash whatever happens to be lying around.
: > "$HW_LOG"
MANIFEST=/tmp/does-not-exist.json timeout 30 "$PROV" --probe-file /tmp/pr-fm.$$ \
    < /dev/null > /tmp/nm.$$ 2>&1; rc=$?
expect_rc "a missing manifest stops the run" 1 "$rc"
expect_contains "and says why"               /tmp/nm.$$ 'no manifest'
expect_contains "and names the file it wanted" /tmp/nm.$$ '/tmp/does-not-exist.json'
expect_absent  "and flashes nothing"         "$HW_LOG" 'fastboot flash'
unset FETCH_ROOT
rm -rf "$fetchroot" "$rman"
rm -f "$rlog" /tmp/fake-ssh.$$ /tmp/fake-scp.$$ /tmp/rp.$$ /tmp/pr-fm.$$ /tmp/fm.$$ /tmp/nm.$$

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
expect_contains "the running slot is read"  /tmp/p-dro.$$ 'slot=a'
expect_contains "linuxroot is detected"     /tmp/p-dro.$$ 'has_linuxroot=yes'
expect_contains "the data partition is named" /tmp/p-dro.$$ 'data_part=userdata'

# A probe whose datapart section is missing must say unknown, not guess.
sed '/^--- datapart$/,/^--- partlabels$/{/^--- partlabels$/!d}' \
    "$ROOT/tests/fixtures/probe-droidian.txt" > /tmp/f-nodp.$$
PROBE_STATE=droidian PROBE_SSH_FIXTURE=/tmp/f-nodp.$$ \
    bash "$PROBE" probe_all > /tmp/p-nodp.$$ 2>&1
expect_contains "an unreadable data partition is unknown" /tmp/p-nodp.$$ 'data_part=unknown'
rm -f /tmp/f-nodp.$$ /tmp/p-nodp.$$

# A device that listed its partitions without linuxroot is the only state that
# may authorise a repartition, so it must be told apart from a failed listing.
sed '/^linuxroot$/d' "$ROOT/tests/fixtures/probe-droidian.txt" > /tmp/f-nolr.$$
PROBE_STATE=droidian PROBE_SSH_FIXTURE=/tmp/f-nolr.$$ \
    bash "$PROBE" probe_all > /tmp/p-nolr.$$ 2>&1
expect_contains "an absent linuxroot is reported as absent" /tmp/p-nolr.$$ 'has_linuxroot=no'
sed '/^--- partlabels$/,$d' "$ROOT/tests/fixtures/probe-droidian.txt" > /tmp/f-nolist.$$
PROBE_STATE=droidian PROBE_SSH_FIXTURE=/tmp/f-nolist.$$ \
    bash "$PROBE" probe_all > /tmp/p-nolist.$$ 2>&1
expect_contains "a failed listing is not an absent partition" /tmp/p-nolist.$$ 'has_linuxroot=unknown'
rm -f /tmp/f-nolr.$$ /tmp/p-nolr.$$ /tmp/f-nolist.$$ /tmp/p-nolist.$$

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

# Nothing in the working tree may have appeared, vanished or changed status.
tree_after=/tmp/tree-after.$$
git -C "$ROOT" status --porcelain --ignored > "$tree_after" 2>/dev/null || : > "$tree_after"
dirty=$(diff "$TREE_BEFORE" "$tree_after" || true)
rm -f "$TREE_BEFORE" "$tree_after"
if [ -z "$dirty" ]; then
    echo "  PASS  the suite writes nothing into the working tree"; pass=$((pass+1))
else
    echo "  FAIL  the suite wrote into the working tree:"; echo "$dirty" | sed 's/^/        /'
    fail=$((fail+1))
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
