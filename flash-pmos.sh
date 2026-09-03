#!/usr/bin/env bash
# Flash a postmarketOS pre-built image (boot + rootfs) to oneplus-fajita via fastboot.
#
# Usage:  flash-pmos.sh <path to ROOTFS .img or .img.xz>
#   The matching "-boot" image is found automatically from the same name.
#   Point it at the big rootfs file, e.g.:
#     ./flash-pmos.sh 20260828-0706-postmarketOS-v26.06-phosh-29.1-oneplus-fajita.img.xz
#
# The phone must be in fastboot mode (the script waits for it).
set -euo pipefail

root_arg="$(readlink -f "${1:?Usage: flash-pmos.sh <rootfs .img or .img.xz>}")"

# Derive the matching -boot image from the rootfs filename.
case "$root_arg" in
  *-boot.img|*-boot.img.xz)
    echo "Point me at the ROOTFS image, not the -boot image." >&2; exit 1 ;;
  *.img.xz) boot_arg="${root_arg%.img.xz}-boot.img.xz" ;;
  *.img)    boot_arg="${root_arg%.img}-boot.img" ;;
  *) echo "Expected a .img or .img.xz file." >&2; exit 1 ;;
esac
[ -f "$boot_arg" ] || { echo "Matching boot image not found: $boot_arg" >&2; exit 1; }

# Decompress *.xz -> *.img (keep the .xz). Echoes the .img path.
prepare() {
  local f="$1"
  if [ "${f##*.}" = "xz" ]; then
    local out="${f%.xz}"
    [ -f "$out" ] || { echo ">>> Decompressing $(basename "$f")..." >&2; xz -dk "$f"; }
    printf '%s' "$out"
  else
    printf '%s' "$f"
  fi
}

BOOT_IMG="$(prepare "$boot_arg")"
ROOT_IMG="$(prepare "$root_arg")"
echo "boot   : $BOOT_IMG"
echo "rootfs : $ROOT_IMG"

echo ">>> Waiting for the phone in fastboot mode (Vol Up + Vol Down + Power from off)..."
until fastboot devices | grep -q fastboot; do sleep 1; done
echo "Device: $(fastboot devices)"

echo ">>> Flashing boot..."
fastboot flash boot "$BOOT_IMG"
echo ">>> Flashing rootfs to userdata (this is the big one)..."
fastboot flash userdata "$ROOT_IMG"
echo ">>> Erasing stock dtbo overlay (required, or pmOS loops back to fastboot)..."
fastboot erase dtbo_a
echo ">>> Rebooting..."
fastboot reboot
echo ">>> Done. First boot takes several minutes. Do NOT use the power button until it's up."
echo ">>> Login: user / 147147"
