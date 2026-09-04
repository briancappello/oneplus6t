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
SSH="$(dirname "$HERE")/.venv/bin/python $HERE/ssh.py"
fail=0
ck() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }

out=$($SSH -r '
echo "phosh=$(systemctl is-active phosh)"
echo "restarts=$(systemctl show -p NRestarts --value phosh)"
for n in /dev/hwbinder /dev/kgsl-3d0 /dev/diag /dev/input/event0; do
    echo "node $n $(stat -c "%a %U:%G" "$n" 2>/dev/null || echo MISSING)"
done
# sudo logs the full command it runs, so a journal grep for a string that
# appears in THIS script matches its own invocation. Drop sudo lines first or
# every journal count is inflated by one and reports a failure that is really
# just the measurement observing itself.
jrn="journalctl -b --no-pager"
echo "gl=$($jrn | grep -v "sudo\[" | grep -c "GL renderer: Adreno")"
echo "pkgs=$(dpkg -l halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita 2>/dev/null | grep -c "^ii")"
echo "divert=$(dpkg-divert --list | grep -c plugins-disabled/libgstcamerabin)"
echo "camerr=$($jrn | grep -v "sudo\[" | grep -c "CameraBin error")"
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
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
