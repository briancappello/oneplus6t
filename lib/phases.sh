#!/usr/bin/env bash
# The five flash phases and their skip predicates.
#
# Each phase is a function that takes a probe file and a manifest file.
# Skip predicates return 0 when the phase can be skipped, 1 otherwise.
set -uo pipefail

# NOTE: this file is sourced into its callers, so it must not define common
# variable names. It previously set HERE, which silently overwrote the caller's
# own HERE; the test harness then resolved its fixture paths against the repo
# root and a phase retried against a device that was never going to answer.
# Anything added here needs a scoped name or a `local`.

load_probe() {
    local probe=$1
    declare -A facts
    while read -r line; do
        if [[ "$line" == *"="* ]]; then
            local key="${line%%=*}"
            local val="${line#*=}"
            facts[$key]="$val"
        fi
    done < "$probe"
    echo "${facts[@]}"
}

# Skip the edl phase unless the GPT is positively known to lack linuxroot.
#
# The polarity here is the opposite of every other predicate, on purpose. edl
# rewrites the partition table and erases the whole device. Running it when it
# was not needed destroys everything; skipping it when it was needed costs a
# rerun. So absent or unreadable evidence means skip, and only a device that
# listed its partitions and did not have linuxroot may trigger the rewrite.
skip_edl() {
    local probe=$1 manifest=$2 lr
    lr=$(grep '^has_linuxroot=' "$probe" | cut -d= -f2)
    [ "$lr" = no ] || return 0
    return 1
}

# device_boot_sha <slot> <bytes> — sha256 of the first <bytes> of the boot
# partition. A boot partition is fixed size and the image in it is smaller, so
# hashing the whole partition would never match the image; the byte count comes
# from the manifest. Any failure prints nothing and returns non-zero, which the
# caller must read as "unknown", never as "differs".
device_boot_sha() {
    local slot=$1 bytes=$2 out
    case "$bytes" in ''|*[!0-9]*) return 1 ;; esac
    out=$(device-ssh -r "head -c $bytes /dev/disk/by-partlabel/boot_$slot | sha256sum" 2>/dev/null) || return 1
    out=${out%% *}
    case "$out" in
        [0-9a-f][0-9a-f]*) printf '%s\n' "$out" ;;
        *) return 1 ;;
    esac
}

# Skip the boot phase when the flashed boot image is already on the device.
# Unknown evidence means reflash: that costs a minute, while wrongly skipping
# leaves a kernel on the phone that nothing accounts for.
skip_boot() {
    local probe=$1 manifest=$2
    local slot want bytes have

    slot=$(grep '^slot=' "$probe" | cut -d= -f2)
    [ -z "$slot" ] || [ "$slot" = "unknown" ] && return 1

    # Expected hash and size of the image we would flash.
    read -r want bytes <<<"$(MAN="$manifest" python3 - <<'PY'
import json, os
try:
    doc = json.load(open(os.environ["MAN"]))
    a = doc.get("artifacts", {}).get("droidian/out/images/boot.img", {})
    print("%s %s" % (a.get("sha256", ""), a.get("bytes", "")))
except Exception:
    print(" ")
PY
)"
    [ -n "$want" ] && [ -n "$bytes" ] || return 1

    have=$(device_boot_sha "$slot" "$bytes") || return 1
    [ "$have" = "$want" ] && return 0
    return 1
}

# Skip the data phase when the device already has every package the rootfs would
# have installed, at the manifest's versions.
#
# Both sides of this comparison must speak Debian package names. The probe
# reports what dpkg calls them and the .deb filenames carry the same name; this
# used to compare against build *target* names instead -- "camera",
# "adaptation" -- which the device has never heard of, since it knows them as
# droidian-camera and adaptation-oneplus-fajita. No version could ever agree, so
# the phase could not skip at all. It failed in the safe direction, but on this
# phone "reflash a rootfs that was already correct" means erasing it, which is
# not a cost worth paying on every run.
#
# One target produces several packages -- adaptation alone ships three -- so the
# unit compared is the .deb, not the target.
skip_data() {
    local probe=$1 manifest=$2 want name ver probe_ver

    # The install has to be on linuxroot before package versions mean
    # anything. "unknown" is not evidence either way, and the safe direction
    # here is to run: a needless rootfs flash costs minutes, a skipped move
    # leaves Droidian sitting in the partition Android is about to format.
    [ "$(grep '^data_part=' "$probe" | cut -d= -f2)" = linuxroot ] || return 1

    want=$(MAN="$manifest" python3 - <<'PY'
import json, os, sys
try:
    doc = json.load(open(os.environ["MAN"]))
except Exception:
    sys.exit(0)
for path, art in doc.get("artifacts", {}).items():
    base = os.path.basename(path)
    version = art.get("version") or ""
    if base.endswith(".gsi"):
        # "<package> <version>": the container image, compared like a .deb.
        if len(version.split()) == 2:
            print(version)
        continue
    if not base.endswith(".deb"):
        continue
    # name_VERSION_arch.deb
    name = base.split("_")[0]
    if name and version:
        print("%s %s" % (name, version))
PY
)
    # No readable package evidence is not permission to skip. An empty list
    # would otherwise fall straight through the loop below and return "skip",
    # which is how a missing manifest could silently cancel a rootfs install.
    [ -n "$want" ] || return 1

    while read -r name ver; do
        [ -n "$name" ] || continue
        probe_ver=$(grep "^pkg_${name}=" "$probe" | cut -d= -f2)
        # Absent, unreadable, or different: none of these are evidence the
        # device already has it.
        [ -n "$probe_ver" ] || return 1
        [ "$probe_ver" = unknown ] && return 1
        [ "$probe_ver" = "$ver" ] || return 1
    done <<< "$want"

    return 0
}

# Skip the activate phase when the phone is already running what it would have
# been rebooted into.
#
# Activation is `fastboot reboot`, and every flash phase speaks fastboot, so a
# device that answered the probe over ssh as Droidian had nothing written under
# it this run and is already on the system we wanted. Any other state --
# fastboot, edl, off, or unreadable -- is not evidence of that. This is the one
# phase where being wrong is cheap in both directions: a needless reboot costs a
# minute, a missed one leaves the phone sitting in the bootloader.
skip_activate() {
    local probe=$1 manifest=$2 state
    state=$(grep '^state=' "$probe" | cut -d= -f2)
    [ "$state" = droidian ] || return 1
    return 0
}

# Verify phase is never skipped.
skip_verify() {
    return 1
}
