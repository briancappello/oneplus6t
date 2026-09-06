#!/usr/bin/env bash
#
# Build LineageOS 20 (Android 13) for the OnePlus 6T (fajita), from nothing, on
# any Linux box with podman or docker.
#
#   ./lineage/build-lineage.sh image     # build the toolchain container only
#   ./lineage/build-lineage.sh sync      # repo init + repo sync (hours, ~200 GB)
#   ./lineage/build-lineage.sh build     # brunch fajita (hours)
#   ./lineage/build-lineage.sh all       # image, then sync, then build
#
# Environment:
#   LINEAGE_WORK   source tree + out/ + ccache   (default: $HOME/lineage20)
#   SYNC_JOBS      repo sync parallelism         (default: 8)
#   BUILD_JOBS     make parallelism              (default: nproc)
#   MIN_FREE_GB    disk guard at LINEAGE_WORK    (default: 300)
#   CCACHE_GB      ccache size                   (default: 50)
#   RUNTIME        force "podman" or "docker"    (default: autodetect)
#
# WHY the tree lives on the host and is bind-mounted in, rather than in the
# image or a named volume: it is ~200 GB and takes hours to fetch. Rebuilding
# the toolchain image must never cost a re-sync, and `podman rmi` must never
# destroy it. The image is disposable; the tree is not.
#
# WHY LINEAGE_WORK defaults OUTSIDE this repository: provision.sh's remote_build
# resets the worker's checkout of this repo from a bundle on every run. A 200 GB
# tree inside the checkout would be at the mercy of that. Keep them separate.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="${LINEAGE_WORK:-$HOME/lineage20}"
SYNC_JOBS="${SYNC_JOBS:-8}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
MIN_FREE_GB="${MIN_FREE_GB:-300}"
CCACHE_GB="${CCACHE_GB:-50}"

IMAGE_TAG="lineage20-build:fajita"

# The LineageOS manifest. The branch is lineage-20.0, NOT lineage-20 -- the
# latter does not exist on LineageOS/android and `repo init -b lineage-20`
# fails outright. The device and blob repos DO use lineage-20; only the
# manifest repo carries the .0. Pinned to a commit so the platform side is as
# reproducible as the device side.
MANIFEST_URL="https://github.com/LineageOS/android.git"
MANIFEST_REV="${MANIFEST_REV:-569c0d5ee26a7ebbda1e1bd91dc6f7e392c67fd7}"

# The repo launcher in the image is only a bootstrap; it downloads the real
# git-repo into .repo/repo at init time. Pin that too, or the tool building our
# reproducible tree is itself unpinned.
REPO_REV="${REPO_REV:-v2.45}"

LUNCH_TARGET="lineage_fajita-userdebug"

# ------------------------------------------------------------------ container

# podman is preferred but docker works. build-kernel.sh makes the same choice
# the same way; keep them in step.
runtime() {
    if [ -n "${RUNTIME:-}" ]; then echo "$RUNTIME"; return; fi
    command -v podman >/dev/null && { echo podman; return; }
    command -v docker >/dev/null && { echo docker; return; }
    echo "build-lineage.sh: need podman or docker." >&2; exit 1
}
RT="$(runtime)"

# Everything the container writes lands in a host bind mount, so it must land
# owned by the invoking user on any machine -- that is the "any machine" half
# of this script's job.
#
#   rootless podman: --userns=keep-id maps the host UID to the same UID inside,
#                    and the process already runs as it. Adding --user on top
#                    fights with keep-id, so it is deliberately absent.
#   docker:          runs as root by default and has no keep-id, so pass the
#                    host UID/GID explicitly.
#
# Rootful podman behaves like docker here, hence the rootless test rather than
# a bare "is it podman".
id_args() {
    if [ "$RT" = podman ] && [ "$(id -u)" -ne 0 ]; then
        printf '%s\n' --userns=keep-id
    else
        printf '%s\n' --user "$(id -u):$(id -g)"
    fi
}

# Run a command inside the toolchain image with the tree mounted at /aosp.
#
# HOME points inside the mount because repo and git both insist on a writable
# home, and a home on a tmpfs would throw away the git object cache between
# phases. :z relabels for SELinux hosts (Fedora, RHEL) and is a no-op elsewhere.
in_container() {
    "$RT" run --rm -i \
        $(id_args) \
        -v "$WORK":/aosp:z \
        -e HOME=/aosp/.home \
        -e USE_CCACHE=1 \
        -e CCACHE_EXEC=/usr/bin/ccache \
        -e CCACHE_DIR=/aosp/.ccache \
        -w /aosp \
        "$IMAGE_TAG" \
        /bin/bash -euo pipefail -c "$1"
}

# ---------------------------------------------------------------- preflight

# A LineageOS 20 tree plus out/ and ccache is ~300 GB. Finding that out four
# hours into a sync, from a disk-full error, is the failure this prevents. The
# roadmap requires this check to live in the script and not in a shell history.
check_disk() {
    mkdir -p "$WORK"
    local free_gb
    free_gb=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc '0-9')
    echo ">>> $WORK has ${free_gb} GB free (need ${MIN_FREE_GB} GB)"
    if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
        echo "build-lineage.sh: not enough free space at $WORK:" >&2
        echo "  have ${free_gb} GB, need ${MIN_FREE_GB} GB." >&2
        echo "  Set LINEAGE_WORK to a bigger disk, or MIN_FREE_GB to override." >&2
        exit 1
    fi
}

# repo refuses to init without a git identity, and the container has no user
# database. Seed one in the mounted HOME. Values are placeholders; nothing here
# is ever pushed.
seed_home() {
    mkdir -p "$WORK/.home" "$WORK/.ccache"
    [ -f "$WORK/.home/.gitconfig" ] && return
    cat > "$WORK/.home/.gitconfig" <<'EOF'
[user]
	name = lineage builder
	email = builder@localhost
[color]
	ui = false
[advice]
	detachedHead = false
EOF
    echo ">>> seeded $WORK/.home/.gitconfig"
}

# --------------------------------------------------------------------- phases

phase_image() {
    echo ">>> building toolchain image $IMAGE_TAG with $RT"
    "$RT" build -t "$IMAGE_TAG" -f "$HERE/Containerfile" "$HERE"
    # podman refuses to start when a bind-mount source is missing ("statfs
    # ...: no such file or directory") where docker would silently create it.
    # in_container always mounts $WORK, so it has to exist even for a phase
    # that does not otherwise care about the tree.
    mkdir -p "$WORK"
    in_container 'echo "    repo:  $(repo --version 2>/dev/null | head -1)"
                  echo "    java:  $(java -version 2>&1 | head -1)"
                  echo "    glibc: $(ldd --version | head -1)"' || true
}

phase_sync() {
    check_disk
    seed_home

    # Clear stale local manifests BEFORE init. `repo init` parses whatever is
    # already in .repo/local_manifests, so a malformed one left by a previous
    # failed run blocks init itself -- before the cp below could ever replace
    # it. That wedges the tree permanently and the error names a line number in
    # a file you are looking at in its fixed form. This is the only ordering
    # that lets a bad manifest be recovered from by re-running.
    rm -rf "$WORK/.repo/local_manifests"

    echo ">>> repo init: manifest $MANIFEST_REV, repo $REPO_REV"
    # Deliberately NOT --depth=1. repo propagates the manifest depth to every
    # project fetch, and a shallow fetch can only resolve a revision that is
    # still the tip of its branch. Our six pins are tips today, so it would
    # work today and break silently the moment upstream moves -- and Phase 3
    # needs real history in kernel/oneplus/sdm845 to rebase Halium patches
    # onto. -c and --no-tags below recover most of the space without that
    # fragility, and the disk guard already proved we have the headroom.
    # No --git-lfs: it is a boolean flag, not key=value ("--git-lfs option does
    # not take a value"), and LineageOS 20 has no LFS objects to fetch anyway.
    in_container "repo init \
        -u '$MANIFEST_URL' \
        -b '$MANIFEST_REV' \
        --repo-rev='$REPO_REV' \
        --no-clone-bundle"

    # The local manifest must be in place BEFORE the sync, or the device,
    # kernel and blob repos are simply absent and `lunch` fails with an
    # unhelpful "device not found".
    mkdir -p "$WORK/.repo/local_manifests"
    cp "$HERE/local_manifest.xml" "$WORK/.repo/local_manifests/fajita.xml"

    # repo only parses the local manifest once it is deep into `sync`, and it
    # reports a malformed one as "not well-formed (invalid token): line N" with
    # no filename context. Checking it here turns a failure discovered hours in
    # into one discovered now. python3 is guaranteed by the toolchain image.
    in_container "python3 -c \"import xml.dom.minidom,sys
xml.dom.minidom.parse('/aosp/.repo/local_manifests/fajita.xml')\"" \
        || { echo "build-lineage.sh: local_manifest.xml is not well-formed XML." >&2
             echo "  A double hyphen inside an XML comment is the usual cause." >&2
             exit 1; }

    echo ">>> installed local manifest ($(grep -c '<project' "$HERE/local_manifest.xml") pinned projects)"

    echo ">>> repo sync -j$SYNC_JOBS (hours, ~200 GB)"
    # -c            only the branch we pinned, not every branch upstream has
    # --no-tags     tags are worth tens of GB across ~1000 repos and we pin SHAs
    # --force-sync  lets a repo whose path changed upstream re-checkout instead
    #               of wedging the whole sync
    in_container "repo sync -j$SYNC_JOBS -c --no-tags --no-clone-bundle \
        --force-sync --fail-fast"

    echo ">>> sync complete"
    in_container 'for d in device/oneplus/fajita device/oneplus/sdm845-common \
                           hardware/oneplus kernel/oneplus/sdm845 \
                           vendor/oneplus/fajita vendor/oneplus/sdm845-common; do
                      printf "    %-38s %s\n" "$d" "$(git -C "$d" rev-parse --short HEAD 2>&1)"
                  done'
}

phase_build() {
    check_disk
    echo ">>> brunch $LUNCH_TARGET with -j$BUILD_JOBS"
    in_container "ccache -M ${CCACHE_GB}G >/dev/null
        source build/envsetup.sh
        breakfast $LUNCH_TARGET
        m -j$BUILD_JOBS bacon"
    echo ">>> build complete; images under $WORK/out/target/product/fajita"
}

case "${1:-all}" in
    image) phase_image ;;
    sync)  phase_sync ;;
    build) phase_build ;;
    all)   phase_image; phase_sync; phase_build ;;
    *) echo "usage: build-lineage.sh [image|sync|build|all]" >&2; exit 1 ;;
esac
