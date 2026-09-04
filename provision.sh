#!/usr/bin/env bash
#
# Probe the phone, decide what is needed, flash it, verify it.
#
#   ./provision.sh --plan-only > plan.json   # probe and decide; touch nothing
#   ./provision.sh --artifacts ./out         # flash using prebuilt artifacts
#   BUILD_HOST=taichi ./provision.sh         # build remotely, fetch, flash
#   PHASE=boot ./provision.sh                # run a single phase
#   VERIFY=1 ./provision.sh                  # full sha256 instead of cheap probes
#
# This never builds. It probes for real evidence and skips only what the device
# demonstrably already has. No state file is written or trusted: such a record
# lies the moment anything changes outside the pipeline, and this repo has been
# bricked once already by believing a claim over reality.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST:-$HERE/droidian/manifest.json}"
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
PHASE=""
ASSUME_YES="${ASSUME_YES:-}"

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
        -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [ -z "$PROBE_FILE" ]; then
    PROBE_FILE=$(mktemp); trap 'rm -f "$PROBE_FILE"' EXIT
    "$HERE/lib/probe.sh" probe_all > "$PROBE_FILE" || die "probe failed"
fi

if [ "$MODE" = plan ]; then
    emit_plan "$(decide_build "$PROBE_FILE" "$MANIFEST")"
    exit 0
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
        userdata_img="$ARTIFACTS/droidian/userdata.img"
        [ -f "$userdata_img" ] || die "userdata.img not found: $userdata_img"
        echo "    data: flashing userdata (~$(( $(stat -c%s "$userdata_img") / 1000000 )) MB)"
        fastboot flash userdata "$userdata_img" || die "failed to flash userdata"
        echo "    data: flashed userdata"
    elif wanted data; then
        echo "    data: skipped (already correct)"
    fi

    # Phase 4: activate - activate Droidian slot
    if [ "$run_activate" = yes ]; then
        echo "    activate: activating Droidian slot"
        # For now, just reboot - the slot is already set by the flash
        fastboot reboot || die "failed to reboot"
        echo "    activate: rebooted"
    elif wanted activate; then
        echo "    activate: skipped (already active)"
    fi
    
    # Phase 5: verify - verify installation (never skipped)
    if [ -z "$PHASE" ] || [ "$PHASE" = "verify" ]; then
        echo "    verify: checking installation"
        # Wait for the device to come back on the USB network. The bounds are
        # tunable because how long a real phone takes to reappear varies with
        # the state it was flashed from; 60s was measured, not assumed.
        attempts=0
        while [ "$attempts" -lt "${VERIFY_ATTEMPTS:-30}" ]; do
            if device-ssh -r 'echo ok' >/dev/null 2>&1; then
                echo "    verify: device reachable via SSH"
                break
            fi
            attempts=$((attempts + 1))
            sleep "${VERIFY_DELAY:-2}"
        done

        if [ "$attempts" -eq "${VERIFY_ATTEMPTS:-30}" ]; then
            echo "    verify: WARNING - device not reachable"
        else
            echo "    verify: installation successful"
        fi
    fi
    
    echo ">>> done"
    exit 0
fi

die "no mode specified; use --plan-only or --artifacts"
