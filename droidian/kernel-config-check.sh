#!/usr/bin/env bash
# kernel-config-check — every line in a Kconfig delta must hold in a .config.
#
#   ./droidian/kernel-config-check.sh droidian/packaging/arch/arm64/configs/halium.delta droidian/out/config-4.9-337-oneplus-fajita
#
# Why: merge_config.sh applies a fragment and then `make olddefconfig` is free
# to DROP any option whose dependencies are unmet, and it says so only as a
# warning that scrolls past in a multi-minute build log. A kernel built that
# way boots and then lxc fails to start hours later with no hint that PID_NS
# was silently discarded. This turns that warning into a failing check that
# runs against the .config the build actually used.
#
# Exit 0 if every =/is-not-set line holds, 1 otherwise, listing each miss.

set -euo pipefail

delta="${1:?usage: kernel-config-check.sh <delta> <.config>}"
cfg="${2:?usage: kernel-config-check.sh <delta> <.config>}"
[ -f "$delta" ] || { echo "no such delta: $delta" >&2; exit 2; }
[ -f "$cfg" ]   || { echo "no such .config: $cfg" >&2; exit 2; }

rc=0; n=0
while IFS= read -r raw; do
    # "# CONFIG_X is not set" is a directive; any other "#..." is a comment.
    case "$raw" in
        "# CONFIG_"*" is not set")
            line="$raw" ;;
        "#"*|"")
            continue ;;
        *)
            line="${raw%%#*}"                      # strip trailing comment
            line="${line%"${line##*[![:space:]]}"}" # rtrim
            ;;
    esac
    [ -n "$line" ] || continue
    n=$((n + 1))
    case "$line" in
        "# CONFIG_"*" is not set")
            k="${line#\# }"; k="${k% is not set}"
            if grep -qE "^${k}=[ym]" "$cfg"; then
                echo "FAIL  $k is set; delta wants it off"; rc=1
            fi ;;
        *=*)
            if ! grep -qxF "$line" "$cfg"; then
                have="$(grep -E "^${line%%=*}=" "$cfg" || echo "(absent)")"
                echo "FAIL  want '$line', have '$have'"; rc=1
            fi ;;
    esac
done < "$delta"

[ "$rc" -eq 0 ] && echo "ALL $n delta lines hold in $cfg"
exit "$rc"
