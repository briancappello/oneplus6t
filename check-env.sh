#!/usr/bin/env bash
#
# Verify this machine has everything the repo's scripts need, for a given role.
#
#   ./check-env.sh            # everything
#   ./check-env.sh build      # worker: builds artifacts, never touches a phone
#   ./check-env.sh flash      # the machine the phone is plugged into
#   BUILD_HOST=taichi ./check-env.sh flash   # also checks the worker is reachable
#
# Reports and exits non-zero. It deliberately does NOT install anything: every
# remediation here needs root, and this repo does not take root. The exact
# command is printed instead.
#
# Written because the prerequisites were previously discovered one mid-build
# failure at a time. Each entry below cost a real debugging session.

set -uo pipefail

PROFILE="${1:-all}"
BUILD_HOST="${BUILD_HOST:-}"
fail=0
FIX=()

ok()    { printf '  \033[32mok\033[0m      %-24s %s\n' "$1" "${2-}"; }
bad()   { printf '  \033[31mMISSING\033[0m %-24s %s\n' "$1" "${2-}"; fail=1; FIX+=("$3"); }
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

want() { [ "$PROFILE" = all ] || [ "$PROFILE" = "$1" ]; }

# Shared by both roles.
if want build || want flash; then
    head_ "common"
    need git     git    git
    need curl    curl   curl
    need python3 python python3
fi

if want flash; then
    head_ "flash (needs the phone attached)"
    need unrar     unrar         unrar-free "extracts the MSM .ops package"
    # restore-android.py reads /data's filesystem type out of the release's own
    # vendor.img rather than trusting the bootloader, which answers f2fs and
    # bootloops the device.
    need debugfs   e2fsprogs     e2fsprogs  "reads fstab.qcom out of vendor.img"
    need mke2fs    e2fsprogs     e2fsprogs
    need resize2fs e2fsprogs     e2fsprogs
    need e2fsck    e2fsprogs     e2fsprogs
    need fastboot  android-tools fastboot
fi

if want build; then
    head_ "build (worker; no phone required)"
    need ar  binutils binutils "unpacks .deb archives"
    need tar tar      tar

    if p=$(command -v podman 2>/dev/null) || p=$(command -v docker 2>/dev/null); then
        ok "podman/docker" "$p"
    else
        bad "podman/docker" "runs the Droidian build container" \
            "arch: sudo pacman -S podman   |   debian: sudo apt install podman"
    fi

    # arm64 emulation. Cross-building is NOT a fallback: Droidian's repo ships
    # different systemd versions per architecture (libudev1 257.1 amd64 vs
    # 257.7 arm64) and libudev1 is Multi-Arch: same, so arm64 Qt can never be
    # co-installed in an amd64 container. Native arm64 under qemu is the only
    # way to build anything linking arm64 libraries.
    bf=/proc/sys/fs/binfmt_misc/qemu-aarch64
    if [ ! -e "$bf" ]; then
        bad "binfmt qemu-aarch64" "no aarch64 emulation registered" \
            "arch: sudo pacman -S --needed qemu-user-static qemu-user-static-binfmt && sudo systemctl restart systemd-binfmt   |   debian: sudo apt install qemu-user-static binfmt-support"
    elif ! grep -q '^flags:.*F' "$bf"; then
        # Without F the kernel opens the interpreter from the calling process's
        # mount namespace, so it is invisible inside a container.
        bad "binfmt F flag" "registered but lacks the 'F' (fix binary) flag" \
            "reinstall qemu-user-static-binfmt; the F flag is what makes it work inside containers"
    else
        ok "binfmt qemu-aarch64" \
           "$(sed -n 's/^interpreter //p' "$bf")  flags:$(sed -n 's/^flags: //p' "$bf")"
    fi

    # Installing .debs into rootfs.img mounts it rootlessly with fuse2fs, which
    # also needs --device /dev/fuse --cap-add SYS_ADMIN on the container run.
    if [ -w /dev/fuse ]; then
        ok "/dev/fuse" "$(stat -c '%A %U:%G' /dev/fuse)"
    else
        bad "/dev/fuse" "needed to mount rootfs.img rootlessly" \
            "load the fuse module and ensure /dev/fuse is world-writable"
    fi
fi

# Only relevant when delegating builds to a worker. Neither role above covers
# this, and it is exactly the sort of thing that fails at the worst moment.
if [ -n "$BUILD_HOST" ]; then
    head_ "remote worker: $BUILD_HOST"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "$BUILD_HOST" true 2>/dev/null; then
        ok "ssh $BUILD_HOST" "reachable"
        if ! ssh -o BatchMode=yes "$BUILD_HOST" 'test -d ~/oneplus6t/.git' 2>/dev/null; then
            bad "repo on $BUILD_HOST" "no checkout at ~/oneplus6t" \
                "on $BUILD_HOST: git clone https://github.com/briancappello/oneplus6t ~/oneplus6t"
        elif ! ssh -o BatchMode=yes "$BUILD_HOST" 'test -x ~/oneplus6t/build.sh' 2>/dev/null; then
            bad "build.sh on $BUILD_HOST" "checkout is present but predates build.sh" \
                "on $BUILD_HOST: git -C ~/oneplus6t pull"
        else
            ok "repo on $BUILD_HOST" \
               "$(ssh -o BatchMode=yes "$BUILD_HOST" 'git -C ~/oneplus6t rev-parse --short HEAD' 2>/dev/null)"
        fi
    else
        bad "ssh $BUILD_HOST" "not reachable with BatchMode" \
            "check ssh keys and that $BUILD_HOST resolves"
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
