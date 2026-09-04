#!/usr/bin/env bash
# build.sh — build the Droidian artifacts for the OnePlus 6T (fajita).
#
#   build.sh [--list] [target ...]
#
# A target is a line in the table below: name, dependencies, output path,
# and the command that produces it. The command runs in the source tree it
# belongs to, and may be replaced with FAKE_BUILD for tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SRC:-$ROOT/src}"
OUT="${OUT:-$ROOT/out}"
FAKE_BUILD="${FAKE_BUILD:-}"

# name|deps|output|command (command runs in the named source tree)
TARGETS=(
  "kernel|||kernel"
  "camera|||camera"
  "adaptation|||adaptation"
  "rootfs|camera adaptation|droidian/userdata.img|droidian"
)

list_targets() {
    local row name deps out cmd
    printf '%-12s %-22s %s\n' NAME DEPS OUTPUT
    for row in "${TARGETS[@]}"; do
        IFS='|' read -r name deps out cmd <<< "$row"
        printf '%-12s %-22s %s\n' "$name" "${deps:--}" "${out:--}"
    done
}

# run_target <name> — run one target's command in its source tree.
run_target() {
    local name="$1" row deps out cmd tree
    row="$(printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$name" '$1==n {print; exit}')"
    [ -n "$row" ] || { echo "build.sh: unknown target: $name" >&2; return 1; }
    IFS='|' read -r name deps out cmd <<< "$row"
    tree="${cmd:-$name}"

    if [ -n "$FAKE_BUILD" ]; then
        FT_NAME="$name" FT_OUTPUTS="$out" "$FAKE_BUILD"
        return
    fi

    if [ -z "$out" ]; then
        echo "build.sh: target '$name' has no output; nothing to do" >&2
        return 1
    fi

    local src="$SRC/$tree"
    [ -d "$src" ] || { echo "build.sh: source tree not found: $src" >&2; return 1; }
    mkdir -p "$OUT/$(dirname "$out")"
    echo "build.sh: building $name in $src -> $OUT/$out"
    ( cd "$src" && bash -c "$cmd" )
}

main() {
    if [ "${1:-}" = "--list" ]; then
        list_targets
        return 0
    fi
    [ $# -ge 1 ] || { list_targets; echo >&2; echo "usage: build.sh [--list] [target ...]" >&2; return 1; }
    local t
    for t in "$@"; do
        run_target "$t"
    done
}

main "$@"