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
# Outputs land where the droidian scripts already write them and where
# provision.sh already looks for them: the repo root. These three agreeing is
# the whole contract, so OUT is not free to be somewhere tidier.
OUT="${OUT:-$ROOT}"
FAKE_BUILD="${FAKE_BUILD:-}"

# name|deps|outputs|tree|command
#
# Output paths are relative to OUT and are the keys provision.sh indexes the
# manifest by, so they must match what it looks for under --artifacts.
#
# tree is the source tree staleness is judged from, under SRC. command is what
# actually builds the target, run from the repo root. These are two different
# things: the table used to have only one column for both, so every real build
# ran `bash -c adaptation` in a directory that has never existed.
TARGETS=(
  "kernel||droidian/out/images/boot.img droidian/out/images/vbmeta.img|kernel|droidian/build-kernel.sh"
  "camera||droidian/out-camera|camera|droidian/build-camera.sh"
  "adaptation||droidian/out-adaptation|adaptation|droidian/adaptation/build-adaptation.sh"
  "rootfs|camera adaptation|droidian/linuxroot.img droidian/linuxroot.simg droidian/linuxroot.gsi|droidian|droidian/build-rootfs.sh"
)

list_targets() {
    local row name deps out tree cmd
    printf '%-12s %-22s %-38s %s\n' NAME DEPS OUTPUT COMMAND
    for row in "${TARGETS[@]}"; do
        IFS='|' read -r name deps out tree cmd <<< "$row"
        printf '%-12s %-22s %-38s %s\n' "$name" "${deps:--}" "${out:--}" "${cmd:--}"
    done
}

# target_cmd <name> — the command that builds the target, relative to ROOT.
target_cmd() {
    printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$1" '$1==n {print $5; exit}'
}

# Every declared command must exist and be executable. A table entry naming a
# script that is not there is a build that fails only on the worker, minutes in.
check_commands() {
    local row name deps out tree cmd bad=0
    for row in "${TARGETS[@]}"; do
        IFS='|' read -r name deps out tree cmd <<< "$row"
        if [ -z "$cmd" ]; then
            echo "build.sh: target '$name' declares no command" >&2; bad=1; continue
        fi
        if [ ! -x "$ROOT/$cmd" ]; then
            echo "build.sh: target '$name' command is not executable: $cmd" >&2; bad=1
        fi
    done
    [ "$bad" -eq 0 ] || return 1
    echo "build.sh: every target has an executable command"
}

# target_deps <name> — print the target's dependencies, space-separated.
target_deps() {
    printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$1" '$1==n {print $2; exit}'
}

# target_exists <name> — true when the name is in the table.
target_exists() {
    printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$1" '$1==n {f=1} END {exit !f}'
}

# read_plan <file> — print "<force> <target...>" for a Contract 2 plan file.
# A plan naming something unbuildable is a mistake worth stopping for: it means
# the phone host and the worker disagree about what exists.
read_plan() {
    PLAN="$1" python3 - <<'PY'
import json, os, sys
try:
    doc = json.load(open(os.environ["PLAN"]))
except Exception as exc:
    sys.stderr.write("build.sh: malformed plan: %s\n" % exc)
    sys.exit(1)
targets = doc.get("build", [])
if not isinstance(targets, list) or not all(isinstance(t, str) for t in targets):
    sys.stderr.write("build.sh: plan 'build' must be a list of names\n")
    sys.exit(1)
print("%d %s" % (1 if doc.get("force") else 0, " ".join(targets)))
PY
}

# target_outputs <name> — the declared output paths, relative to OUT.
target_outputs() {
    printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$1" '$1==n {print $3; exit}'
}

# target_tree <name> — the source tree the target's staleness is judged from.
target_tree() {
    local t; t=$(printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$1" '$1==n {print $4; exit}')
    printf '%s\n' "${t:-$1}"
}

# target_files <name> — the actual files produced, expanding declared
# directories. A .deb's name carries its version, so the files cannot simply
# be the declared paths.
#
# From a directory, only the packages count. dpkg-buildpackage drops a .changes,
# a .dsc, a .buildinfo, a .build and a build log beside every .deb, and recording
# those as artifacts made the manifest describe the build's paperwork as though
# it were something installable on a phone.
target_files() {
    local o
    for o in $(target_outputs "$1"); do
        if [ -d "$OUT/$o" ]; then
            find "$OUT/$o" -type f -name '*.deb' 2>/dev/null | sed "s|^$OUT/||"
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

# run_target <name> — run one target's build command from the repo root.
run_target() {
    local name="$1" row deps out tree cmd
    row="$(printf '%s\n' "${TARGETS[@]}" | awk -F'|' -v n="$name" '$1==n {print; exit}')"
    [ -n "$row" ] || { echo "build.sh: unknown target: $name" >&2; return 1; }
    IFS='|' read -r name deps out tree cmd <<< "$row"

    # A directory output is cleared first, so it holds what this build produced
    # and not also what every previous one did. Left to accumulate, it collects
    # one .deb per version ever built, and a manifest naming two versions of the
    # same package describes a device that cannot exist -- which is how skip_data
    # stops being able to skip. This belongs to the output, not to the builder,
    # so it happens whichever one is about to run.
    local o
    for o in $out; do
        if [ -d "${OUT:?}/$o" ]; then rm -rf "${OUT:?}/$o"; fi
        mkdir -p "$OUT/$(dirname "$o")"
    done

    if [ -n "$FAKE_BUILD" ]; then
        local abs=""
        for o in $out; do abs="$abs $OUT/$o"; done
        FT_NAME="$name" FT_OUTPUTS="$abs" "$FAKE_BUILD"
    else
        if [ -z "$out" ]; then
            echo "build.sh: target '$name' has no output; nothing to do" >&2
            return 1
        fi
        [ -x "$ROOT/$cmd" ] || { echo "build.sh: build command not found: $cmd" >&2; return 1; }
        echo "build.sh: building $name with $cmd"
        ( cd "$ROOT" && "./$cmd" )
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
            # name_VERSION_arch.deb -> VERSION; a .gsi sidecar IS its version
            # ("<package> <version>" of the container image); empty for images.
            ver=""
            case "$f" in
                *_*_*.deb) ver="$(basename "$f" | cut -d_ -f2)" ;;
                *.gsi)     ver="$(tr -d '\n' < "$OUT/$f")" ;;
            esac
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
rows_read = [l.rstrip("\n").split("\t") for l in open(rows) if l.strip()]

# Entries for targets built this run are replaced, not merged into. Merging by
# path meant a package whose filename carried a version could never be
# superseded: the old path was still a key, so the manifest kept claiming an
# artifact that this build did not produce and the output directory no longer
# held. Targets NOT built this run are still preserved -- that is the point of
# reading the existing file at all.
rebuilt = {r[1] for r in rows_read}
artifacts = {p: a for p, a in artifacts.items() if a.get("target") not in rebuilt}

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
    for t in "$@"; do
        target_exists "$t" || { echo "build.sh: unknown target: $t" >&2; return 1; }
    done
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

    if [ "${1:-}" = "--check-commands" ]; then
        check_commands
        return
    fi

    if [ "${1:-}" = "--plan" ]; then
        local pf="${2:-}" line targets
        [ -n "$pf" ] || { echo "build.sh: --plan needs a file" >&2; return 1; }
        [ -f "$pf" ] || { echo "build.sh: plan not found: $pf" >&2; return 1; }
        line="$(read_plan "$pf")" || return 1
        if [ "${line%% *}" = 1 ]; then FORCE=1; fi
        targets="${line#* }"
        [ -n "$targets" ] || { echo "build.sh: plan builds nothing" >&2; return 1; }
        # shellcheck disable=SC2086 -- $targets is a whitespace-separated list
        build_targets $targets
        return
    fi

    [ $# -ge 1 ] || { list_targets; echo >&2; echo "usage: build.sh [--list] [--plan FILE] [target ...]" >&2; return 1; }
    build_targets "$@"
}

main "$@"