#!/usr/bin/env bash
#
# Prepare a flashable Droidian data image for the OnePlus 6T (fajita).
#
#   ./droidian/build-rootfs.sh
#
# Produces droidian/linuxroot.img: an ext4 filesystem containing Droidian's
# rootfs.img, ready for `fastboot flash linuxroot`. Android keeps `userdata`;
# the kernel cmdline (datapart=, see packaging/debian/kernel-info.mk) points
# the halium initramfs at linuxroot instead.
#
# Droidian does NOT flash a rootfs partition. Its installer (setup.sh inside
# the release zip) drops rootfs.img as a FILE into /data, resizes it, and
# loop-mounts it. The official flow does that from TWRP. We build the same
# layout offline instead, so no recovery and no manual steps are needed.
#
# HARD REQUIREMENT: the data filesystem must have a journal.
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
# The inner rootfs.img is grown here, at build time, because the Droidian
# rootfs ships no e2fsprogs to grow it on the device. 100G is SPARSE: only the
# ~4.5 GB of real data occupies blocks, and mke2fs -d keeps the holes when it
# packs the file into the outer image (verified: a 5 GiB sparse file costs 16
# blocks in a 256 MiB image). A file's logical size is not bounded by its
# filesystem's size, so this fits in the 9 GiB outer image below; the halium
# initramfs then grows the outer filesystem to the 114 GiB linuxroot partition
# on first boot, and verify-device.sh asserts both sizes. The 14 GiB left over
# is for android-data, the container's /data, which lives beside rootfs.img.
ROOTFS_SIZE="${ROOTFS_SIZE:-100G}"
IMG_BLOCKS="${IMG_BLOCKS:-2359296}"     # 9 GiB of 4 KiB blocks; must exceed the
                                        # ALLOCATED size of the rootfs plus fs
                                        # overhead, not its sparse logical size
STAGE="$HERE/stage"
OUT="$HERE/linuxroot.img"
SPARSE="$HERE/linuxroot.simg"

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
# resize2fs exits 0 on some refusals it only prints. Assert the result: the
# block count must be within 1% of what was asked for.
want_blocks=$(( $(numfmt --from=iec "$ROOTFS_SIZE") / 4096 ))
got_blocks=$(dumpe2fs -h "$STAGE/rootfs.img" 2>/dev/null | awk '/^Block count/{print $3}')
if [ -z "$got_blocks" ] || [ "$got_blocks" -lt $(( want_blocks * 99 / 100 )) ]; then
    echo "ABORT: rootfs.img is $got_blocks blocks after resize, wanted $want_blocks" >&2
    exit 1
fi
printf '    rootfs.img: %s blocks (%s), sparse: %s allocated\n' "$got_blocks" "$ROOTFS_SIZE" \
    "$(du -h "$STAGE/rootfs.img" | cut -f1)"

# setup.sh creates this symlink so the halium initramfs can find the Android
# container image inside the rootfs.
ln -sfn /halium-system/var/lib/lxc/android/android-rootfs.img \
        "$STAGE/android-rootfs.img"

# ---------------------------------------------------------------- adaptation
# Install our .debs into the rootfs so the fixes survive a reinstall. This is
# the seam that makes the whole pipeline worth having: without it every fix
# lives only on the running device and the next flash destroys it.
#
# Runs in the Droidian container because the host (Arch) has no dpkg. fuse2fs
# mounts the image rootlessly and dpkg --root installs arm64 packages from an
# amd64 container.
#
# Our three adaptation packages carry no maintainer scripts, so they alone need
# no emulation. droidian-camera is built with dh and DOES ship postinst/postrm,
# and dpkg --root chroots to run them -- so installing it requires qemu-aarch64
# binfmt with the F flag, which check-env.sh already asserts for the build role.
#
# /dev must be bind-mounted over the image's own. The image does contain a
# /dev/null character device, but FUSE mounts are nodev, so opening it fails
# with EPERM. Without this, droidian-camera's postinst hits
# "cannot create /dev/null: Permission denied" on its `command -v ... >/dev/null`
# line. That failure sits inside an `if` condition, so `set -e` does not trip
# and dpkg still reports success -- a silently half-applied package.
if [ "${ADAPTATION:-1}" = 1 ]; then
    debs=$(ls "$HERE"/out-adaptation/*.deb "$HERE"/out-camera/*.deb 2>/dev/null || true)
    if [ -z "$debs" ]; then
        echo "ABORT: no .debs found. Run droidian/adaptation/build-adaptation.sh" >&2
        echo "       and droidian/build-camera.sh first, or set ADAPTATION=0." >&2
        exit 1
    fi
    say "installing adaptation packages into rootfs.img"
    mkdir -p "$STAGE/debs"
    cp $debs "$STAGE/debs/"

    runtime() {
        command -v docker >/dev/null && { echo docker; return; }
        command -v podman >/dev/null && { echo podman; return; }
        echo "Need docker or podman." >&2; exit 1
    }

    # --cap-add SYS_ADMIN is a capability inside the container's user
    # namespace, not host root. Without it fusermount3 fails with EPERM.
    $(runtime) run --rm --device /dev/fuse --cap-add SYS_ADMIN \
        --security-opt apparmor=unconfined \
        -v "$STAGE":/stage \
        quay.io/droidian/build-essential:current-amd64 /bin/sh -c '
set -e
apt-get update -qq
apt-get install -y -qq fuse2fs fuse3 >/dev/null
mkdir -p /mnt/rootfs
# fuse2fs forks, so its exit code is meaningless. Assert with mountpoint.
fuse2fs -o rw,fakeroot /stage/rootfs.img /mnt/rootfs 2>&1 | grep -v journal || true
mountpoint -q /mnt/rootfs || { echo "fuse2fs failed to mount"; exit 1; }
mount --bind /dev /mnt/rootfs/dev
trap "umount /mnt/rootfs/dev 2>/dev/null || true; fusermount3 -u /mnt/rootfs 2>/dev/null || true" EXIT

dpkg --root=/mnt/rootfs -i /stage/debs/*.deb
dpkg --root=/mnt/rootfs --audit

# A half-configured package still lets dpkg exit 0, so assert the state
# explicitly: all four must be "ii", not "iF" or "iU".
want=4
got=$(dpkg --root=/mnt/rootfs -l halium-hostdev-perms halium-oldkernel-compat \
        adaptation-oneplus-fajita droidian-camera 2>/dev/null | grep -c "^ii")
dpkg --root=/mnt/rootfs -l halium-hostdev-perms halium-oldkernel-compat \
        adaptation-oneplus-fajita droidian-camera 2>/dev/null | grep "^[a-z][a-zA-Z]"
if [ "$got" != "$want" ]; then
    echo "ABORT: expected $want packages in state ii, found $got" >&2
    exit 1
fi

umount /mnt/rootfs/dev
trap - EXIT
fusermount3 -u /mnt/rootfs
'
    rm -rf "$STAGE/debs"
    e2fsck -fy "$STAGE/rootfs.img" >/dev/null 2>&1 || true   # fuse2fs bypasses the journal

    for p in halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita; do
        # debugfs exits 0 even when the file does not exist -- it prints
        # "File not found by ext2_lookup" to stderr and carries on. Asserting on
        # its exit code silently passes for a package that never installed, so
        # assert on the OUTPUT: a real stat always begins a line with "Inode:".
        if ! debugfs -R "stat /var/lib/dpkg/info/$p.list" "$STAGE/rootfs.img" 2>&1 \
             | grep -q '^Inode:'; then
            echo "ABORT: $p is not installed in rootfs.img" >&2
            exit 1
        fi
    done
    say "adaptation packages verified present in rootfs.img"
fi

# ---------------------------------------------------------------- pack
# The image is 9 GiB inside a 114 GiB partition. The halium initramfs grows
# the filesystem to the partition on first boot (resize_userdata_if_needed in
# scripts/halium) -- but only for /dev/mmcblk* and /dev/disk* paths, which is
# why the cmdline names the partition as /dev/disk/by-partlabel/linuxroot.
say "building linuxroot.img (WITH journal - see comment at top)"
rm -f "$OUT"
# -O ^orphan_file: the halium initramfs carries e2fsprogs 1.43.4 (2017), and
# orphan_file (default since 1.47) is a feature it does not know. Its e2fsck and
# resize2fs then fail with "unsupported feature(s)" -- silently, because the
# script logs "resized" regardless -- so the fs was never checked and never
# grown past the 9 GiB built here. Verified by running the initramfs's own
# resize2fs under qemu-user against both variants.
mke2fs -t ext4 -L data -d "$STAGE" -b 4096 -m 0 -O ^orphan_file "$OUT" "$IMG_BLOCKS" 2>&1 | tail -2

if ! dumpe2fs -h "$OUT" 2>/dev/null | grep -q has_journal; then
    echo "ABORT: produced image has no journal; halium will refuse to mount it" >&2
    exit 1
fi
if dumpe2fs -h "$OUT" 2>/dev/null | grep '^Filesystem features' | grep -q orphan_file; then
    echo "ABORT: produced image has orphan_file; the initramfs e2fsprogs cannot resize it" >&2
    exit 1
fi

# The image is mostly empty -- 9 GiB of container around a few GiB of rootfs --
# so the Android sparse form of it is under half the size, and that is the form
# fastboot wants anyway: given a raw image it sparses it itself before sending.
# Converting here costs about a second and takes the same bytes off both the
# network transfer and the USB transfer.
say "converting to sparse for transfer and flashing"
rm -f "$SPARSE"
img2simg "$OUT" "$SPARSE"
[ -s "$SPARSE" ] || { echo "ABORT: img2simg produced nothing" >&2; exit 1; }

say "done"
printf '    %s  %s bytes\n' "$OUT" "$(stat -c%s "$OUT")"
printf '    %s  %s bytes (%s%% of raw)\n' "$SPARSE" "$(stat -c%s "$SPARSE")" \
    "$(( $(stat -c%s "$SPARSE") * 100 / $(stat -c%s "$OUT") ))"
dumpe2fs -h "$OUT" 2>/dev/null | grep -E "Filesystem features|Total journal size" | sed 's/^/    /'
debugfs -R "ls -l /" "$OUT" 2>/dev/null | awk 'NF>5{printf "    %-22s %s\n",$NF,$6}'
