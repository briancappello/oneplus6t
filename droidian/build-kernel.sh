#!/usr/bin/env bash
#
# Build the Droidian Android kernel for the OnePlus 6T (fajita).
#
#   ./droidian/build-kernel.sh
#
# Produces, in droidian/out/:
#   linux-bootimage-4.9-337-oneplus-fajita_*.deb   -> boot.img, recovery.img, vbmeta.img
#   linux-image-*.deb  linux-headers-*.deb
#   config-4.9-337-oneplus-fajita                  -> the .config actually built
# and copies the raw images to droidian/out/images/ for flashing.
#
# Why this exists rather than just building the LineageOS tree as-is:
#
#   * The LineageOS kernel repo has no debian/ directory; it is built by the
#     Android build system. We carry a debian/ overlay (droidian/packaging/,
#     modelled on the droidian-devices/linux-android-fxtec-pro1 reference port)
#     so releng-build-package can turn it into the linux-image / linux-bootimage
#     .debs the Droidian rootfs and its flash-on-upgrade hooks expect.
#   * LineageOS ships enchilada_defconfig for both enchilada and fajita; the
#     bootloader picks the fajita DT overlays from dtbo. We install our own
#     fajita_defconfig = enchilada_defconfig + a reviewed Halium delta
#     (namespaces, devtmpfs, apparmor, module signing off, ...). See
#     docs/plans/2026-09-06-los20-kernel.md.
#   * Local fixes go in as patches under droidian/packaging/patches/, applied
#     idempotently below. The tree itself is never hand-edited: everything this
#     script builds is the pinned commit plus what is committed in this repo.
#
# NOTE ON dtbo: kernel-info.mk sets KERNEL_IMAGE_WITH_DTB_OVERLAY=0 and the
# generated flash-bootimage config says DEVICE_HAS_DTBO_PARTITION=no. Droidian
# relies on the dtbo already on the slot, which is LineageOS 20's and contains
# the fajita overlays. Do NOT erase dtbo when installing Droidian.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# LineageOS's lineage-20 kernel: the exact commit Phase 2's LineageOS 20
# boot.img was built from (the running kernel reports 4.9.337-g7fbf93e22944),
# so every divergence between this build and LineageOS's is ours. Replaces
# the junocomp 4.9.113 tree; techpack/audio is in-tree here, no side checkout.
KERNEL_REPO="https://github.com/LineageOS/android_kernel_oneplus_sdm845"
KERNEL_BRANCH="lineage-20"
KERNEL_COMMIT="7fbf93e229443b8366c18eaa0ea70dd499749e37"   # tip of lineage-20, 4.9.337

# Derived once; the deb name, the image suffix and debian/control all carry
# this string, and the 4.9.113 -> 4.9.337 rename found it in three places.
KVER="4.9-337"

# bookworm-amd64 was last rebuilt in May 2024 and every Droidian apt repo now
# fails signature checks inside it (NO_PUBKEY 5E775B2A27AB0C94, plus an expired
# Mobian key), which stalls the build at dependency resolution. current-amd64 is
# rebuilt continuously.
IMAGE="quay.io/droidian/build-essential:current-amd64"

KERNEL_DIR="$HERE/kernel"
OUT_DIR="$HERE/out"
REPO_DIR="$HERE/local-repo"
LOG="$OUT_DIR/build.log"

# Droidian's tooling locates the runtime with `whereis -b docker`. podman is a
# drop-in; a shim on PATH avoids needing Docker or root at all.
runtime() {
    command -v docker >/dev/null && { echo docker; return; }
    command -v podman >/dev/null && { echo podman; return; }
    echo "Need docker or podman." >&2; exit 1
}

mkdir -p "$OUT_DIR" "$REPO_DIR"

if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo ">>> cloning kernel (~2 GB)"
    git clone --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
fi
# Check out the pin explicitly. `--branch` alone fetches whatever the branch
# tip is on clone day; that is this commit today and something else after
# the next upstream push. Not --depth 1: a shallow clone cannot check out a
# SHA that has moved off the tip, which is exactly when the pin matters.
git -C "$KERNEL_DIR" checkout -q "$KERNEL_COMMIT"
[ "$(git -C "$KERNEL_DIR" rev-parse HEAD)" = "$KERNEL_COMMIT" ] \
    || { echo "kernel tree is not at $KERNEL_COMMIT" >&2; exit 1; }
echo ">>> kernel at $(git -C "$KERNEL_DIR" rev-parse --short HEAD) ($(git -C "$KERNEL_DIR" describe --tags --always 2>/dev/null))"

echo ">>> applying fajita packaging overlay"
# The LineageOS tree has no debian/ at all (the junocomp tree did). mkdir
# must come BEFORE the copy, and the copy must be allowed to fail loudly:
# the previous `2>/dev/null ... || true` turned "destination directory does
# not exist" into a silent no-op, and the build then died an hour later in
# releng-build-changelog with "Unable to find debian/control".
mkdir -p "$KERNEL_DIR/debian/source"
# Files only: the glob also matches the source/ directory, which cp without
# -r rejects with exit 1, and under pipefail that exit escapes the `| sed`
# and set -e kills the script right here, before "applying patches". The
# source/ subdirectory has exactly one file and is copied on its own below.
find "$HERE/packaging/debian" -maxdepth 1 -type f -print0 \
    | xargs -0 -I{} cp -v {} "$KERNEL_DIR/debian/" | sed 's/^/    /'
cp "$HERE/packaging/debian/source/format" "$KERNEL_DIR/debian/source/format"
[ -f "$KERNEL_DIR/debian/control" ] \
    || { echo "packaging overlay did not land: no debian/control in $KERNEL_DIR" >&2; exit 1; }

# debian/control repeats kernel-info.mk's DEB_TOOLCHAIN inline in
# Build-Depends, and control is what apt reads. Updating one and not the
# other installed clang 6.0 against a BUILD_PATH for clang 14, twice. Assert
# they agree before spending a build on it.
mk_tc="$(sed -n 's/^DEB_TOOLCHAIN = //p' "$HERE/packaging/debian/kernel-info.mk")"
grep -qF "$mk_tc" "$HERE/packaging/debian/control" \
    || { echo "DEB_TOOLCHAIN in kernel-info.mk is not in debian/control Build-Depends:" >&2
         echo "  $mk_tc" >&2; exit 1; }
cp -v "$HERE/packaging/arch/arm64/configs/fajita_defconfig" \
      "$KERNEL_DIR/arch/arm64/configs/fajita_defconfig" | sed 's/^/    /'
# regenerated from git history by releng-build-changelog; a stale one breaks it
rm -f "$KERNEL_DIR/debian/changelog"

if [ -d "$HERE/packaging/patches" ]; then
    echo ">>> applying patches"
    for p in "$HERE"/packaging/patches/*.patch; do
        [ -e "$p" ] || continue
        name=$(basename "$p")
        # Idempotent: skip if already applied, fail loudly if it does not apply.
        if git -C "$KERNEL_DIR" apply --reverse --check "$p" 2>/dev/null; then
            echo "    $name (already applied)"
        elif git -C "$KERNEL_DIR" apply "$p" 2>/dev/null; then
            echo "    $name"
        else
            echo "    $name FAILED TO APPLY" >&2
            exit 1
        fi
    done
fi

echo ">>> building in $IMAGE (this takes a while; log: $LOG)"
$(runtime) run --rm \
    -v "$OUT_DIR":/buildd \
    -v "$KERNEL_DIR":/buildd/sources \
    -v "$REPO_DIR":/buildd/local-repo \
    -e RELENG_FULL_BUILD=yes \
    -e RELENG_HOST_ARCH=arm64 \
    "$IMAGE" \
    /bin/sh -c 'cd /buildd/sources && releng-build-package' 2>&1 | tee "$LOG"

# Publish the .config the build actually used, so kernel-config-check.sh can
# assert the Halium delta held rather than trusting that olddefconfig kept
# every line. `|| true`: a missing copy must not fail a build that succeeded.
cp "$KERNEL_DIR/.config" "$OUT_DIR/config-$KVER-oneplus-fajita" 2>/dev/null || true

echo ">>> extracting images"
IMAGES="$OUT_DIR/images"
rm -rf "$IMAGES" && mkdir -p "$IMAGES"
deb=$(ls "$OUT_DIR"/linux-bootimage-"$KVER"-oneplus-fajita_*.deb 2>/dev/null | head -1)
[ -n "$deb" ] || { echo "no bootimage package produced" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
( cd "$tmp" && ar x "$deb" && tar xf data.tar.* )
for f in boot recovery vbmeta; do
    src="$tmp/boot/$f.img-$KVER-oneplus-fajita"
    [ -f "$src" ] && cp "$src" "$IMAGES/$f.img" && \
        printf '    %-12s %s bytes  %s\n' "$f.img" "$(stat -c%s "$IMAGES/$f.img")" \
        "$(head -c8 "$IMAGES/$f.img" | tr -d '\0')"
done

echo
echo ">>> done. Images in $IMAGES"
