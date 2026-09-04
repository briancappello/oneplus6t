#!/usr/bin/env bash
#
# Build the Droidian Android kernel for the OnePlus 6T (fajita).
#
#   ./droidian/build-kernel.sh
#
# Produces, in droidian/out/:
#   linux-bootimage-4.9-113-oneplus-fajita_*.deb   -> boot.img, recovery.img, vbmeta.img
#   linux-image-*.deb  linux-headers-*.deb
# and copies the raw images to droidian/out/images/ for flashing.
#
# Why this exists rather than just cloning junocomp's tree:
#
#   * That repo is published WITHOUT debian/control, so it cannot build at all
#     ("Unable to find debian/control"). We carry a reconstructed one, modelled
#     on the droidian-devices/linux-android-fxtec-pro1 reference port.
#   * It targets DEVICE_MODEL=oneplus6 with KERNEL_DEFCONFIG=enchilada_defconfig.
#     We retarget to fajita so the artifacts are unambiguous. fajita_defconfig is
#     byte-identical to enchilada_defconfig -- it contains no device-name strings,
#     only SoC configuration -- so this is a naming change, not a functional one.
#   * The device tree already builds fajita: CONFIG_BUILD_ARM64_DT_OVERLAY=y and
#     arch/arm64/boot/dts/qcom/Makefile lists 10 fajita-*.dtbo overlays alongside
#     the enchilada ones, all on the shared sdm845-v2.1.dtb base.
#
# NOTE ON dtbo: kernel-info.mk sets KERNEL_IMAGE_WITH_DTB_OVERLAY=0 and the
# generated flash-bootimage config says DEVICE_HAS_DTBO_PARTITION=no. Droidian
# relies on the dtbo already present on the device, which for us is OxygenOS 9's
# and already contains the fajita overlays. So unlike flash-pmos.sh, do NOT erase
# dtbo_a when installing Droidian.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

KERNEL_REPO="https://github.com/junocomp/linux-android-oneplus-oneplus6"
KERNEL_BRANCH="droidian"
KERNEL_COMMIT="a11cace73"          # tip of droidian at 2024-01-01

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
    echo ">>> cloning kernel (~1.1 GB)"
    git clone --branch "$KERNEL_BRANCH" --depth 1 "$KERNEL_REPO" "$KERNEL_DIR"
fi
echo ">>> kernel at $(git -C "$KERNEL_DIR" rev-parse --short HEAD)"

echo ">>> applying fajita packaging overlay"
cp -v "$HERE/packaging/debian/"* "$KERNEL_DIR/debian/" 2>/dev/null | sed 's/^/    /' || true
mkdir -p "$KERNEL_DIR/debian/source"
cp "$HERE/packaging/debian/source/format" "$KERNEL_DIR/debian/source/format"
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

echo ">>> extracting images"
IMAGES="$OUT_DIR/images"
rm -rf "$IMAGES" && mkdir -p "$IMAGES"
deb=$(ls "$OUT_DIR"/linux-bootimage-4.9-113-oneplus-fajita_*.deb 2>/dev/null | head -1)
[ -n "$deb" ] || { echo "no bootimage package produced" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
( cd "$tmp" && ar x "$deb" && tar xf data.tar.* )
for f in boot recovery vbmeta; do
    src="$tmp/boot/$f.img-4.9-113-oneplus-fajita"
    [ -f "$src" ] && cp "$src" "$IMAGES/$f.img" && \
        printf '    %-12s %s bytes  %s\n' "$f.img" "$(stat -c%s "$IMAGES/$f.img")" \
        "$(head -c8 "$IMAGES/$f.img" | tr -d '\0')"
done

echo
echo ">>> done. Images in $IMAGES"
