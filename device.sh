#!/usr/bin/env bash
#
# Detect and change the phone's state over USB.
#
#   ./device.sh state              # print the current state and exit
#   ./device.sh goto fastboot      # transition, prompting if hands are required
#   ./device.sh goto edl
#   ./device.sh goto droidian
#   ./device.sh wait droidian      # just wait for a state
#
# States: droidian fastboot edl initramfs ramdump android off
#
# ---------------------------------------------------------------------------
# Everything below was measured on hardware, not assumed.
#
# THE IMPORTANT GOTCHA: during Droidian's shutdown the OLD usb id stays
# enumerated and the device keeps answering pings for up to ~2 minutes. Never
# conclude a transition failed because the old id is still present -- poll for
# the TARGET id with a generous timeout. Getting this wrong makes a working
# transition look broken, which is exactly what happened the first time.
#
# Measured timings (OnePlus 6T, 246 GB userdata):
#   droidian -> fastboot   ~120-180s   (slow systemd shutdown, not slow boot)
#   droidian -> edl        ~70s
#   fastboot -> droidian   ~30s to usb, ~40s to sshd
#   edl reset -> droidian  ~20s
#
# EDL is reachable from a booted Droidian even though the BOOTLOADER refuses
# it: `fastboot oem edl`, `oem enter-dload` and `reboot emergency` are all
# rejected, but the kernel's own restart handler accepts "edl"
# (drivers/power/reset/msm-poweroff.c, guarded by CONFIG_QCOM_DLOAD_MODE=y,
# which our fajita_defconfig sets). That is a completely different code path.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="$HERE/.venv/bin/python $HERE/droidian/ssh.py"
LOADER="$HERE/msm/extract/prog_firehose_ddr.elf"

say() { printf '>>> %s\n' "$*" >&2; }

state() {
    local ids; ids=$(lsusb 2>/dev/null)
    case "$ids" in
        *0fce:7169*) echo droidian  ; return ;;
        *18d1:d00d*) echo fastboot  ; return ;;
        *05c6:9008*) echo edl       ; return ;;
        *18d1:d001*) echo initramfs ; return ;;
        *05c6:900e*) echo ramdump   ; return ;;
    esac
    command -v adb >/dev/null && [ -n "$(adb devices 2>/dev/null | sed -n 2p)" ] && { echo android; return; }
    echo off
}

wait_for() {   # wait_for <state> [timeout-seconds]
    local want=$1 timeout=${2:-240} waited=0 now
    while [ "$waited" -lt "$timeout" ]; do
        now=$(state)
        [ "$now" = "$want" ] && { say "reached $want after ${waited}s"; return 0; }
        sleep 5; waited=$((waited + 5))
        [ $((waited % 30)) -eq 0 ] && say "  ${waited}s: still $now, waiting for $want"
    done
    say "TIMEOUT after ${timeout}s waiting for $want (now: $(state))"
    return 1
}

# Anything needing fingers. Prompts, then waits for the expected result rather
# than trusting the human to have done it.
prompt_human() {   # prompt_human <target-state> <instruction>
    local want=$1; shift
    cat >&2 <<EOF

  ---------------------------------------------------------------
  HANDS REQUIRED -- this transition cannot be done over USB.

  $*

  Waiting for the device to appear as: $want
  Ctrl-C to abort.
  ---------------------------------------------------------------

EOF
    wait_for "$want" 600
}

goto() {
    local want=$1 now; now=$(state)
    [ "$now" = "$want" ] && { say "already $want"; return 0; }
    say "$now -> $want"

    case "$now/$want" in
        droidian/fastboot)
            $SSH -r 'sync; systemctl --reboot-argument=bootloader reboot' >/dev/null 2>&1
            wait_for fastboot 300 ;;
        droidian/edl)
            $SSH -r 'sync; systemctl --reboot-argument=edl reboot' >/dev/null 2>&1
            wait_for edl 300 ;;
        droidian/droidian)
            $SSH -r 'sync; systemctl reboot' >/dev/null 2>&1
            sleep 20; wait_for droidian 300 ;;

        fastboot/droidian|fastboot/android)
            fastboot reboot >/dev/null 2>&1; wait_for "$want" 300 ;;
        fastboot/edl)
            # The bootloader rejects oem edl / enter-dload / reboot emergency,
            # so go the long way round through a booted system.
            say "bootloader cannot enter EDL directly; routing via a booted OS"
            goto droidian || return 1
            goto edl ;;

        edl/*)
            [ -f "$LOADER" ] || { say "missing $LOADER (run bootstrap.py)"; return 1; }
            "$HERE/.venv/bin/python" "$HERE/edl/edl.py" reset --loader="$LOADER" >/dev/null 2>&1
            wait_for "$want" 300 ;;

        initramfs/fastboot)
            "$HERE/droidian/debug.sh" "sync; reboot bootloader" >/dev/null 2>&1
            wait_for fastboot 300 ;;

        ramdump/*)
            prompt_human "$want" \
"The device is halted in ramdump mode after a panic.
  Pull the log first if you want it:  ./droidian/dump-ramoops.py
  Then hold POWER for ~15s to force a power cycle." ;;

        off/edl)
            prompt_human edl \
"1. Unplug USB.
  2. Hold POWER + VOLUME UP ~15s until the screen is fully black.
  3. Hold VOLUME UP + VOLUME DOWN together and, still holding, plug USB in.
     The screen stays black -- that is correct." ;;
        off/fastboot)
            prompt_human fastboot \
"From powered off, hold VOLUME UP + VOLUME DOWN + POWER." ;;
        off/*)
            prompt_human "$want" "Press POWER to boot the device." ;;

        */*)
            say "no direct route $now -> $want; try going via fastboot"
            return 1 ;;
    esac
}

case "${1:-state}" in
    state) state ;;
    goto)  [ $# -eq 2 ] || { echo "usage: $0 goto <state>" >&2; exit 2; }; goto "$2" ;;
    wait)  [ $# -ge 2 ] || { echo "usage: $0 wait <state> [timeout]" >&2; exit 2; }; wait_for "$2" "${3:-240}" ;;
    *)     sed -n '2,20p' "$0"; exit 2 ;;
esac
