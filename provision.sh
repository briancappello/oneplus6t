#!/usr/bin/env bash
#
# Probe the phone, decide what is needed, flash it, verify it.
#
#   ./provision.sh                           # probe, flash what is needed, verify
#   BUILD_HOST=taichi ./provision.sh         # build on a worker first, then that
#   ./provision.sh --plan-only > plan.json   # probe and decide; touch nothing
#   ./provision.sh --artifacts ./out         # flash from somewhere else on disk
#   ./provision.sh --remote-build taichi     # build on a worker and stop there
#   PHASE=boot ./provision.sh                # run a single phase
#
# It builds nothing itself: with BUILD_HOST it asks a worker, and otherwise it
# flashes what build.sh already produced. It probes for real evidence and skips
# only what the device demonstrably already has. No state file is written or
# trusted: such a record lies the moment anything changes outside the pipeline,
# and this repo has been bricked once already by believing a claim over reality.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The manifest is a contract between the two scripts, so this must be the file
# build.sh actually writes -- it writes $OUT/manifest.json, and OUT is the repo
# root. These two have already drifted apart once.
MANIFEST="${MANIFEST:-$HERE/manifest.json}"
PROBE_FILE=""
MODE=full

die() { echo "provision.sh: $*" >&2; exit 1; }

# Phone-touching tools are resolved by name off PATH: fastboot, edl, device-ssh.
# This script therefore has no notion of being under test. The suite shadows
# those three names with fakes earlier on PATH, which makes reaching a real
# device from a test impossible rather than merely discouraged. Checking whether
# a device is actually attached and in the right state is ./device.sh state,
# not anything here.
PATH="$PATH:$HERE/bin:$HERE/edl/.venv/bin"

# Decide from evidence, never from a marker.
decide_build() {
    local probe=$1 manifest=$2
    PROBE="$probe" MANIFEST="$manifest" python3 - <<'PY'
import json, os, sys

def load_probe(path):
    facts = {}
    with open(path) as fh:
        for line in fh:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                facts[k] = v
    return facts

facts = load_probe(os.environ["PROBE"])
try:
    man = json.load(open(os.environ["MANIFEST"]))
except Exception:
    man = {"artifacts": {}}

ALL = ["kernel", "camera", "adaptation", "rootfs"]
have = {a.get("target") for a in man.get("artifacts", {}).values()}

# An unreadable device is not evidence that anything can be skipped, so an
# incomplete probe asks for everything rather than guessing.
if facts.get("probe_complete") != "yes":
    print(" ".join(ALL)); raise SystemExit

print(" ".join(t for t in ALL if t not in have))
PY
}

emit_plan() {
    local targets=$1
    TARGETS="$targets" python3 - <<'PY'
import json, os
targets = os.environ["TARGETS"].split()
print(json.dumps({"build": targets, "force": False}, indent=2, sort_keys=True))
PY
}

ARTIFACTS=""
PHASE="${PHASE:-}"
ASSUME_YES="${ASSUME_YES:-}"

# Where fetched artifacts land. Overridable for the same reason build.sh's OUT
# is: without it the only place this can write is the working tree, and a test
# that exercises fetching then writes over real build output. That is not
# hypothetical -- it overwrote a 4 GB rootfs with a 22-byte fixture.
FETCH_ROOT="${FETCH_ROOT:-$HERE}"

SSH_CMD="${PROV_SSH:-ssh}"
SCP_CMD="${PROV_SCP:-scp}"
REMOTE_DIR="${REMOTE_DIR:-oneplus6t}"

# Published commits go over origin; unpublished WIP goes by bundle.
#
# Both land the worker on an exact commit with an honest git state, which is the
# whole point: an rsynced pile of files builds something no one can name
# afterwards. Proven work is pushed, so the worker just fetches it and the trail
# is auditable. The bundle is for work deliberately kept unpushed -- asking
# origin for a commit it has never seen would simply fail.
is_published() {
    # Overridable so both transports are testable without a remote.
    case "${PROV_PUBLISHED:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    git -C "$HERE" rev-parse --verify --quiet origin/main >/dev/null 2>&1 || return 1
    git -C "$HERE" merge-base --is-ancestor HEAD origin/main 2>/dev/null
}

# remote_build <host> <plan-file> — build this commit on <host>, bring the
# results back. Touches no phone at either end.
remote_build() {
    local host=$1 plan=$2 f
    local sha; sha=$(git -C "$HERE" rev-parse HEAD)

    "$SCP_CMD" -q "$plan" "$host:/tmp/plan.json" || die "could not copy the plan to $host"

    if is_published; then
        "$SSH_CMD" "$host" "cd $REMOTE_DIR && git fetch -q origin && git reset -q --hard $sha" \
            || die "could not update $host to $sha from origin"
    else
        local bundle=/tmp/op6t-$$.bundle
        git -C "$HERE" bundle create "$bundle" HEAD >/dev/null 2>&1 \
            || die "could not create a git bundle"
        "$SCP_CMD" -q "$bundle" "$host:/tmp/op6t.bundle" || die "could not copy the bundle to $host"
        rm -f "$bundle"
        "$SSH_CMD" "$host" "cd $REMOTE_DIR && git fetch -q /tmp/op6t.bundle && git reset -q --hard FETCH_HEAD" \
            || die "could not update $host from the bundle"
    fi

    "$SSH_CMD" "$host" "cd $REMOTE_DIR && ./check-env.sh build" \
        || die "$host is missing build prerequisites"
    "$SSH_CMD" "$host" "cd $REMOTE_DIR && ./build.sh --plan /tmp/plan.json" \
        || die "the build failed on $host"

    # Bring back the manifest first: if it is absent the build produced nothing
    # trustworthy and flashing must not proceed.
    "$SCP_CMD" -q "$host:$REMOTE_DIR/manifest.json" "$MANIFEST" \
        || die "no manifest.json came back from $host"

    # The kernel is 32 MB, the rootfs around 9 GB. The small ones come over now;
    # the rootfs is left to start_rootfs_fetch, which runs only once something
    # has decided the rootfs is actually going to be flashed.
    for f in droidian/out/images/boot.img droidian/out/images/vbmeta.img; do
        mkdir -p "$(dirname "$FETCH_ROOT/$f")"
        "$SCP_CMD" -q "$host:$REMOTE_DIR/$f" "$FETCH_ROOT/$f" 2>/dev/null || true
    done
}

ROOTFS_IMG="droidian/linuxroot.simg"

# manifest_field <path> <field> — one recorded property of one artifact.
manifest_field() {
    MAN="$MANIFEST" P="$1" F="$2" python3 - <<'PY'
import json, os
try:
    doc = json.load(open(os.environ["MAN"]))
    print(doc.get("artifacts", {}).get(os.environ["P"], {}).get(os.environ["F"], "") or "")
except Exception:
    print("")
PY
}

# fetch_rootfs <host> — bring the rootfs over, compressed on the wire, and prove
# it arrived intact before any of it can reach the phone.
#
# The image is Android sparse rather than raw: a 9 GiB mostly-empty container
# sparses to 3.8 GiB and compresses to 1.3 GiB, so this moves a seventh of what
# copying the raw file did. It is also the form fastboot wants, which sparses a
# raw image itself before sending it.
#
# zstd on both ends rather than scp -C: it decompresses straight into the
# destination, so the compressed copy never lands on disk. Into a .part file,
# because an interrupted transfer must not be mistakable for a finished one --
# flashing a truncated rootfs gives a phone that will not boot and no hint why.
fetch_rootfs() {
    local host=$1 dest="$FETCH_ROOT/$ROOTFS_IMG" want got
    mkdir -p "$(dirname "$dest")"

    # A rejected transfer must not leave its remains lying next to the real
    # artifacts. Nothing downstream reads a .part, but a stale multi-gigabyte one
    # sits in the repo until someone notices, and the next run would append this
    # run's failure to it.
    rm -f "$dest.part"
    fail_fetch() { rm -f "$dest.part"; die "$*"; }

    local bytes; bytes=$(manifest_field "$ROOTFS_IMG" bytes)
    echo "    data: fetching the rootfs from $host; the count below is compressed"
    echo "    data: it decompresses to ${bytes:-an unknown number of} bytes here"

    # dd reports throughput and total once a second. Without it this is several
    # silent minutes, which from the outside is indistinguishable from a hang --
    # and a step that cannot be told apart from a hang is one people interrupt.
    # dd sits on the COMPRESSED side, so the bytes it counts are the bytes
    # actually crossing the network. Downstream of zstd -dc it would report the
    # decompressed size and quietly contradict the word "compressed".
    "$SSH_CMD" "$host" "zstd -c -T0 -3 $REMOTE_DIR/$ROOTFS_IMG" \
        | dd bs=1M status=progress \
        | zstd -dc > "$dest.part" \
        || fail_fetch "the rootfs transfer from $host failed; nothing was flashed"

    # An exit status is a weak claim about a multi-gigabyte copy. The manifest
    # recorded what the worker built, so compare against that instead.
    want=$(manifest_field "$ROOTFS_IMG" sha256)
    [ -n "$want" ] || fail_fetch "the manifest does not record a sha256 for $ROOTFS_IMG"
    echo "    data: hashing $(( $(stat -c%s "$dest.part") / 1048576 )) MiB to check it against the manifest"
    got=$(sha256sum "$dest.part" | cut -d' ' -f1)
    [ "$got" = "$want" ] \
        || fail_fetch "the rootfs arrived corrupt: sha256 $got, expected $want"
    mv "$dest.part" "$dest" || fail_fetch "could not finish the rootfs transfer"
}

# confirm_destructive <line...> — name every irreversible step, then require an
# explicit yes.
#
# Asked once, before anything is written, so the whole blast radius is visible
# rather than revealed one prompt at a time. It fails closed: with no terminal
# and no --yes it refuses rather than assuming consent, because the alternative
# is a script erasing a phone because nobody was there to say no. The reply must
# be the word YES, so a stray Enter cannot approve an erase.
confirm_destructive() {
    local line reply=""
    echo
    echo "  These steps write to the phone and cannot be undone:"
    for line in "$@"; do echo "    - $line"; done
    echo
    if [ -n "$ASSUME_YES" ]; then
        echo "  proceeding without asking (--yes given)"
        return 0
    fi
    [ -t 0 ] || die "refusing to write to the phone without confirmation; pass --yes to proceed non-interactively"
    printf '  Type YES to continue: '
    read -r reply || true
    [ "$reply" = YES ] || die "aborted: not confirmed"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)     ASSUME_YES=1; shift ;;
        --plan-only)  MODE=plan; shift ;;
        --artifacts)  shift; ARTIFACTS="${1:?--artifacts needs a path}"; MODE=artifacts; shift ;;
        --probe-file) shift; PROBE_FILE="${1:?--probe-file needs a path}"; shift ;;
        --manifest)   shift; MANIFEST="${1:?--manifest needs a path}"; shift ;;
        --phase)      shift; PHASE="${1:?--phase needs a name}"; shift ;;
        --remote-build) shift; REMOTE_HOST="${1:?--remote-build needs a host}"; MODE=remote; shift ;;
        --plan-file)  shift; PLAN_FILE="${1:?--plan-file needs a path}"; shift ;;
        # The header, however long it happens to be. A hardcoded line range goes
        # stale the first time someone documents a flag.
        -h|--help)    awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

# Probing reads the phone. A remote build handed an explicit plan has nothing
# left to ask it, so requiring an attached device there would make the one mode
# that never touches hardware the one that insists on it.
OWN_PROBE=""
if [ -z "$PROBE_FILE" ] && ! { [ "$MODE" = remote ] && [ -n "${PLAN_FILE:-}" ]; }; then
    PROBE_FILE=$(mktemp); OWN_PROBE=1; trap 'rm -f "$PROBE_FILE"' EXIT
    "$HERE/lib/probe.sh" probe_all > "$PROBE_FILE" || die "probe failed"
fi

if [ "$MODE" = remote ]; then
    if [ -z "${PLAN_FILE:-}" ]; then
        PLAN_FILE=$(mktemp)
        emit_plan "$(decide_build "$PROBE_FILE" "$MANIFEST")" > "$PLAN_FILE"
    fi
    remote_build "$REMOTE_HOST" "$PLAN_FILE"
    fetch_rootfs "$REMOTE_HOST"
    echo "provision.sh: artifacts and manifest fetched from $REMOTE_HOST"
    exit 0
fi

if [ "$MODE" = plan ]; then
    emit_plan "$(decide_build "$PROBE_FILE" "$MANIFEST")"
    exit 0
fi

# Full mode: the default, with no flag saying what to do. Build on the worker if
# one was named, then flash from whatever is on disk. Everything after this point
# is the artifacts path, because that is what full mode is once the artifacts
# exist -- there is no second flashing implementation to keep in step.
if [ "$MODE" = full ]; then
    if [ -n "${BUILD_HOST:-}" ]; then
        PLAN_FILE="${PLAN_FILE:-$(mktemp)}"
        emit_plan "$(decide_build "$PROBE_FILE" "$MANIFEST")" > "$PLAN_FILE"
        remote_build "$BUILD_HOST" "$PLAN_FILE"
        # The phone may have moved while the worker was building, so decide from
        # fresh evidence -- unless the caller pinned the evidence with
        # --probe-file, in which case re-probing would overrule what they asked.
        if [ -n "$OWN_PROBE" ]; then
            "$HERE/lib/probe.sh" probe_all > "$PROBE_FILE" || die "re-probe failed"
        fi
    fi
    # Every phase decides by comparing the device against the manifest. Without
    # one there is nothing to compare, and flashing whatever happens to be lying
    # on disk is exactly the unrecorded install this pipeline exists to prevent.
    [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST -- run build.sh, or set BUILD_HOST"
    # build.sh writes here and remote_build fetches here, so this is where the
    # artifacts are.
    ARTIFACTS="$HERE"
    MODE=artifacts
fi

if [ "$MODE" = artifacts ]; then
    . "$HERE/lib/phases.sh"
    echo ">>> flashing from artifacts in $ARTIFACTS"

    slot=$(grep '^slot=' "$PROBE_FILE" | cut -d= -f2)
    [ -n "$slot" ] && [ "$slot" != "unknown" ] || slot=a

    # Decide every phase before performing any of them. Deciding first is what
    # lets the warning below state the whole blast radius up front, instead of
    # a human discovering the third destructive step after approving two.
    wanted() { [ -z "$PHASE" ] || [ "$PHASE" = "$1" ]; }
    run_edl=no; run_boot=no; run_data=no; run_activate=no
    if wanted edl      && ! skip_edl      "$PROBE_FILE" "$MANIFEST"; then run_edl=yes; fi
    if wanted boot     && ! skip_boot     "$PROBE_FILE" "$MANIFEST"; then run_boot=yes; fi
    if wanted data     && ! skip_data     "$PROBE_FILE" "$MANIFEST"; then run_data=yes; fi
    if wanted activate && ! skip_activate "$PROBE_FILE" "$MANIFEST"; then run_activate=yes; fi
    # Anything that puts the phone in the bootloader has to take it back out
    # again, whatever the probe said before the flash began. Deciding this from
    # the probe alone would leave a freshly flashed phone sitting in fastboot,
    # because the probe was read while it was still running Droidian.
    if wanted activate && { [ "$run_boot" = yes ] || [ "$run_data" = yes ]; }; then
        run_activate=yes
    fi

    warn=()
    [ "$run_edl" = yes ] && warn+=(
        "edl   rewrites the partition table. This ERASES EVERY PARTITION, including Android and everything in internal storage. It is recoverable only by reflashing stock firmware, and an interruption can leave the phone unbootable.")
    [ "$run_data" = yes ] && warn+=(
        "data  overwrites the rootfs partition. Every file in the Droidian install, including anything you saved there, is replaced.")
    [ "$run_boot" = yes ] && warn+=(
        "boot  overwrites boot_$slot and vbmeta_$slot. The kernel currently on that slot is replaced.")
    if [ "${#warn[@]}" -gt 0 ]; then
        confirm_destructive "${warn[@]}"
    fi

    # Phase 1: edl (destructive) - rewrite the GPT
    if [ "$run_edl" = yes ]; then
        echo "    edl: running (GPT lacks linuxroot)"
        # Delegate to restore-android.py, which owns the verified GPT path:
        # it measures the real LUN size, completes the MSM template (which
        # ships unfinished, with last_usable_lba=0 and a zero-length
        # userdata), recomputes both CRC32s, writes the primary at sector 0
        # and the backup at total-5, and byte-compares each write by reading
        # it back.
        #
        # A partition table is not a partition. It lives at fixed sectors of
        # the LUN, so it cannot be written through a name-addressed API: the
        # previous code here ran `edl w sbl1 gpt_main0.bin`, which would have
        # written the table into the secondary bootloader, from a template
        # that contains no linuxroot and so could not have created one anyway.
        echo "    edl: writing the dual-boot partition table"
        repartition-dualboot || die "repartitioning failed"
        echo "    edl: GPT rewrite complete"
    elif wanted edl; then
        echo "    edl: skipped (not positively known to need repartitioning)"
    fi

    # The boot and data phases speak fastboot, and the phone answers fastboot
    # only from the bootloader. Getting there is a reboot, so it happens once,
    # after consent and before the first write, rather than inside each phase --
    # and it happens at all, which it did not: these phases used to fire
    # fastboot at whatever state the phone happened to be in, so running this
    # from a booted Droidian simply hung.
    if [ "$run_boot" = yes ] || [ "$run_data" = yes ]; then
        echo "    fastboot: putting the phone in the bootloader"
        device-goto fastboot || die "the phone would not enter the bootloader; nothing was flashed"
    fi

    # Phase 2: boot - flash boot.img
    if [ "$run_boot" = yes ]; then
        echo "    boot: flashing"
        boot_img="$ARTIFACTS/droidian/out/images/boot.img"
        vbmeta_img="$ARTIFACTS/droidian/out/images/vbmeta.img"
        [ -f "$boot_img" ] || die "boot.img not found: $boot_img"
        [ -f "$vbmeta_img" ] || die "vbmeta.img not found: $vbmeta_img"
        fastboot flash "boot_$slot" "$boot_img" || die "failed to flash boot"
        fastboot flash "vbmeta_$slot" "$vbmeta_img" || die "failed to flash vbmeta"
        echo "    boot: flashed boot_$slot and vbmeta_$slot"
    elif wanted boot; then
        echo "    boot: skipped (already correct)"
    fi

    # Phase 3: data - install rootfs (destructive)
    if [ "$run_data" = yes ]; then
        echo "    data: installing rootfs"
        rootfs_img="$ARTIFACTS/$ROOTFS_IMG"
        # Only fetched once it is known to be needed, so a run that skips this
        # phase does not move gigabytes to decide it had nothing to do.
        [ -f "$rootfs_img" ] || [ -z "${BUILD_HOST:-}" ] || fetch_rootfs "$BUILD_HOST"
        [ -f "$rootfs_img" ] || die "rootfs image not found: $rootfs_img"
        # linuxroot, never userdata: userdata is Android's /data, and the
        # kernel cmdline (datapart=) points the halium initramfs here.
        echo "    data: flashing linuxroot (~$(( $(stat -c%s "$rootfs_img") / 1000000 )) MB sparse)"
        fastboot flash linuxroot "$rootfs_img" || die "failed to flash linuxroot"
        echo "    data: flashed linuxroot"
    elif wanted data; then
        echo "    data: skipped (already correct)"
    fi

    # Phase 4: activate - leave the bootloader for the system that was flashed
    if [ "$run_activate" = yes ]; then
        echo "    activate: rebooting out of the bootloader"
        # Bounded, because this hung for six minutes on a real run: after a large
        # flash the bootloader reboots without answering, and fastboot sits on a
        # USB read that never returns. The command has already been delivered by
        # then, so a timeout here is not a failure to reboot -- it is fastboot
        # failing to notice that it worked. What settles it is the state the phone
        # is actually in, which is what gets checked next.
        timeout "${ACTIVATE_TIMEOUT:-60}" fastboot reboot >/dev/null 2>&1 \
            || echo "    activate: fastboot did not confirm the reboot; checking the phone instead"

        # The phone leaving the bootloader is the outcome that matters, and it is
        # observable. Waiting on it means an unanswered reboot costs a moment
        # rather than the whole run.
        if device-goto droidian; then
            echo "    activate: the phone left the bootloader"
        else
            die "the phone did not leave the bootloader after flashing"
        fi
    elif wanted activate; then
        echo "    activate: skipped (already active)"
    fi
    
    # Phase 5: verify - verify installation (never skipped)
    if [ -z "$PHASE" ] || [ "$PHASE" = "verify" ]; then
        echo "    verify: waiting for the device"
        # Wait for the device to come back on the USB network. The bounds are
        # tunable because how long a real phone takes to reappear varies with
        # the state it was flashed from; 60s was measured, not assumed.
        attempts=0
        while [ "$attempts" -lt "${VERIFY_ATTEMPTS:-30}" ]; do
            device-ssh -r 'echo ok' >/dev/null 2>&1 && break
            attempts=$((attempts + 1))
            # Say something periodically. A phone coming back from a flash takes
            # up to a minute, and silence for a minute reads as a hang.
            if [ $((attempts % 10)) -eq 0 ]; then
                echo "    verify: ${attempts} tries, still waiting for the device"
            fi
            sleep "${VERIFY_DELAY:-2}"
        done
        [ "$attempts" -lt "${VERIFY_ATTEMPTS:-30}" ] \
            || die "verify: the device never came back, so nothing was verified"

        # Answering a ping is not an install. verify-device.sh asserts the
        # user-visible outcomes, and the negative ones too, so its verdict is
        # this phase's verdict: saying "successful" on the strength of an echo
        # is the kind of claim this pipeline exists to stop making.
        echo "    verify: device reachable, checking the install"
        "$HERE/droidian/verify-device.sh" 2>&1 | sed 's/^/    /' \
            || die "verify: the device is reachable but the install is not correct"
    fi
    
    echo ">>> done"
    exit 0
fi

# Every mode above either exits or resolves to the artifacts path, so there is
# nothing left to fall through to.
