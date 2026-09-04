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

# Skip edl phase if vendor fingerprint is OOS9 and GPT already has linuxroot.
skip_edl() {
    local probe=$1 manifest=$2
    # TODO: implement skip logic
    return 1  # Don't skip for now
}

# Skip boot phase if boot_<slot> sha256 matches the manifest.
skip_boot() {
    local probe=$1 manifest=$2
    local slot boot_sha manifest_sha
    
    # Read slot from probe
    slot=$(grep '^slot=' "$probe" | cut -d= -f2)
    [ "$slot" = "unknown" ] && return 1
    
    # Read boot_sha from probe
    boot_sha=$(grep '^boot_sha=' "$probe" | cut -d= -f2)
    [ "$boot_sha" = "unknown" ] && return 1
    
    # Read manifest sha for boot.img
    manifest_sha=$(python3 -c "
import json
try:
    doc = json.load(open('$manifest'))
    art = doc.get('artifacts', {}).get('droidian/out/images/boot.img', {})
    print(art.get('sha256', 'unknown'))
except:
    print('unknown')
")
    [ "$manifest_sha" = "unknown" ] && return 1
    
    # Compare
    [ "$boot_sha" = "$manifest_sha" ] && return 0
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
