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
# 100 GB, not 50: Phase 3 rebuilds this kernel repeatedly and the C/C++ half of
# the tree is what ccache actually accelerates. Cheap against 585 GB free.
CCACHE_GB="${CCACHE_GB:-100}"

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
    # --pids-limit is NOT optional at -j32. podman defaults the container cgroup
    # to pids.max=2048, and the Java half of an AOSP build runs dozens of r8/d8
    # JVMs in parallel, each with its own ForkJoinPool. The ceiling is reached
    # around 96%, deep into the Java targets, and the failure does not name it:
    #   runtime: failed to create new OS thread (have 8 already; errno=11)
    #   pthread_create failed (EAGAIN)
    #   java.lang.OutOfMemoryError: unable to create native thread
    # That reads like memory exhaustion and is not -- the box had 50 GB free.
    #
    # An explicit large number rather than "unlimited": podman and docker
    # disagree on whether 0 or -1 means unlimited, and 32768 is unambiguous to
    # both while still far below the host's 375354.
    # 63 MB is podman's default /dev/shm and nobody chose it. Java tooling and
    # some AOSP host binaries use shared memory, and the last default we left
    # unexamined surfaced at 96% of a multi-hour build.
    "$RT" run --rm -i \
        --pids-limit=32768 \
        --shm-size=2g \
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

# Refuse to start when this tree already has a run in progress.
#
# Two concurrent runs do NOT fail cleanly. The second one's soong waits 10s for
# out/.lock, gives up, and prints "failed to build some targets (10 seconds)"
# -- while the first keeps going. And because both are launched with
# `> ~/lineage20-build.log`, the second TRUNCATES the log the first is still
# writing to, so the surviving build becomes invisible: no progress, no error
# count, nothing. Diagnosing that from the outside is near impossible, which is
# exactly what happened.
guard_single_instance() {
    local running
    running="$("$RT" ps --filter "ancestor=$IMAGE_TAG" --format '{{.ID}} {{.Status}}' 2>/dev/null | head -1)"
    [ -n "$running" ] || return 0
    echo "build-lineage.sh: a run is already using $WORK ($running)." >&2
    echo "  Two soong processes collide on out/.lock and the second dies in 10s," >&2
    echo "  and its log redirect truncates the log the first is still writing." >&2
    echo "  Stop the existing run first:" >&2
    echo "    pkill -f lineage/build-lineage.sh && $RT rm -f -a" >&2
    exit 1
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
    # Always rewritten, never skipped when present: an early run created this
    # file without the lfs filters, and skipping meant the fix could never
    # reach an existing tree. The content is fully determined by this script,
    # so rewriting costs nothing.
    #
    # The [filter "lfs"] block is what `git lfs install` would write. Without
    # it git never invokes git-lfs during checkout, so LFS-backed files are
    # silently not created at all -- not even as pointer files. That surfaces
    # much later as ninja: "external/chromium-webview/prebuilt/arm64/webview.apk
    # missing and no known rule to make it".
    cat > "$WORK/.home/.gitconfig" <<'EOF'
[user]
	name = lineage builder
	email = builder@localhost
[color]
	ui = false
[advice]
	detachedHead = false
[filter "lfs"]
	clean = git-lfs clean -- %f
	smudge = git-lfs smudge -- %f
	process = git-lfs filter-process
	required = true
EOF
    echo ">>> seeded $WORK/.home/.gitconfig (with git-lfs filters)"
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
    # Full default groups. An earlier version passed --groups=default,-cts to
    # drop the CTS suite, whose cts-tradefed dependency LineageOS does not ship.
    # That was wrong: the `cts` GROUP is not just the cts project. It also
    # contains platform_testing and tools/trebuchet, and tools/trebuchet defines
    # jsonlib, which frameworks/base/tools/protologtool genuinely needs. The
    # build then died 6 minutes in with "module protologtool-lib missing
    # dependencies: jsonlib".
    #
    # The missing CTS modules are handled where they belong, with
    # ALLOW_MISSING_DEPENDENCIES in phase_build, rather than by removing
    # projects that carry real build dependencies alongside test code.
    # --groups=default is passed EXPLICITLY and must stay that way. `repo init`
    # persists the previous run's --groups in .repo/manifests.git/config; simply
    # omitting the flag does NOT restore the default, it silently keeps whatever
    # was set before. After dropping an earlier --groups=default,-cts the config
    # still read "default,-cts,platform-linux", the excluded projects stayed
    # deleted, and the build failed again in exactly the same way -- with a
    # script that no longer contained the cause. Being explicit makes the tree's
    # group set a function of this file rather than of init history.
    in_container "repo init \
        -u '$MANIFEST_URL' \
        -b '$MANIFEST_REV' \
        --repo-rev='$REPO_REV' \
        --groups='default' \
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

    # Materialise LFS content explicitly. repo checks out with whatever filters
    # were configured at the time, so any project fetched before the lfs filter
    # existed keeps an empty working tree with no error of any kind. Re-running
    # sync does not fix it, because repo considers those projects already
    # up to date. `git lfs pull` is idempotent and cheap when there is nothing
    # to do, so this runs unconditionally rather than trying to detect the case.
    echo ">>> materialising git-lfs objects (chromium-webview prebuilts)"
    # git lfs pull's exit code is NOT a reliable success signal here. In a repo
    # checkout it prints "webview.apk: cannot add to the index - missing --add
    # option?" and exits non-zero while having correctly written the file --
    # repo's split .git layout confuses its index update, not its transfer.
    # Trusting that exit code aborted the run with the APKs already on disk.
    # The size assertion below is the real gate: verify the outcome, not the
    # tool's opinion of itself.
    in_container 'for d in external/chromium-webview/prebuilt/*/; do
            [ -e "$d/.git" ] || continue
            ( cd "$d" && git lfs pull >/dev/null 2>&1; true )
        done
        true'

    # Prove it worked rather than assuming. An LFS pointer is ~130 bytes and a
    # real WebView APK is tens of MB, so a size floor separates them cleanly.
    in_container 'for f in external/chromium-webview/prebuilt/*/webview.apk; do
            sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
            printf "    %-52s %s bytes\n" "$f" "$sz"
            [ "$sz" -gt 1000000 ] || { echo "build-lineage.sh: $f is missing or is an unresolved LFS pointer" >&2; exit 1; }
        done'

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
    # ALLOW_MISSING_DEPENDENCIES=true is required, not a shortcut.
    #
    # LineageOS ships the test suites (cts, test/cts-root, test/mts, test/vts,
    # test/catbox) but omits tools/tradefederation/core and test/suite_harness,
    # so cts-tradefed and cts-shim-host-lib are defined nowhere. Excluding cts
    # only moves the failure: cts also PROVIDES cts_defaults, which those other
    # suites depend on, and they sit on the aosp remote with no groups attribute
    # so they cannot be excluded by group at all.
    #
    # Every undefined module here is test infrastructure that a ROM build does
    # not ship. It does NOT silently excuse a missing vendor blob or HAL: those
    # fail on their own in packaging and in the vintf checks Phase 2 runs
    # against the built image. Verify the image, not the absence of this flag.
    in_container "export ALLOW_MISSING_DEPENDENCIES=true &&
        ccache -M ${CCACHE_GB}G >/dev/null &&
        source build/envsetup.sh &&
        lunch $LUNCH_TARGET &&
        m -j$BUILD_JOBS bacon"
    echo ">>> build complete; images under $WORK/out/target/product/fajita"
}

case "${1:-all}" in
    image)  phase_image ;;
    doctor) phase_doctor ;;
    sync)   guard_single_instance; phase_sync ;;
    build)  guard_single_instance; phase_build ;;
    all)    guard_single_instance; phase_image; phase_doctor; phase_sync; phase_build ;;
    *) echo "usage: build-lineage.sh [image|doctor|sync|build|all]" >&2; exit 1 ;;
esac
