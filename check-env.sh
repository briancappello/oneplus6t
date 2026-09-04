#!/usr/bin/env bash
#
# Verify this machine has everything the repo's scripts need.
#
#   ./check-env.sh            # check everything
#   ./check-env.sh restore    # only what bootstrap.py + restore-android.py need
#   ./check-env.sh droidian   # only what the droidian/ build scripts need
#
# Reports and exits non-zero. It deliberately does NOT install anything: every
# remediation here needs root, and this repo does not take root. The exact
# command is printed instead.
#
# Written because the prerequisites were previously discovered one mid-build
# failure at a time. Each entry below cost a real debugging session.

set -uo pipefail

PROFILE="${1:-all}"
fail=0
FIX=()

ok()   { printf '  \033[32mok\033[0m      %-24s %s\n' "$1" "${2-}"; }
bad()  { printf '  \033[31mMISSING\033[0m %-24s %s\n' "$1" "${2-}"; fail=1; FIX+=("$3"); }
head_() { printf '\n>>> %s\n' "$1"; }

# need <binary> <arch-pkg> <debian-pkg> [why]
need() {
    local exe=$1 arch=$2 deb=$3 why=${4-}
    if p=$(command -v "$exe" 2>/dev/null); then
        ok "$exe" "$p"
    else
        bad "$exe" "$why" "arch: sudo pacman -S $arch   |   debian: sudo apt install $deb"
    fi
}

want_restore() { [ "$PROFILE" = all ] || [ "$PROFILE" = restore ]; }
want_droidian() { [ "$PROFILE" = all ] || [ "$PROFILE" = droidian ]; }

if want_restore; then
    head_ "bootstrap + EDL restore"
    need git    git        git
    need curl   curl       curl
    need unrar  unrar      unrar-free   "extracts the MSM .ops package"
    need python3 python    python3
    # restore-android.py reads /data's fs type out of the release's vendor.img,
    # and build-rootfs.sh builds/points-checks the ext4 images.
    need debugfs   e2fsprogs e2fsprogs "reads fstab.qcom out of vendor.img"
    need mke2fs    e2fsprogs e2fsprogs
    need resize2fs e2fsprogs e2fsprogs
    need e2fsck    e2fsprogs e2fsprogs
    need fastboot  android-tools fastboot
fi

if want_droidian; then
    head_ "droidian build"
    need ar  binutils binutils "unpacks .deb archives"
    need tar tar      tar

    # Container runtime. Droidian's own tooling locates it with `whereis -b
    # docker`, so a podman shim on PATH is enough; our scripts call it directly.
    if p=$(command -v podman 2>/dev/null) || p=$(command -v docker 2>/dev/null); then
        ok "podman/docker" "$p"
    else
        bad "podman/docker" "runs the Droidian build container" \
            "arch: sudo pacman -S podman   |   debian: sudo apt install podman"
    fi

    # arm64 emulation. Cross-building is NOT a fallback here: Droidian's repo
    # ships different systemd versions per architecture (libudev1 257.1 amd64 vs
    # 257.7 arm64) and libudev1 is Multi-Arch: same, so arm64 Qt can never be
    # co-installed in an amd64 container. Native arm64 under qemu is the only
    # way to build anything that links arm64 libraries.
    bf=/proc/sys/fs/binfmt_misc/qemu-aarch64
    if [ ! -e "$bf" ]; then
        bad "binfmt qemu-aarch64" "no aarch64 emulation registered" \
            "arch: sudo pacman -S --needed qemu-user-static qemu-user-static-binfmt && sudo systemctl restart systemd-binfmt   |   debian: sudo apt install qemu-user-static binfmt-support"
    elif ! grep -q '^flags:.*F' "$bf"; then
        # Without F the kernel opens the interpreter from the process's own
        # mount namespace, so it is not visible inside a container.
        bad "binfmt F flag" "registered but lacks the 'F' (fix binary) flag" \
            "reinstall qemu-user-static-binfmt; the F flag is what makes it work inside containers"
    else
        ok "binfmt qemu-aarch64" "$(sed -n 's/^interpreter //p' "$bf")  flags:$(sed -n 's/^flags: //p' "$bf")"
    fi

    # Installing .debs into rootfs.img needs a rootless ext4 mount, which means
    # FUSE. Also requires --device /dev/fuse --cap-add SYS_ADMIN on the run.
    if [ -w /dev/fuse ]; then
        ok "/dev/fuse" "$(stat -c '%A %U:%G' /dev/fuse)"
    else
        bad "/dev/fuse" "needed to mount rootfs.img rootlessly" \
            "load the fuse module and ensure /dev/fuse is world-writable"
    fi
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "All good."
else
    echo "Missing prerequisites. Fix with:"
    printf '  %s\n' "${FIX[@]}"
fi
exit "$fail"
