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

# name|deps|outputs|command (command runs in the named source tree)
# Output paths are relative to OUT and are the keys provision.sh indexes the
# manifest by, so they must match what it looks for under --artifacts.
TARGETS=(
  "kernel||droidian/out/images/boot.img droidian/out/images/vbmeta.img|kernel"
  "camera||droidian/out-camera|camera"
  "adaptation||droidian/out-adaptation|adaptation"
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

# target_outputs <name> — the declared output paths, relative to OUT.
target_outputs() {
    printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$1" '$1==n {print $3; exit}'
}

# target_tree <name> — the source tree the target's command runs in.
target_tree() {
    local t; t=$(printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$1" '$1==n {print $4; exit}')
    printf '%s\n' "${t:-$1}"
}

# target_files <name> — the actual files produced, expanding declared
# directories. A .deb's name carries its version, so the files cannot simply
# be the declared paths.
target_files() {
    local o
    for o in $(target_outputs "$1"); do
        if [ -d "$OUT/$o" ]; then
            find "$OUT/$o" -type f 2>/dev/null | sed "s|^$OUT/||"
        elif [ -e "$OUT/$o" ]; then
            printf '%s\n' "$o"
        fi
    done
}

# source_commit <tree> — the commit the target would be built from.
#
# A dirty tree gets a -dirty suffix and is never treated as up to date: an
# uncommitted tree is not reproducible, so nothing can be concluded about an
# artifact built from it.
source_commit() {
    local dir="$SRC/$1" c
    [ -d "$dir" ] || dir="$ROOT"
    c=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || { printf 'unknown\n'; return; }
    [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] && c="$c-dirty"
    printf '%s\n' "$c"
}

# is_stale <name> — print a human reason and return 0 when the target must be
# built. Existence alone is deliberately not sufficient: an artifact built from
# a commit the tree has since moved past is how a reverted patch survives on a
# device with nothing recording it.
is_stale() {
    local name="$1" cur o recorded
    [ "${FORCE:-0}" = 1 ] && { echo "FORCE=1"; return 0; }

    cur=$(source_commit "$(target_tree "$name")")
    case "$cur" in
        *-dirty) echo "source tree is dirty"; return 0 ;;
        unknown) echo "source commit unknown"; return 0 ;;
    esac

    for o in $(target_outputs "$name"); do
        [ -e "$OUT/$o" ] || { echo "output missing: $o"; return 0; }
    done

    [ -f "$OUT/manifest.json" ] || { echo "no manifest"; return 0; }

    recorded=$(MAN="$OUT/manifest.json" NAME="$name" CUR="$cur" python3 - <<'PY'
import json, os, sys
try:
    doc = json.load(open(os.environ["MAN"]))
except Exception:
    print("unreadable manifest"); sys.exit(0)
mine = {p: a for p, a in doc.get("artifacts", {}).items()
        if a.get("target") == os.environ["NAME"]}
if not mine:
    print("not in manifest"); sys.exit(0)
for path, a in mine.items():
    if a.get("source_commit") != os.environ["CUR"]:
        print("source moved: %s -> %s" % (a.get("source_commit"), os.environ["CUR"]))
        sys.exit(0)
print("")
PY
)
    [ -n "$recorded" ] && { echo "$recorded"; return 0; }
    return 1
}

# run_target <name> — run one target's command in its source tree.
run_target() {
    local name="$1" row deps out cmd tree
    row="$(printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$name" '$1==n {print; exit}')"
    [ -n "$row" ] || { echo "build.sh: unknown target: $name" >&2; return 1; }
    IFS='|' read -r name deps out cmd <<< "$row"
    tree="${cmd:-$name}"

    if [ -n "$FAKE_BUILD" ]; then
        local o abs=""
        for o in $out; do mkdir -p "$OUT/$(dirname "$o")"; abs="$abs $OUT/$o"; done
        FT_NAME="$name" FT_OUTPUTS="$abs" "$FAKE_BUILD"
    else
        if [ -z "$out" ]; then
            echo "build.sh: target '$name' has no output; nothing to do" >&2
            return 1
        fi
        local src="$SRC/$tree"
        [ -d "$src" ] || { echo "build.sh: source tree not found: $src" >&2; return 1; }
        local o
        for o in $out; do mkdir -p "$OUT/$(dirname "$o")"; done
        echo "build.sh: building $name in $src"
        ( cd "$src" && bash -c "$cmd" )
    fi
}

# write_manifest <target...> — record the provenance of the finished build.
#
# The manifest is the unit of trust: provision.sh refuses to flash an artifact
# whose manifest does not match the phone, and is_stale decides from it. It is
# written once, by the parent, after every target has finished -- targets build
# in parallel, and having each write this file would race them against a single
# path. Entries for targets not built this run are preserved.
write_manifest() {
    local t f rows repo ver
    repo="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    rows="$(mktemp)"

    for t in "$@"; do
        local sc; sc="$(source_commit "$(target_tree "$t")")"
        while read -r f; do
            [ -n "$f" ] || continue
            # name_VERSION_arch.deb -> VERSION; empty for images.
            ver=""
            case "$f" in *_*_*.deb) ver="$(basename "$f" | cut -d_ -f2)" ;; esac
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$f" "$t" "$(sha256sum "$OUT/$f" | cut -d' ' -f1)" \
                "$(stat -c%s "$OUT/$f")" "$sc" "$ver"
        done < <(target_files "$t")
    done > "$rows"

    mkdir -p "$OUT"
    REPO_COMMIT="$repo" python3 - "$rows" "$OUT/manifest.json" <<'PY'
import json, os, sys, time
rows, out = sys.argv[1], sys.argv[2]
try:
    doc = json.load(open(out))
except Exception:
    doc = {}
artifacts = doc.get("artifacts", {})
with open(rows) as fh:
    for line in fh:
        path, target, sha, size, src, ver = line.rstrip("\n").split("\t")
        artifacts[path] = {
            "target": target, "version": ver, "sha256": sha, "bytes": int(size),
            "repo_commit": os.environ["REPO_COMMIT"], "source_commit": src,
        }
doc = {"generated": int(time.time()),
       "repo_commit": os.environ["REPO_COMMIT"],
       "artifacts": artifacts}
with open(out, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
    rm -f "$rows"
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
    local order level t rc reason
    local -A pids=()
    local -a todo=()
    order="$(resolve_order "$@")" || return 1
    while IFS= read -r level; do
        [ -n "$level" ] || continue
        todo=()
        for t in $level; do
            if reason="$(is_stale "$t")"; then
                echo "build.sh: building $t ($reason)"
                todo+=("$t")
            else
                echo "up to date: $t"
            fi
        done
        [ "${#todo[@]}" -gt 0 ] || continue
        pids=()
        for t in "${todo[@]}"; do
            run_target "$t" & pids[$t]=$!
        done
        rc=0
        for t in "${todo[@]}"; do
            wait "${pids[$t]}" || { echo "build.sh: build failed: $t" >&2; rc=1; }
        done
        for t in "${todo[@]}"; do
            [ "$rc" -eq 0 ] && echo "built: $t"
        done
        [ "$rc" -eq 0 ] || return 1
    done <<< "$order"
    # shellcheck disable=SC2086 -- $order is a whitespace-separated target list
    write_manifest $order
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