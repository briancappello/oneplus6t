#!/usr/bin/env bash
#
# Build a patched droidian-camera for the OnePlus 6T (fajita).
#
#   ./droidian/build-camera.sh
#
# Produces droidian/out-camera/droidian-camera_*_arm64.deb
#
# Why we fork an upstream app at all:
#
#   src/qml/main.qml hardcodes `focusMode: Camera.FocusMacro` -- Qt's "focus on
#   objects close to the camera". The viewfinder is therefore sharp a few inches
#   out and blurry at any real distance, on EVERY Droidian device, not just this
#   one. Tapping appears to fix it only because the tap handler calls
#   searchAndLock(), which runs a fresh AF sweep; the mode itself stays macro.
#
#   The QML is compiled into the binary's qrc (qrc:/main.qml), so this cannot be
#   overridden by a config file, a drop-in or an environment variable. Rebuilding
#   is the only option.
#
# The patch picks the best mode the HAL actually advertises
# (continuous -> auto -> macro), guarded by isFocusModeSupported, rather than
# swapping one hardcoded assumption for another. That is also what makes it
# suitable to send upstream.
#
# Pinned to the commit that is currently installed on the device, so the focus
# change is the ONLY variable. Upstream HEAD carries unrelated trixie/UI
# refactors we have not tested.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CAMERA_REPO="https://github.com/droidian/droidian-camera"
CAMERA_BRANCH="droidian"
CAMERA_COMMIT="a0b51cd"        # == the version shipped in the api28 rootfs

# Built NATIVELY for arm64 under qemu-user-static, not cross-compiled.
#
# Cross-building this is impossible, not merely awkward. Droidian's repo ships
# different systemd versions per architecture -- libudev1 is 257.1 for amd64 and
# 257.7 for arm64 -- and libudev1 is Multi-Arch: same, which demands identical
# versions across architectures. The chain
#   qtbase5-dev:arm64 -> libqt5gui5t64:arm64 -> libudev1:arm64
# therefore can never be satisfied inside an amd64 container, and there is no
# 257.7 amd64 to upgrade to. releng-build-package also runs mk-build-deps with
# no --host-arch, so build-deps always install for the build architecture.
#
# The kernel misleads here: it cross-builds fine only because it brings its own
# Android toolchain and needs zero arm64 library packages.
#
# Requires binfmt qemu-aarch64 with the F flag -- run ./check-env.sh.
IMAGE="quay.io/droidian/build-essential:current-arm64"

SRC_DIR="$HERE/camera-src"
OUT_DIR="$HERE/out-camera"
REPO_DIR="$HERE/local-repo"
LOG="$OUT_DIR/build.log"

runtime() {
    command -v docker >/dev/null && { echo docker; return; }
    command -v podman >/dev/null && { echo podman; return; }
    echo "Need docker or podman." >&2; exit 1
}

mkdir -p "$OUT_DIR" "$REPO_DIR"

if [ ! -d "$SRC_DIR/.git" ]; then
    echo ">>> cloning droidian-camera"
    git clone -q --branch "$CAMERA_BRANCH" "$CAMERA_REPO" "$SRC_DIR"
fi

echo ">>> resetting to pinned commit $CAMERA_COMMIT"
git -C "$SRC_DIR" checkout -q --force "$CAMERA_COMMIT"
git -C "$SRC_DIR" clean -qfd

echo ">>> applying patches"
for p in "$HERE"/packaging-camera/patches/*.patch; do
    [ -e "$p" ] || continue
    name=$(basename "$p")
    if git -C "$SRC_DIR" apply --reverse --check "$p" 2>/dev/null; then
        echo "    $name (already applied)"
    elif git -C "$SRC_DIR" apply "$p" 2>/dev/null; then
        echo "    $name"
    else
        echo "    $name FAILED TO APPLY" >&2
        exit 1
    fi
done

# Commit the patch so releng derives a version newer than the installed one.
# Without this the rebuilt package has an identical version string and dpkg
# refuses to replace it.
git -C "$SRC_DIR" -c user.email=build@localhost -c user.name=build \
    commit -qam "focus: use the best supported mode instead of macro" || true
echo ">>> building $(git -C "$SRC_DIR" rev-parse --short HEAD)"

rm -f "$SRC_DIR/debian/changelog"   # regenerated; a stale one breaks releng

# No RELENG_HOST_ARCH: this is a native arm64 build, not a cross build, so
# releng's mk-build-deps resolves upstream's own Build-Depends normally.
# apt-get update is still required -- the image's index is stale.
$(runtime) run --rm --arch arm64 \
    -v "$OUT_DIR":/buildd \
    -v "$SRC_DIR":/buildd/sources \
    -v "$REPO_DIR":/buildd/local-repo \
    -e RELENG_FULL_BUILD=yes \
    "$IMAGE" \
    /bin/sh -c 'apt-get update -qq && cd /buildd/sources && releng-build-package' 2>&1 | tee "$LOG"

deb=$(ls "$OUT_DIR"/droidian-camera_*_arm64.deb 2>/dev/null | head -1)
[ -n "$deb" ] || { echo "no droidian-camera package produced; see $LOG" >&2; exit 1; }

echo
echo ">>> done"
printf '    %s  %s bytes\n' "$deb" "$(stat -c%s "$deb")"
