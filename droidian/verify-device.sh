#!/usr/bin/env bash
#
# Assert the device is actually fixed. Checks user-visible outcomes, not that
# files exist, and asserts the NEGATIVE cases too -- the two ways this design
# could silently do the wrong thing.
#
#   ./droidian/verify-device.sh
#
# Every value is LABELLED at the source and looked up by label. An earlier
# draft indexed the remote output by line number, which was wrong twice over:
# it read the wrong line, and a single missing /dev node shifts every line
# after it, so the checks would silently start testing the wrong values.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolved by name off PATH, like every other device-touching call in this repo.
# That is what lets the test suite shadow it; hardcoding the interpreter path
# here would have made this the one script a test could not keep off the phone.
PATH="$PATH:$(dirname "$HERE")/bin"
SSH=device-ssh
fail=0
ck() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }

out=$($SSH -r '
echo "phosh=$(systemctl is-active phosh)"
echo "restarts=$(systemctl show -p NRestarts --value phosh)"
for n in /dev/hwbinder /dev/kgsl-3d0 /dev/diag /dev/input/event0; do
    echo "node $n $(stat -c "%a %U:%G" "$n" 2>/dev/null || echo MISSING)"
done
# sudo logs the full command it runs, so a journal grep for a string that
# appears in THIS script matches its own invocation. Every journal count would
# be inflated by one and report a failure that is really the measurement
# observing itself. The sudo filter lives INSIDE this function rather than at
# each call site, because leaving it to the call site got forgotten twice and
# produced two phantom failures.
jrn() { journalctl -b --no-pager | grep -v "sudo\["; }
echo "gl=$(jrn | grep -c "GL renderer: Adreno")"
echo "pkgs=$(dpkg -l halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita 2>/dev/null | grep -c "^ii")"
echo "divert=$(dpkg-divert --list | grep -c plugins-disabled/libgstcamerabin)"
echo "camerr=$(jrn | grep -c "CameraBin error")"
echo "setuid=$(stat -c "%a" /usr/lib/polkit-1/polkit-agent-helper-1 2>/dev/null)"
echo "hhp=$(systemctl is-active halium-hostdev-perms.service 2>/dev/null)"
# The deny invariant is about REACHABILITY, not a particular mode. /dev/diag is
# 660 system:root on a stock boot, not 600 root:root -- an earlier draft
# asserted the latter, which was an incidental value observed on a stale rootfs
# and had nothing to do with whether the deny worked.
R=/run/udev/rules.d/70-halium-hostdev-perms.rules
echo "diagread=$(runuser -u droidian -- test -r /dev/diag 2>/dev/null && echo yes || echo no)"
echo "diagwrite=$(runuser -u droidian -- test -w /dev/diag 2>/dev/null && echo yes || echo no)"
echo "diagrule=$(grep -c '"'"'KERNEL=="diag"'"'"' $R 2>/dev/null)"
echo "rules=$(grep -c ACTION $R 2>/dev/null)"
# Erosion guard. A ruleset persisted in /etc is applied by udev BEFORE
# generate-rules runs, so the nodes it fixed read as "already reachable" and get
# written out of the file -- measured erosion from 52 rules to 42 across one
# reboot, dropping hwbinder and vndbinder. The rules must live in /run (tmpfs),
# so each boot measures a pristine /dev. Any file in /etc outranks /run and
# brings the bug straight back.
echo "stale=$([ -e /etc/udev/rules.d/70-halium-hostdev-perms.rules ] && echo yes || echo no)"
# The qpnp RTC free-runs from zero and is read-only, and a reflash wipes
# timekeeper offset file, so a stock boot comes up in 1970 -- which breaks TLS,
# breaks apt, trips the polkit password-age check, and makes journald discard
# boots. No apostrophes in this block: it is single-quoted all the way to the
# remote shell, and one would end the quote and truncate the script.
echo "epoch=$(date -u +%s)"
echo "clockfloor=$(systemctl is-active adaptation-clock-floor.service 2>/dev/null)"
# Droidian owns linuxroot; Android owns userdata. The initramfs is pointed at
# linuxroot by datapart= on the cmdline and grows the filesystem to the
# partition on first boot. datafill is the filesystem as a percentage of the
# partition, from stat -f (the rootfs has no e2fsprogs, so no dumpe2fs). The
# image is built at 9 GiB in a 114 GiB partition, so anything above 95 means
# the grow happened; an ungrown image reads 7.
DP=$(findmnt -no SOURCE /userdata 2>/dev/null)
echo "datapart=$(lsblk -no PARTLABEL "$DP" 2>/dev/null)"
echo "datafill=$(( $(stat -f -c "%b * %S" /userdata 2>/dev/null || echo 0) * 100 / $(blockdev --getsize64 "$DP" 2>/dev/null || echo 1) ))"
echo "udmounts=$(findmnt -no TARGET /dev/disk/by-partlabel/userdata 2>/dev/null | wc -l)"
# The inner rootfs.img is grown to 100G (sparse) at build time; below 90 means
# an image built with the old 8G default, or one that was never resized.
echo "rootsize=$(df -BG --output=size / 2>/dev/null | tail -1 | tr -dc 0-9)"
# systemd resolves an ordering cycle by deleting one job silently. The victim
# then looks identical to a unit that ran and did nothing, so check explicitly.
echo "cycles=$(jrn | grep -c "Found ordering cycle")"
echo "deleted=$(jrn | grep -c "deleted to break ordering cycle")"
# lxc.service is masked: it started nothing for this container and its stop
# killed it; masking it is what removed the cycle above. If it is back, the
# cycle is back, and which job systemd deletes varies from boot to boot.
echo "lxcmask=$(systemctl is-enabled lxc.service 2>/dev/null)"
# chre must never run: shutdown critical, unstoppable, and its exit wedges in
# fastrpc after sscrpcd is gone. Any value here means the rc override is off.
echo "chre=$(getprop init.svc.chre 2>/dev/null)"
# Kernel-mode fastrpc invocations are bounded (packaging/patches/0004). The
# knob only exists on the patched kernel.
echo "fastrpcto=$(cat /sys/module/adsprpc/parameters/kernel_invoke_timeout_ms 2>/dev/null)"
echo "timewarp=$(jrn | grep -c "Time jumped backwards")"
# NOT asserted: that a given node appears in our ruleset. Which nodes need our
# help legitimately varies -- the kgsl driver creates /dev/kgsl-3d0 and /dev/ion
# already at their ueventd.rc values on some boots, and skipping an
# already-correct node is the design working, not erosion. The OUTCOME checks
# below are what matter, and they catch erosion on the following boot anyway.
' 2>/dev/null)

echo "$out"
echo
# A node that is MISSING fails its check rather than being skipped.
node() { grep "^node $1 " <<<"$out" | cut -d" " -f3-; }
val()  { grep "^$1=" <<<"$out" | cut -d= -f2-; }

ck "phosh active"                 '[ "$(val phosh)" = active ]'
ck "hwbinder widened"             '[ "$(node /dev/hwbinder)" = "666 root:root" ]'
ck "kgsl widened"                 '[ "$(node /dev/kgsl-3d0)" = "666 system:system" ]'
ck "diag STILL unreachable"       '[ "$(val diagread)" = no ] && [ "$(val diagwrite)" = no ]'
ck "no rule emitted for diag"     '[ "$(val diagrule)" = 0 ]'
ck "rules were generated at all"  '[ "$(val rules)" -gt 0 ]'
ck "no stale ruleset in /etc"     '[ "$(val stale)" = no ]'
ck "input STILL android_input"    '[[ "$(node /dev/input/event0)" == *:android_input ]]'
ck "hardware GL (not pixman)"     '[ "$(val gl)" -gt 0 ]'
ck "3 adaptation packages"        '[ "$(val pkgs)" = 3 ]'
ck "hostdev-perms unit ran"       '[ "$(val hhp)" = active ]'
ck "polkit helper is setuid"      '[ "$(val setuid)" = 4755 ]'
ck "camerabin diverted"           '[ "$(val divert)" = 1 ]'
ck "no CameraBin error"           '[ "$(val camerr)" = 0 ]'
ck "clock-floor unit ran"         '[ "$(val clockfloor)" = active ]'
# 1767225600 = 2026-01-01. Anything below means the clock is still at the RTC's
# 1970, or the floor did not apply.
ck "clock is not stuck in 1970"   '[ "$(val epoch)" -gt 1767225600 ]'
ck "no systemd ordering cycles"   '[ "$(val cycles)" = 0 ]'
ck "no jobs deleted for cycles"   '[ "$(val deleted)" = 0 ]'
ck "lxc.service is masked"        '[ "$(val lxcmask)" = masked ]'
ck "chre never ran"               '[ -z "$(val chre)" ]'
ck "fastrpc kernel invoke bounded" '[ "$(val fastrpcto)" = 5000 ]'
ck "clock never jumped backwards" '[ "$(val timewarp)" = 0 ]'
ck "droidian data is on linuxroot" '[ "$(val datapart)" = linuxroot ]'
ck "data fs fills linuxroot"       '[ "$(val datafill)" -ge 95 ] 2>/dev/null'
ck "userdata is left to Android"   '[ "$(val udmounts)" = 0 ]'
ck "rootfs is grown past 8G"       '[ "$(val rootsize)" -ge 90 ] 2>/dev/null'
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
