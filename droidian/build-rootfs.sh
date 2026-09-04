#!/usr/bin/env bash
#
# Prepare a flashable Droidian userdata image for the OnePlus 6T (fajita).
#
#   ./droidian/build-rootfs.sh
#
# Produces droidian/userdata.img: an ext4 filesystem containing Droidian's
# rootfs.img, ready for `fastboot flash userdata`.
#
# Droidian does NOT flash a rootfs partition. Its installer (setup.sh inside
# the release zip) drops rootfs.img as a FILE into /data, resizes it, and
# loop-mounts it. The official flow does that from TWRP. We build the same
# layout offline instead, so no recovery and no manual steps are needed.
#
# HARD REQUIREMENT: the userdata filesystem must have a journal.
# The halium initramfs mounts /data with `data=journal`. Building the image
# with `-O ^has_journal` makes that remount fail:
#
#     EXT4-fs (sda17): can't mount with data=, fs mounted w/o journal
#     initrd: Halium rootfs is
#
# and the device drops to the initramfs debug shell reporting "Failed to boot"
# with everything else perfectly fine. Do not "optimise" the journal away.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
DOWNLOADS="$ROOT/downloads"

# Droidian ships a generic rootfs per Android API level. api28 = Android 9,
# which is what OxygenOS 9.0.17 gives us and what Droidian requires on the 6T.
API="${API:-28}"
RELEASE_REPO="droidian-images/droidian"
ROOTFS_SIZE="${ROOTFS_SIZE:-8G}"        # setup.sh resizes to 8G when there is
                                        # no .full_resize marker
IMG_BLOCKS="${IMG_BLOCKS:-2359296}"     # 9 GiB of 4 KiB blocks; must exceed
                                        # ROOTFS_SIZE plus fs overhead
STAGE="$HERE/stage"
OUT="$HERE/userdata.img"

say() { printf '\n>>> %s\n' "$*"; }

# ---------------------------------------------------------------- fetch
mkdir -p "$DOWNLOADS"
if [ -n "${ROOTFS_ZIP:-}" ]; then
    zip="$ROOTFS_ZIP"
else
    say "resolving latest api${API} rootfs"
    read -r name url < <(
        curl -sfL "https://api.github.com/repos/$RELEASE_REPO/releases" |
        python3 -c "
import json,sys
rs=json.load(sys.stdin)
for r in rs:
    for a in r['assets']:
        if 'rootfs-api${API}' in a['name'] and a['name'].endswith('.zip'):
            print(a['name'], a['browser_download_url']); raise SystemExit
raise SystemExit('no api${API} rootfs asset found')
")
    echo "    $name"
    zip="$DOWNLOADS/$name"
    if [ ! -f "$zip" ]; then
        say "downloading (~1.5 GB)"
        curl -fL --retry 3 -C - -o "$zip" "$url"
    else
        echo "    already downloaded"
    fi
fi
unzip -tq "$zip" >/dev/null || { echo "zip is corrupt: $zip" >&2; exit 1; }

# ---------------------------------------------------------------- extract
say "extracting rootfs.img"
rm -rf "$STAGE"; mkdir -p "$STAGE"
unzip -o -q -j "$zip" "data/rootfs.img" -d "$STAGE"
ls -l "$STAGE/rootfs.img" | awk '{printf "    %s bytes\n",$5}'

# ---------------------------------------------------------------- resize
say "resizing rootfs to $ROOTFS_SIZE"
e2fsck -fy "$STAGE/rootfs.img" >/dev/null 2>&1 || true   # rc 1/2 = fixed, fine
resize2fs -f "$STAGE/rootfs.img" "$ROOTFS_SIZE" 2>&1 | tail -1

# setup.sh creates this symlink so the halium initramfs can find the Android
# container image inside the rootfs.
ln -sfn /halium-system/var/lib/lxc/android/android-rootfs.img \
        "$STAGE/android-rootfs.img"

# ---------------------------------------------------------------- pack
say "building userdata.img (WITH journal - see comment at top)"
rm -f "$OUT"
mke2fs -t ext4 -L data -d "$STAGE" -b 4096 -m 0 "$OUT" "$IMG_BLOCKS" 2>&1 | tail -2

if ! dumpe2fs -h "$OUT" 2>/dev/null | grep -q has_journal; then
    echo "ABORT: produced image has no journal; halium will refuse to mount it" >&2
    exit 1
fi

say "done"
printf '    %s  %s bytes\n' "$OUT" "$(stat -c%s "$OUT")"
dumpe2fs -h "$OUT" 2>/dev/null | grep -E "Filesystem features|Total journal size" | sed 's/^/    /'
debugfs -R "ls -l /" "$OUT" 2>/dev/null | awk 'NF>5{printf "    %-22s %s\n",$NF,$6}'
