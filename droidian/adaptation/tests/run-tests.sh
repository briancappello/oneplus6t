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
# Group and user resolution is also a seam: this host has no "system" or
# "radio" group, so falling through to the real getent would make the results
# depend on the machine running the tests.
export HHP_GROUP_EXISTS_CMD="grep -qxF \"\$1\" $FIX/groups.txt"
export HHP_USER_EXISTS_CMD="grep -qxF \"\$1\" $FIX/users.txt"

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
    'KERNEL=="renderD128", OWNER="root", GROUP="android_graphics", MODE="0666"'
expect_absent "KERNEL is never a path" /tmp/hhp-out.$$ 'KERNEL=="dri/'

rm -f /tmp/hhp-out.$$

# ---------------------------------------------------------------- Task 2b
# 13 of the 19 groups named in this device's ueventd.rc do not exist under that
# name on Droidian; 11 exist as android_<name>. udev silently drops a GROUP= it
# cannot resolve while still applying the mode, so resolution is not cosmetic.
"$GEN" > /tmp/hhp-map.$$ 2>/tmp/hhp-err.$$

expect_contains "graphics maps to android_graphics" /tmp/hhp-map.$$ \
    'KERNEL=="renderD128", OWNER="root", GROUP="android_graphics", MODE="0666"'
expect_contains "drmrpc maps to android_drmrpc" /tmp/hhp-map.$$ \
    'KERNEL=="qseecom", OWNER="system", GROUP="android_drmrpc", MODE="0660"'
expect_absent "unresolvable group emits nothing" /tmp/hhp-map.$$ 'byte-cntr'
expect_absent "unresolvable owner emits nothing" /tmp/hhp-map.$$ 'rmnet_ctrl'
expect_contains "the skip is logged, not silent" /tmp/hhp-err.$$ \
    'skipping /dev/byte-cntr: no group oem_2902 or android_oem_2902'
# The vendor declaration of diag (system:oem_2901) is unusable, so the base
# file's declaration applies rather than the node being dropped.
expect_contains "falls back to the base declaration for diag" /tmp/hhp-map.$$ \
    'KERNEL=="diag", OWNER="radio", GROUP="radio"'
rm -f /tmp/hhp-map.$$ /tmp/hhp-err.$$

# ---------------------------------------------------------------- Task 3
export HHP_POLICY_DIRS="$ADAPT/halium-hostdev-perms/usr/lib/halium-hostdev-perms/policy.d"
"$GEN" > /tmp/hhp-pol.$$ 2>/dev/null
expect_absent "diag denied by default"         /tmp/hhp-pol.$$ 'KERNEL=="diag"'
expect_absent "ramdump_* denied by default"    /tmp/hhp-pol.$$ 'ramdump_modem'
expect_absent "subsys_* denied by default"     /tmp/hhp-pol.$$ 'subsys_modem'
expect_contains "qseecom still fixed"          /tmp/hhp-pol.$$ 'KERNEL=="qseecom"'

# A local allow fragment overrides the shipped deny.
tmp_pol=$(mktemp -d)
cp "$ADAPT/halium-hostdev-perms/usr/lib/halium-hostdev-perms/policy.d/10-defaults.conf" "$tmp_pol/"
printf 'allow /dev/diag\n' > "$tmp_pol/90-local.conf"
HHP_POLICY_DIRS="$tmp_pol" "$GEN" > /tmp/hhp-allow.$$ 2>/dev/null
expect_contains "local allow re-enables diag" /tmp/hhp-allow.$$ 'KERNEL=="diag"'

# allow must NOT override the reachability invariant.
printf 'allow /dev/input/event0\n' >> "$tmp_pol/90-local.conf"
HHP_POLICY_DIRS="$tmp_pol" "$GEN" > /tmp/hhp-allow2.$$ 2>/dev/null
expect_absent "allow cannot revert a reachable node" /tmp/hhp-allow2.$$ 'event0'
rm -rf "$tmp_pol" /tmp/hhp-pol.$$ /tmp/hhp-allow.$$ /tmp/hhp-allow2.$$

# Precedence is by BASENAME across all dirs, not by path. Dir "a" is searched
# first (it stands for /usr/lib) and holds the LATER basename, so sorting the
# merged list by path instead would apply 50-mid before 10-early and invert the
# result. Basename order is 10-early (deny) then 50-mid (allow) -> allow wins.
tmp_root=$(mktemp -d); mkdir -p "$tmp_root/a" "$tmp_root/b"
printf 'allow /dev/diag\n' > "$tmp_root/a/50-mid.conf"
printf 'deny /dev/diag\n'  > "$tmp_root/b/10-early.conf"
HHP_POLICY_DIRS="$tmp_root/a $tmp_root/b" "$GEN" > /tmp/hhp-ord.$$ 2>/dev/null
expect_contains "precedence is by basename, not by path" /tmp/hhp-ord.$$ 'KERNEL=="diag"'

# A same-named file in the later dir masks the earlier one, systemd-style.
printf 'deny /dev/qseecom\n'  > "$tmp_root/a/20-mask.conf"
printf 'allow /dev/qseecom\n' > "$tmp_root/b/20-mask.conf"
HHP_POLICY_DIRS="$tmp_root/a $tmp_root/b" "$GEN" > /tmp/hhp-mask.$$ 2>/dev/null
expect_contains "same-named file in the later dir masks the earlier" \
    /tmp/hhp-mask.$$ 'KERNEL=="qseecom"'
rm -rf "$tmp_root" /tmp/hhp-ord.$$ /tmp/hhp-mask.$$

# ---------------------------------------------------------------- Task 4
# udev silently discards a rule with a trailing inline comment, and
# "udevadm control --reload-rules" reports nothing. Only udevadm verify
# catches it. This cost a debugging cycle already.
#
# --resolve-names=never because verify resolves users and groups against
# whichever host runs it. The names here are the DEVICE's (system, radio,
# android_graphics) and do not exist on a build host, so resolving would fail
# everywhere except the phone. Resolution is the device's job at boot.
if command -v udevadm >/dev/null 2>&1 && udevadm verify --help >/dev/null 2>&1; then
    "$GEN" > /tmp/hhp-syn.$$ 2>/dev/null
    if udevadm verify --resolve-names=never /tmp/hhp-syn.$$ >/tmp/hhp-verify.$$ 2>&1; then
        echo "  PASS  udevadm verify accepts generated rules"; pass=$((pass+1))
    else
        echo "  FAIL  udevadm verify rejected the rules"; sed 's/^/        /' /tmp/hhp-verify.$$; fail=$((fail+1))
    fi

    # A check that cannot fail is not a check. Prove verify rejects the exact
    # defect this guards: a rule with a trailing inline comment.
    sed '$a ACTION=="add", KERNEL=="zz", OWNER="root", GROUP="root", MODE="0666" # bad' \
        /tmp/hhp-syn.$$ > /tmp/hhp-bad.$$
    if udevadm verify --resolve-names=never /tmp/hhp-bad.$$ >/dev/null 2>&1; then
        echo "  FAIL  verify accepted a trailing inline comment"; fail=$((fail+1))
    else
        echo "  PASS  verify rejects a trailing inline comment"; pass=$((pass+1))
    fi
    rm -f /tmp/hhp-syn.$$ /tmp/hhp-verify.$$ /tmp/hhp-bad.$$
else
    echo "  SKIP  udevadm verify not available"
fi

# ---------------------------------------------------------------- Task 6
# The kernel version gate decides whether polkit gets fixed at all. Judging
# 4.9 as "has pidfd" would leave authentication silently broken, which presents
# as a rejected password. HOKC_HELPER points at a missing file so the script
# stops right after the gate without needing root or dpkg-statoverride.
APPLY="$ADAPT/halium-oldkernel-compat/usr/lib/halium-oldkernel-compat/apply"
for c in "4.9-113-oneplus-fajita:fix" "5.0.9:fix" "5.1.0:skip" "6.1.0-13-arm64:skip"; do
    kv=${c%%:*}; want=${c##*:}
    got=$(HOKC_UNAME="echo $kv" HOKC_HELPER=/nonexistent "$APPLY" 2>&1)
    ok=0
    case "$want" in
        fix)  case "$got" in *absent*)      ok=1 ;; esac ;;
        skip) case "$got" in *"has pidfd"*) ok=1 ;; esac ;;
    esac
    if [ "$ok" = 1 ]; then
        echo "  PASS  kernel $kv -> $want"; pass=$((pass+1))
    else
        echo "  FAIL  kernel $kv -> expected $want, got: $got"; fail=$((fail+1))
    fi
done

# ---------------------------------------------------------------- Task 7
# Both packages drop policy into the same directory. Check the device fragment
# composes with the generic defaults instead of disturbing them.
HHP_POLICY_DIRS="$ADAPT/halium-hostdev-perms/usr/lib/halium-hostdev-perms/policy.d $ADAPT/adaptation-oneplus-fajita/usr/lib/halium-hostdev-perms/policy.d" \
    "$GEN" > /tmp/hhp-faj.$$ 2>/dev/null
expect_contains "fajita fragment keeps hwbinder fixed" /tmp/hhp-faj.$$ 'KERNEL=="hwbinder"'
expect_absent  "fajita fragment keeps diag denied"    /tmp/hhp-faj.$$ 'KERNEL=="diag"'
rm -f /tmp/hhp-faj.$$

# The clock floor must only ever move time FORWARD. Moving it backward would
# fight NTP; not moving it at all leaves 1970, which breaks TLS, apt, polkit's
# password-age check and journald retention.
CF="$ADAPT/adaptation-oneplus-fajita/usr/lib/adaptation-oneplus-fajita/clock-floor"
cf_stamp=$(mktemp); touch -d "@1700000000" "$cf_stamp"
cf_set=$(mktemp); cf_log=$(mktemp)
# The script sends the set command's stdout to /dev/null, so the fake must
# record a SIDE EFFECT. Probing its stdout would make every "was not called"
# case pass vacuously.
printf '#!/bin/sh\necho "SET $1" >> %s\n' "$cf_log" > "$cf_set"; chmod +x "$cf_set"

cf_tk=$(mktemp)
printf '#!/bin/sh\necho "TIMEKEEPER $1" >> %s\n' "$cf_log" > "$cf_tk"; chmod +x "$cf_tk"

: > "$cf_log"
ACF_STAMP="$cf_stamp" ACF_NOW=100 ACF_SET_CMD="$cf_set" ACF_TIMEKEEPER="$cf_tk" "$CF" > /tmp/cf-old.$$ 2>&1
expect_contains "clock behind the floor is advanced" "$cf_log" 'SET @1700000000'
expect_contains "the advance is reported"           /tmp/cf-old.$$ 'advanced 100 -> 1700000000'
# Without this the correction lives only in RAM and a battery pull loses it.
expect_contains "the correction is handed to timekeeper" "$cf_log" 'TIMEKEEPER store'

: > "$cf_log"
ACF_STAMP="$cf_stamp" ACF_NOW=1900000000 ACF_SET_CMD="$cf_set" ACF_TIMEKEEPER="$cf_tk" "$CF" > /tmp/cf-new.$$ 2>&1
expect_absent  "clock ahead of the floor is left alone" "$cf_log" 'SET '
expect_absent  "timekeeper not disturbed on a no-op"    "$cf_log" 'TIMEKEEPER'
expect_contains "no-op is reported"                     /tmp/cf-new.$$ 'already at or past'

: > "$cf_log"
ACF_STAMP=/nonexistent ACF_NOW=100 ACF_SET_CMD="$cf_set" ACF_TIMEKEEPER="$cf_tk" "$CF" > /tmp/cf-nostamp.$$ 2>&1
expect_absent "missing stamp never sets the clock" "$cf_log" 'SET '

rm -f "$cf_stamp" "$cf_set" "$cf_log" "$cf_tk" /tmp/cf-old.$$ /tmp/cf-new.$$ /tmp/cf-nostamp.$$

# RCU pacing: mobile-power-saver leaves jiffies_till_*_fqs at 1000 (clamped to
# HZ) once the screen has been off, and shutdown under that takes ~4 minutes.
# The ExecStop hook must put BOTH back, and must not fail on a kernel that
# lacks the knob.
RU="$ADAPT/adaptation-oneplus-fajita/usr/lib/adaptation-oneplus-fajita/rcu-unthrottle"
ru_dir=$(mktemp -d)
echo 300 > "$ru_dir/jiffies_till_first_fqs"; echo 300 > "$ru_dir/jiffies_till_next_fqs"
ARU_DIR="$ru_dir" "$RU" > /tmp/ru-out.$$ 2>&1
[ "$(cat "$ru_dir/jiffies_till_first_fqs")" = 1 ] && [ "$(cat "$ru_dir/jiffies_till_next_fqs")" = 1 ] \
    && { echo "  PASS  throttled fqs pair is restored to 1"; pass=$((pass+1)); } \
    || { echo "  FAIL  throttled fqs pair is restored to 1: $(cat "$ru_dir"/*)"; fail=$((fail+1)); }
expect_contains "each restore is reported" /tmp/ru-out.$$ 'jiffies_till_next_fqs -> 1'

rm -f "$ru_dir"/*
ARU_DIR="$ru_dir" "$RU" > /tmp/ru-none.$$ 2>&1
[ $? -eq 0 ] && { echo "  PASS  missing knob is a no-op, not a failure"; pass=$((pass+1)); } \
    || { echo "  FAIL  missing knob is a no-op, not a failure"; fail=$((fail+1)); }
rm -rf "$ru_dir" /tmp/ru-out.$$ /tmp/ru-none.$$

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
