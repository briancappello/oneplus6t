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

# target_deps <name> — print the target's dependencies, space-separated.
target_deps() {
    printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$1" '$1==n {print $2; exit}'
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
    else
        if [ -z "$out" ]; then
            echo "build.sh: target '$name' has no output; nothing to do" >&2
            return 1
        fi
        local src="$SRC/$tree"
        [ -d "$src" ] || { echo "build.sh: source tree not found: $src" >&2; return 1; }
        mkdir -p "$OUT/$(dirname "$out")"
        echo "build.sh: building $name in $src -> $OUT/$out"
        ( cd "$src" && bash -c "$cmd" )
    fi

    write_manifest "$name" "$tree" "$out"
}

# write_manifest <name> <tree> <output> — record the provenance of a finished
# build. The manifest is the unit of trust: provision.sh later refuses to
# flash an artifact whose manifest does not match the phone.
write_manifest() {
    local name="$1" tree="$2" out="$3" commit
    commit="$(git -C "$SRC/$tree" rev-parse HEAD 2>/dev/null || echo unknown)"
    mkdir -p "$OUT"
    cat > "$OUT/manifest.json" <<EOF
{
  "name": "$name",
  "source": "$tree",
  "commit": "$commit",
  "output": "$out",
  "time": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
}

# resolve_order <requested...> — print the build order, one topological level
# per line; the targets on a line are independent and may run in parallel.
resolve_order() {
    local -a remaining=() ready=() nr=()
    local -A done=() is_ready=()
    local t d r changed ok found

    for t in "$@"; do remaining+=("$t"); done

    # Grow to the transitive closure of the dependencies.
    changed=1
    while [ "$changed" -eq 1 ]; do
        changed=0
        for r in "${remaining[@]}"; do
            for d in $(target_deps "$r"); do
                found=0
                for t in "${remaining[@]}"; do [ "$t" = "$d" ] && found=1; done
                if [ "$found" -eq 0 ]; then
                    remaining+=("$d"); changed=1
                fi
            done
        done
    done

    # Emit each level whose dependencies are all satisfied.
    while [ "${#remaining[@]}" -gt 0 ]; do
        ready=()
        for t in "${remaining[@]}"; do
            ok=1
            for d in $(target_deps "$t"); do
                [ -n "${done[$d]:-}" ] || { ok=0; break; }
            done
            [ "$ok" -eq 1 ] && ready+=("$t")
        done
        if [ "${#ready[@]}" -eq 0 ]; then
            echo "build.sh: unresolvable dependencies among: ${remaining[*]}" >&2
            return 1
        fi
        printf '%s\n' "${ready[*]}"
        for t in "${ready[@]}"; do done[$t]=1; done
        is_ready=()
        for t in "${ready[@]}"; do is_ready[$t]=1; done
        nr=()
        for t in "${remaining[@]}"; do
            [ -n "${is_ready[$t]:-}" ] || nr+=("$t")
        done
        remaining=("${nr[@]}")
    done
}

# build_targets <requested...> — build each resolved level; the targets of a
# level run in parallel. Prints "built: <name>" for each target, in order.
build_targets() {
    local order level t rc
    local -A pids=()
    order="$(resolve_order "$@")" || return 1
    while IFS= read -r level; do
        [ -n "$level" ] || continue
        pids=()
        for t in $level; do
            run_target "$t" & pids[$t]=$!
        done
        rc=0
        for t in $level; do
            wait "${pids[$t]}" || { echo "build.sh: build failed: $t" >&2; rc=1; }
        done
        for t in $level; do
            [ "$rc" -eq 0 ] && echo "built: $t"
        done
        [ "$rc" -eq 0 ] || return 1
    done <<< "$order"
}

main() {
    if [ "${1:-}" = "--list" ]; then
        list_targets
        return 0
    fi
    [ $# -ge 1 ] || { list_targets; echo >&2; echo "usage: build.sh [--list] [target ...]" >&2; return 1; }
    build_targets "$@"
}

main "$@"