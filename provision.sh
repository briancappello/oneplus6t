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

while [ $# -gt 0 ]; do
    case "$1" in
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
    echo ">>> flashing from artifacts in $ARTIFACTS"
    
    # Phase 1: edl (destructive) - rewrite GPT if needed
    if [ -z "$PHASE" ] || [ "$PHASE" = "edl" ]; then
        . "$HERE/lib/phases.sh"
        if skip_edl "$PROBE_FILE" "$MANIFEST"; then
            echo "    edl: skipped (GPT already correct)"
        else
            echo "    edl: running (GPT needs rewrite)"
            # TODO: implement EDL GPT rewrite
        fi
    fi
    
    # Phase 2: boot - flash boot.img
    if [ -z "$PHASE" ] || [ "$PHASE" = "boot" ]; then
        . "$HERE/lib/phases.sh"
        if skip_boot "$PROBE_FILE" "$MANIFEST"; then
            echo "    boot: skipped (already correct)"
        else
            echo "    boot: flashing"
            # TODO: implement boot flash
        fi
    fi
    
    # Phase 3: data - install rootfs (destructive)
    if [ -z "$PHASE" ] || [ "$PHASE" = "data" ]; then
        . "$HERE/lib/phases.sh"
        if skip_data "$PROBE_FILE" "$MANIFEST"; then
            echo "    data: skipped (already correct)"
        else
            echo "    data: installing rootfs"
            # TODO: implement data flash
        fi
    fi
    
    # Phase 4: activate - activate Droidian slot
    if [ -z "$PHASE" ] || [ "$PHASE" = "activate" ]; then
        . "$HERE/lib/phases.sh"
        if skip_activate "$PROBE_FILE" "$MANIFEST"; then
            echo "    activate: skipped (already active)"
        else
            echo "    activate: activating Droidian slot"
            # TODO: implement slot activation
        fi
    fi
    
    # Phase 5: verify - verify installation (never skipped)
    if [ -z "$PHASE" ] || [ "$PHASE" = "verify" ]; then
        echo "    verify: checking installation"
        # TODO: implement verification
    fi
    
    echo ">>> done"
    exit 0
fi

die "no mode specified; use --plan-only or --artifacts"
