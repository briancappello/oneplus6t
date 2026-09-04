#!/usr/bin/env bash
# Read evidence off the device. WRITES NOTHING.
#
# Every fact is emitted as key=value, and a fact that could not be read is
# emitted as key=unknown -- never omitted, never guessed. Callers decide from
# probe_complete whether skipping is safe; an absent key would otherwise let a
# destructive phase skip itself on missing evidence.
#
# Fixture env vars exist so the parsers are testable with no phone attached.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="$PATH:$HERE/bin"

# section <name> — the lines between "--- <name>" and the next "--- " marker.
# Empty output means the remote command produced nothing, which is deliberately
# distinct from it producing an answer we did not like.
section() {
    awk -v m="--- $1" '$0==m {f=1; next} /^--- /{f=0} f' | sed '/^$/d'
}

device_state() {
    [ -n "${PROBE_STATE:-}" ] && { printf '%s\n' "$PROBE_STATE"; return; }
    "$HERE/device.sh" state 2>/dev/null || echo unknown
}

ssh_blob() {
    [ -n "${PROBE_SSH_FIXTURE:-}" ] && { cat "$PROBE_SSH_FIXTURE"; return; }
    device-ssh -r 'grep -E "^ro\.(build\.fingerprint|oxygen\.version)" /vendor/build.prop /system/build.prop 2>/dev/null; echo ---; dpkg -l halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita droidian-camera 2>/dev/null | grep "^ii"; echo "--- slot"; sed -n "s/.*androidboot\.slot_suffix=_\?\([ab]\).*/\1/p" /proc/cmdline; echo "--- partlabels"; ls /dev/disk/by-partlabel/ 2>/dev/null' 2>/dev/null
}

fb_blob() {
    [ -n "${PROBE_FB_FIXTURE:-}" ] && { cat "$PROBE_FB_FIXTURE"; return; }
    { fastboot getvar current-slot; fastboot getvar all; } 2>&1
}

emit() { printf '%s=%s\n' "$1" "${2:-unknown}"; }

probe_all() {
    local state; state=$(device_state)
    emit state "$state"

    local slot=unknown vfp=unknown oos=unknown lr=unknown
    local complete=no blob="" labels=""

    case "$state" in
        droidian)
            blob=$(ssh_blob)
            oos=$(sed -n 's/^.*ro\.oxygen\.version=//p'      <<<"$blob" | head -1)
            vfp=$(sed -n 's/^.*ro\.build\.fingerprint=//p'   <<<"$blob" | head -1)
            # The running slot is in the kernel command line. Without it
            # skip_boot cannot name a partition, so it never skips.
            slot=$(section slot <<<"$blob" | head -1)
            # Package versions: "ii  name  version  arch  desc"
            while read -r _ name ver _; do
                [ -n "${name:-}" ] || continue
                emit "pkg_$name" "$ver"
            done < <(grep '^ii' <<<"$blob")
            # has_linuxroot decides whether a destructive repartition is even
            # considered, so "the listing failed" must stay distinct from "the
            # partition is not there". Only the latter may trigger an erase.
            labels=$(section partlabels <<<"$blob")
            if [ -z "$labels" ]; then    lr=unknown
            elif grep -qx linuxroot <<<"$labels"; then lr=yes
            else                         lr=no
            fi
            [ -n "$vfp" ] && complete=yes
            ;;
        fastboot)
            blob=$(fb_blob)
            slot=$(sed -n 's/^current-slot: *//p' <<<"$blob" | tr -d '\r' | head -1)
            # Fingerprints and dpkg state are not readable here, and saying so
            # is the point: an incomplete probe must not permit a skip.
            complete=no
            ;;
        *)
            complete=no
            ;;
    esac

    emit slot           "${slot:-unknown}"
    emit vendor_fp      "${vfp:-unknown}"
    emit oos_version    "${oos:-unknown}"
    emit has_linuxroot  "${lr:-unknown}"
    # boot_sha is deliberately not a probe fact. A boot partition is fixed size
    # and the image flashed into it is smaller, so hashing the partition never
    # matches the image. The comparison needs the image's byte count from the
    # manifest, so lib/phases.sh queries it there instead of guessing here.
    emit probe_complete "$complete"
}

"${@:-probe_all}"
