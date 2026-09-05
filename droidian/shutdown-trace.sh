#!/usr/bin/env bash
#
# Run one instrumented reboot of the phone and bring back everything it left.
#
#   ./droidian/shutdown-trace.sh                  # reboot now, whatever state
#   ./droidian/shutdown-trace.sh --screen-off     # wait for power-save first
#   ./droidian/shutdown-trace.sh --arg warm       # pass a reboot argument
#   ./droidian/shutdown-trace.sh --ramdump        # keep DDR: the whole story
#   ./droidian/shutdown-trace.sh --collect-only   # just fetch the last one
#
# --ramdump is the one that sees past journald. It sets
# msm_poweroff.dload_on_reboot so the kernel restarts through the download-mode
# path; the bootloader then halts in ramdump mode instead of booting, the
# ramoops console and pmsg zones are read out over Sahara (dump-ramoops.py),
# and a Sahara reset boots the phone. Costs about a minute more per run. A
# plain warm reset was tried first and the bootloader wipes DDR anyway.
#
# Needs fajita-shutdown-trace installed on the phone (built by
# adaptation/build-adaptation.sh, baked into the rootfs by build-rootfs.sh).
#
# Shutdown time is measured from the host, reboot request to the USB device
# disappearing, because that is the kernel actually restarting. The journal
# stops tens of seconds earlier; its figure is reported too, as a lower bound.
#
# Output: logs/shutdown-trace/<stamp>/ with journal.log, watch.log, the
# ramoops console and pmsg zones if the warm reset preserved them, the next
# boot's dmesg, and summary.txt from shutdown-trace-report.py.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
PATH="$ROOT/bin:$PATH"
USB_ID="0fce:7169"          # the booted Droidian gadget

want_state=any; arg=""; collect_only=0; ramdump=0
while [ $# -gt 0 ]; do
    case "$1" in
        --screen-off)   want_state=off ;;
        --screen-on)    want_state=on ;;
        --arg)          arg="$2"; shift ;;
        --collect-only) collect_only=1 ;;
        --ramdump)      ramdump=1 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

say() { printf '>>> %s\n' "$*"; }
fresh_ssh() {   # true once the phone answers and its uptime says it rebooted
    local u; u=$(device-ssh 'cut -d. -f1 /proc/uptime' 2>/dev/null) || return 1
    [ -n "$u" ] && [ "$u" -lt 150 ]
}

stamp=$(date +%Y%m%d-%H%M%S)
out="$ROOT/logs/shutdown-trace/$stamp"
mkdir -p "$out"

if [ "$collect_only" = 0 ]; then
    if [ "$want_state" != any ]; then
        say "waiting for screen $want_state"
        for _ in $(seq 1 60); do
            st=$(device-ssh -r 'echo $(cat /sys/class/backlight/panel0-backlight/bl_power) $(cat /sys/module/rcutree/parameters/jiffies_till_first_fqs)' 2>/dev/null)
            case "$want_state:$st" in off:"4 "*) break ;; on:"0 "*) break ;; esac
            sleep 10
        done
        echo "    bl_power/fqs = $st"
    fi
    pre=$(device-ssh -r 'echo "bl=$(cat /sys/class/backlight/panel0-backlight/bl_power) fqs=$(cat /sys/module/rcutree/parameters/jiffies_till_first_fqs) dload=$(cat /sys/module/msm_poweroff/parameters/dload_on_reboot 2>/dev/null || echo absent) hung=$(cat /proc/sys/kernel/hung_task_timeout_secs 2>/dev/null || echo absent) trace=$(systemctl is-active fajita-shutdown-trace.service)"' 2>/dev/null)
    echo "pre-reboot: $pre" | tee "$out/pre-reboot.txt"

    if [ "$ramdump" = 1 ]; then
        device-ssh -r 'echo 1 > /sys/module/msm_poweroff/parameters/dload_on_reboot && echo armed for ramdump' \
            || { echo "kernel has no dload_on_reboot knob; flash the patched kernel" >&2; exit 1; }
    fi
    say "rebooting${arg:+ (argument: $arg)}"
    t0=$(date +%s.%N)
    device-ssh -r "(sleep 0.2; systemctl reboot ${arg:+--reboot-argument=$arg}) >/dev/null 2>&1 & disown" >/dev/null 2>&1
    while lsusb | grep -q "$USB_ID"; do sleep 0.5; done
    t1=$(date +%s.%N)
    host_shutdown=$(python3 -c "print('%.1f' % ($t1 - $t0))")
    echo "host_shutdown_s=$host_shutdown" | tee -a "$out/pre-reboot.txt"
    say "kernel restarted after ${host_shutdown}s; waiting for the new boot"
    if [ "$ramdump" = 1 ]; then
        # This bootloader (emmc_dload=1) usually writes the dump to storage and
        # boots by itself, in which case the zones come back through pstore.
        # If it halts on USB instead, read them out and reset it.
        for _ in $(seq 1 90); do
            st=$("$ROOT/device.sh" state)
            [ "$st" = ramdump ] || [ "$st" = droidian ] && break
            sleep 1
        done
        if [ "$st" = ramdump ]; then
            "$ROOT/.venv/bin/python" "$HERE/dump-ramoops.py" --out "$out/ramoops.bin" --reset 2>&1 | grep -v "library is missing"
            sleep 5
            [ "$("$ROOT/device.sh" state)" = edl ] && "$ROOT/device.sh" goto droidian >/dev/null
        fi
    fi
    sleep 20
    until fresh_ssh; do sleep 3; done
    t2=$(date +%s.%N)
    echo "host_cycle_s=$(python3 -c "print('%.1f' % ($t2 - $t0))")" >> "$out/pre-reboot.txt"
fi

say "collecting into $out"
device-ssh -r 'journalctl -b -1 -o short-monotonic --no-pager' > "$out/journal.log" 2>/dev/null
device-ssh -r 'dmesg' > "$out/next-boot-dmesg.log" 2>/dev/null
prev=$(device-ssh -r 'journalctl -b -1 -o export -n1 --no-pager 2>/dev/null | sed -n "s/^_BOOT_ID=//p"' 2>/dev/null | tr -d '\r\n')
echo "prev_boot_id=$prev" >> "$out/pre-reboot.txt"
for f in watch console-ramoops-0 pmsg-ramoops-0 dmesg-ramoops-0 dmesg-ramoops-1 next-boot-pon; do
    device-ssh -g "/var/log/shutdown-trace/$prev.$f:$out/$f" >/dev/null 2>&1 || rm -f "$out/$f"
done
[ -f "$out/watch" ] && mv "$out/watch" "$out/watch.log"
ls -la "$out" | sed 's/^/    /'

python3 "$HERE/shutdown-trace-report.py" "$out" | tee "$out/summary.txt"
