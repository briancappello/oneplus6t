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

# Skip data phase if linuxroot holds our rootfs at the manifest's package versions.
skip_data() {
    local probe=$1 manifest=$2
    local pkg_names
    
    # Get package names from manifest
    pkg_names=$(python3 -c "
import json
try:
    doc = json.load(open('$manifest'))
    arts = doc.get('artifacts', {})
    for path, art in arts.items():
        if path.endswith('.deb'):
            name = art.get('target', '')
            if name in ('camera', 'adaptation'):
                print(name)
except:
    pass
")
    
    # No readable package evidence is not permission to skip. An empty list
    # would otherwise fall straight through the loop below and return "skip",
    # which is how a missing manifest could silently cancel a rootfs install.
    [ -n "$pkg_names" ] || return 1

    # Check each package version against probe
    for pkg in $pkg_names; do
        local manifest_ver probe_ver
        manifest_ver=$(python3 -c "
import json
try:
    doc = json.load(open('$manifest'))
    arts = doc.get('artifacts', {})
    for path, art in arts.items():
        if path.endswith('.deb') and art.get('target') == '$pkg':
            print(art.get('version', 'unknown'))
            break
except:
    print('unknown')
")
        
        probe_ver=$(grep "^pkg_${pkg}=" "$probe" | cut -d= -f2)
        [ "$probe_ver" = "unknown" ] && return 1
        [ "$manifest_ver" != "$probe_ver" ] && return 1
    done
    
    return 0
}

# Skip activate phase if current-slot is already the Droidian slot.
skip_activate() {
    local probe=$1 manifest=$2
    # TODO: implement skip logic
    return 1  # Don't skip for now
}

# Verify phase is never skipped.
skip_verify() {
    return 1
}
