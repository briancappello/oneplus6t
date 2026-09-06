#!/usr/bin/env bash
#
# Flash Droidian to the OnePlus 6T (fajita) over fastboot.
#
#   ./droidian/flash.sh
#
# Expects droidian/out/images/{boot,vbmeta}.img from build-kernel.sh and
# droidian/linuxroot.img from build-rootfs.sh.
#
# Prerequisite: stock OxygenOS 9.0.17 must already be installed
# (RELEASE=oos9 restore-android.py). Droidian does not replace the Android
# system -- it runs it as an LXC container -- so system_a, vendor_a and the
# firmware must be present and must be Android 9.
#
# DO NOT ERASE dtbo. kernel-info.mk sets KERNEL_IMAGE_WITH_DTB_OVERLAY=0 and
# the generated flash config says DEVICE_HAS_DTBO_PARTITION=no: Droidian reuses
# the dtbo already on the device, which for us is OxygenOS 9's and already
# contains the fajita overlays. flash-pmos.sh erases dtbo_a because mainline
# needs its own device tree; for Droidian that would break the boot.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT="$HERE/out/images/boot.img"
VBMETA="$HERE/out/images/vbmeta.img"
ROOTFS="$HERE/linuxroot.img"

for f in "$BOOT" "$VBMETA" "$USERDATA"; do
    [ -f "$f" ] || { echo "missing $f -- run build-kernel.sh / build-rootfs.sh" >&2; exit 1; }
done

say() { printf '\n>>> %s\n' "$*"; }

say "waiting for fastboot"
until fastboot devices | grep -q fastboot; do sleep 2; done
echo "    $(fastboot devices)"

slot="$(fastboot getvar current-slot 2>&1 | sed -n 's/^current-slot: *//p' | tr -d '\r')"
[ -n "$slot" ] || slot=a
echo "    current slot: $slot"

# Guard: a half-written linuxroot is indistinguishable from a bad image when it
# fails to boot, and this flash takes ~2 minutes. Warn plainly.
say "flashing (do not interrupt; linuxroot is ~$(( $(stat -c%s "$ROOTFS") / 1000000 )) MB)"

fastboot flash "boot_$slot"   "$BOOT"
fastboot flash "vbmeta_$slot" "$VBMETA"
fastboot flash linuxroot      "$ROOTFS"

say "rebooting"
fastboot reboot

cat <<EOF

Booting. What to expect:

  * The screen stays on the "bootloader is unlocked" warning. That is normal
    with no device adaptation installed -- nothing is driving the display yet.
  * Success is a USB network device appearing. Check with:

        ./droidian/debug.sh

    The USB descriptor's iProduct field reports the initramfs verdict:
    "Failed to boot" means it dropped to the debug shell, and debug.sh will
    pull the reason out of dmesg.
EOF
