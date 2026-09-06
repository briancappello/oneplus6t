#!/usr/bin/env bash
#
# Build LineageOS 20 (Android 13) for the OnePlus 6T (fajita), from nothing, on
# any Linux box with podman or docker.
#
#   ./lineage/build-lineage.sh image     # build the toolchain container only
#   ./lineage/build-lineage.sh doctor    # check disk, runtime and uid mapping
#   ./lineage/build-lineage.sh sync      # repo init + repo sync (hours, ~200 GB)
#   ./lineage/build-lineage.sh build     # brunch fajita (hours)
#   ./lineage/build-lineage.sh all       # image, doctor, sync, then build
#
# You are meant to hand-edit the tree in $LINEAGE_WORK as your normal user
# between phases; the container bind-mounts it and sees changes immediately,
# with no copy step and no root-owned files. `doctor` is what proves that, and
# `all` runs it before committing to the long phases.
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
        /bin/bash -c "$1"
}
# Deliberately NOT `bash -euo pipefail -c`. AOSP's build/envsetup.sh reads
# plenty of variables that are legitimately unset (TOP, ZSH_VERSION, ...), so
# `set -u` kills the build phase on its first line with "TOP: unbound
# variable", and envsetup returns non-zero in places that `set -e` would treat
# as fatal. AOSP is not written for strict mode and will not be.
#
# Nothing is lost: every caller either runs a single command, whose exit status
# bash returns anyway, or chains its own steps with && and checks explicitly.

# Heartbeat for the long phases. Prints one line a minute so a log tail shows
# forward motion, and so a stall is visible as a flat GB column rather than as
# silence that looks identical to healthy work.
#
# `df` is O(1); `du` on a 200 GB tree is not, and running it every minute would
# generate more I/O than the sync it is reporting on. Project count comes from
# .repo/projects, which repo populates as each project completes.
progress_ticker() {
    local start_mb now_mb mins=0 gb projects
    start_mb=$(df -BM --output=avail "$WORK" | tail -1 | tr -dc '0-9')
    while sleep 60; do
        mins=$((mins + 1))
        now_mb=$(df -BM --output=avail "$WORK" | tail -1 | tr -dc '0-9')
        gb=$(( (start_mb - now_mb) / 1024 ))
        projects=$(find "$WORK/.repo/projects" -maxdepth 4 -name '*.git' 2>/dev/null | wc -l)
        printf '    [%3dm] %4d GB fetched, %4d projects done\n' "$mins" "$gb" "$projects"
    done
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

# Prove the host and the container are the same user on the same tree, in both
# directions. The whole workflow depends on being able to hand-edit the tree as
# yourself between builds and have the container pick it up with no copy step.
# When this breaks it does NOT fail loudly -- it silently leaves root-owned
# files that only surface hours later as a mid-build permission denied, or an
# edit the build never sees.
phase_doctor() {
    check_disk
    echo ">>> runtime: $RT $("$RT" --version | awk '{print $NF}')"
    "$RT" image exists "$IMAGE_TAG" 2>/dev/null \
        || { echo "doctor: image $IMAGE_TAG missing; run: $0 image" >&2; exit 1; }

    local probe="$WORK/.doctor-probe"
    echo "host" > "$probe"
    in_container "test \"\$(cat /aosp/.doctor-probe)\" = host \
                  || { echo 'doctor: container cannot read host-written file' >&2; exit 1; }
                  echo container >> /aosp/.doctor-probe" \
        || { rm -f "$probe"; echo "doctor: container write failed" >&2; exit 1; }

    local owner; owner="$(stat -c '%U' "$probe")"
    if [ "$owner" != "$(id -un)" ]; then
        rm -f "$probe"
        echo "doctor: container wrote files as '$owner', expected '$(id -un)'." >&2
        echo "  Under rootless podman this means --userns=keep-id is not taking" >&2
        echo "  effect; check /etc/subuid and /etc/subgid for $(id -un)." >&2
        exit 1
    fi
    [ -w "$probe" ] || { rm -f "$probe"; echo "doctor: host cannot edit container-written file" >&2; exit 1; }
    rm -f "$probe"
    echo ">>> uid mapping OK: host and container are both $(id -un) ($(id -u):$(id -g)) on $WORK"
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
    # No --git-lfs flag: it is a boolean, not key=value ("--git-lfs option does
    # not take a value"). LFS itself is very much needed -- the chromium-webview
    # prebuilts are LFS objects -- but it is enabled by having the git-lfs binary
    # in the image, which the Containerfile installs, not by this flag.
    #
    # --groups=default,-cts excludes the CTS suite. LineageOS's manifest ships
    # `cts` (LineageOS/android_cts) but NOT tools/tradefederation/core or
    # test/suite_harness, so cts-tradefed and cts-shim-host-lib are defined
    # nowhere in the tree. soong parses Android.bp by walking the filesystem,
    # not the manifest, so merely leaving those projects unsynced is not enough
    # -- the cts directory must not exist at all, or bootstrap dies with:
    #   "CtsApexTestCases" depends on undefined module "cts-tradefed"
    #
    # The usual workaround is ALLOW_MISSING_DEPENDENCIES=true, deliberately NOT
    # used here: it downgrades EVERY missing dependency to a warning and
    # silently disables the module. On a device port that is precisely the
    # signal we need to stay loud -- a missing vendor blob or HAL must fail the
    # build, not quietly vanish from the image. Excluding one unbuildable test
    # suite keeps strict dependency checking for everything that matters.
    in_container "repo init \
        -u '$MANIFEST_URL' \
        -b '$MANIFEST_REV' \
        --repo-rev='$REPO_REV' \
        --groups='default,-cts' \
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

    # A project dropped from the group set still has to leave the filesystem,
    # because soong discovers Android.bp by walking the tree. repo will not do
    # it once the checkout is dirty -- it stops the whole sync with "cts: Cannot
    # remove project: uncommitted changes are present" -- and building once
    # leaves generated files behind, so the second run is always the dirty one.
    #
    # Removed directly rather than with repo's --force-remove-dirty, which would
    # apply to every project at once and silently discard hand edits elsewhere
    # in the tree. The group exclusion is what stops it coming back.
    if [ -d "$WORK/cts" ]; then
        echo ">>> removing cts/ (excluded via --groups, repo cannot delete it while dirty)"
        rm -rf "$WORK/cts"
    fi

    echo ">>> repo sync -j$SYNC_JOBS (hours, ~200 GB)"
    # repo calls isatty() and suppresses its progress bar completely when stdout
    # is a file -- which is exactly what the `setsid nohup ... > log` launch this
    # script is designed for produces. So a multi-hour sync prints NOTHING and is
    # indistinguishable from a hang. Emit our own heartbeat instead.
    #
    # Progress is measured with df, not du: du has to walk a tree heading for
    # 200 GB and would cost more I/O than the thing it is reporting on.
    progress_ticker &
    local ticker=$!
    trap 'kill "$ticker" 2>/dev/null || true' EXIT
    # -c            only the branch we pinned, not every branch upstream has
    # --no-tags     tags are worth tens of GB across ~1000 repos and we pin SHAs
    # --force-sync  lets a repo whose path changed upstream re-checkout instead
    #               of wedging the whole sync
    local rc=0
    in_container "repo sync -j$SYNC_JOBS -c --no-tags --no-clone-bundle \
        --force-sync --fail-fast" || rc=$?
    kill "$ticker" 2>/dev/null || true
    trap - EXIT
    [ "$rc" -eq 0 ] || { echo "build-lineage.sh: repo sync failed (rc=$rc)" >&2; exit "$rc"; }

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
    # `lunch`, NOT `breakfast`. breakfast is lunch plus roomservice, and
    # roomservice resolves lineage.dependencies over the network and writes its
    # findings to .repo/local_manifests/roomservice.xml using floating branch
    # names. That would silently un-pin the tree this script exists to pin. Every
    # repo roomservice would look for is already present and at a known commit,
    # so there is nothing for it to do except damage.
    #
    # Steps are chained with && because in_container runs without `set -e`
    # (see the note there); without the chain a failed lunch would still run m.
    in_container "ccache -M ${CCACHE_GB}G >/dev/null &&
        source build/envsetup.sh &&
        lunch $LUNCH_TARGET &&
        m -j$BUILD_JOBS bacon"
    echo ">>> build complete; images under $WORK/out/target/product/fajita"
}

case "${1:-all}" in
    image)  phase_image ;;
    doctor) phase_doctor ;;
    sync)   phase_sync ;;
    build)  phase_build ;;
    all)    phase_image; phase_doctor; phase_sync; phase_build ;;
    *) echo "usage: build-lineage.sh [image|doctor|sync|build|all]" >&2; exit 1 ;;
esac
