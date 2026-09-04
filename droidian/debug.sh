#!/usr/bin/env bash
#
# Talk to the halium initramfs debug shell on a booting Droidian device.
#
#   ./droidian/debug.sh              # diagnose why it did not boot
#   ./droidian/debug.sh "ls /halium-system"   # run arbitrary commands
#
# When the halium initramfs cannot hand off to the rootfs it brings up an RNDIS
# gadget and a passwordless telnet shell. The USB descriptor tells you the
# verdict before you connect:
#
#     iManufacturer  Halium initrd
#     iProduct       Failed to boot          <- dropped to the debug shell
#
# The host gets 192.168.2.x; the device is always 192.168.2.15 on port 23.

set -uo pipefail

DEV_IP="${DEV_IP:-192.168.2.15}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\n>>> %s\n' "$*"; }

say "USB gadget"
if lsusb | grep -q 18d1:d001; then
    lsusb -d 18d1:d001 -v 2>/dev/null |
        grep -iE "iManufacturer|iProduct" | sed 's/^ */    /'
else
    echo "    no halium initrd gadget (18d1:d001) present"
    echo "    device is either still booting, fully booted, or in fastboot:"
    lsusb | grep -oiE "18d1:[0-9a-f]{4}|05c6:[0-9a-f]{4}|2a70:[0-9a-f]{4}" |
        sed 's/^/      /' || echo "      nothing"
    exit 1
fi

say "network"
ip -br addr show | awk '/192\.168\.2\./ {printf "    %s %s\n",$1,$3}'
ping -c1 -W2 "$DEV_IP" >/dev/null 2>&1 && echo "    $DEV_IP reachable" || {
    echo "    $DEV_IP NOT reachable"; exit 1; }

# Default diagnostics answer: why did the handoff fail?
if [ $# -eq 0 ]; then
    set -- \
        "uname -a" \
        "dmesg | grep -iE 'initrd:|EXT4-fs \(sd|halium' | tail -20" \
        "mount | grep -iE 'data|halium|loop'" \
        "ls /halium-system/ | head -5" \
        "ls -la /dev/disk/by-partlabel/userdata"
fi

python3 - "$DEV_IP" "$@" <<'PY'
import socket, sys, time
ip, cmds = sys.argv[1], sys.argv[2:]
s = socket.create_connection((ip, 23), timeout=10); s.settimeout(3)
def drain():
    out = b""
    try:
        while True:
            d = s.recv(65536)
            if not d: break
            out += d
    except Exception:
        pass
    return out.decode("utf-8", "replace")
time.sleep(1); drain()
for c in cmds:
    s.sendall((c + "\n").encode()); time.sleep(2)
    txt = drain()
    # strip the busybox prompt/escape noise so output stays readable
    lines = [l for l in txt.splitlines()
             if l.strip() and not l.strip().startswith("/ #") and c not in l]
    print(f"\n--- {c}")
    for l in lines:
        print("   ", l.replace("\x1b[6n", "").rstrip())
s.close()
PY

cat <<EOF

Reminder: 'reboot bootloader' works from this shell, so you can get back to
fastboot without the key combo:

    ./droidian/debug.sh "sync; reboot bootloader"
EOF
