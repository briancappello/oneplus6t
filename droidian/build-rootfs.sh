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
SPARSE="$HERE/userdata.simg"

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
say "building userdata.img (WITH journal - see comment at top)"
rm -f "$OUT"
mke2fs -t ext4 -L data -d "$STAGE" -b 4096 -m 0 "$OUT" "$IMG_BLOCKS" 2>&1 | tail -2

if ! dumpe2fs -h "$OUT" 2>/dev/null | grep -q has_journal; then
    echo "ABORT: produced image has no journal; halium will refuse to mount it" >&2
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
