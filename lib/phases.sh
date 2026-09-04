#!/usr/bin/env bash
# The five flash phases and their skip predicates.
#
# Each phase is a function that takes a probe file and a manifest file.
# Skip predicates return 0 when the phase can be skipped, 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    # TODO: implement skip logic
    return 1  # Don't skip for now
}

# Skip data phase if linuxroot holds our rootfs at the manifest's package versions.
skip_data() {
    local probe=$1 manifest=$2
    # TODO: implement skip logic
    return 1  # Don't skip for now
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
