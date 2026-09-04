# Provisioning Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take a OnePlus 6T in any USB-reachable state to dual-boot OxygenOS 9 +
Droidian, skipping whatever is already correct, with building on the worker and
flashing on the machine holding the phone.

**Architecture:** Two entry points over the scripts already proven on hardware.
`build.sh` runs on the worker: it resolves target dependencies, delegates to the
per-target build scripts, and records provenance in `manifest.json`.
`provision.sh` runs where the phone is: it probes the device for real evidence,
emits `plan.json` saying what needs building, then runs skippable flash phases
and verifies the user-visible outcome. Neither reimplements build or flash
logic; they add ordering, provenance, skip detection and verification.

**Tech Stack:** bash, `python3` (JSON and the existing `edl`/`paramiko` venv),
`git`, `sha256sum`, `fastboot`, `debugfs`. No new host requirements beyond what
`check-env.sh` already asserts.

## Why one plan and not three

`manifest.json` and `plan.json` are contracts between the two halves. A contract
specified in one document and consumed in another is a mismatch waiting to
happen, and neither half is provably correct until the other exists. They are
built together, in one order, with the round trip tested end to end.

The destructive work is still **last and gated**: nothing writes a partition
table until the probe, the plan round trip and the non-destructive phases are
green.

## Why this exists at all

Not speculative. In a single session this repo hit every failure the pipeline
prevents:

- The kernel was built on the workstation instead of the 32-core worker, twice.
- A `boot.img` was flashed, the patch that produced it was **reverted**, and the
  device kept running an artifact not reproducible from `HEAD` — with nothing
  recording the divergence. It is still in that state today.
- `build-rootfs.sh` was run before `build-adaptation.sh` and aborted, because
  the dependency between them lived only in a human's head.
- Every flash cycle was a hand-typed sequence of five commands.

## Global Constraints

- **`build.sh` never touches a phone.** No `fastboot`, no `edl`, no device
  `ssh`. It must run with no phone in the building.
- **`provision.sh` never builds.** It probes, decides, transfers, flashes and
  verifies. If an artifact is missing it says so and stops.
- **Probe reality; never trust a stored marker.** No state file records "what we
  did last time". This repo has already been bricked once by trusting a claim
  over reality — the MSM GPT template *said* it was valid and was not.
- **Existence is not freshness.** An artifact is rebuilt when its recorded
  source commit differs from the current one. A dirty tree is never up to date.
- **Delegate, never reimplement.** Build logic stays in the per-target scripts;
  flashing stays in `flash.sh` and `restore-android.py`.
- **The `edl` phase refuses to run without explicit acknowledgement** on first
  use. Not to protect data — there is none worth keeping — but because a
  half-written GPT costs a full EDL recovery cycle.
- **Never reintroduce `fastboot -w` or `edl qfil`.** The first bootloops this
  device; the second destroyed the LUN0 GPT and is why this repo exists.
- Device naming is always `fajita`, never `oneplus6`.

---

## File Structure

```
build.sh                     worker: produces artifacts + manifest.json
provision.sh                 phone host: probe, plan, transfer, flash, verify
lib/
  probe.sh                   read-only device evidence, one function per state
  phases.sh                  the five flash phases and their skip predicates
tests/
  run-tests.sh               offline suite; no phone, no network, no real builds
  fixtures/
    fake-target              stands in for a per-target build script
    fake-git                 deterministic commit ids
    probe-droidian.txt       captured real probe output, booted device
    probe-fastboot.txt       captured real getvar output
    manifest.json            a known-good manifest
```

`provision.sh` keeps every device interaction behind `lib/probe.sh`, and every
write behind `lib/phases.sh`, so the decision logic is testable offline against
captured fixtures with no phone attached.

## Contract 1 — `manifest.json` (build.sh writes, provision.sh reads)

```json
{
  "generated": 1788545435,
  "repo_commit": "14d70e2",
  "artifacts": {
    "droidian/out/images/boot.img": {
      "target": "kernel",
      "version": "",
      "sha256": "1123a5...",
      "bytes": 33140736,
      "repo_commit": "14d70e2",
      "source_commit": "a11cace"
    },
    "droidian/out-adaptation/halium-hostdev-perms_1.0.0_all.deb": {
      "target": "adaptation",
      "version": "1.0.0",
      "sha256": "9f2b1c...",
      "bytes": 5632,
      "repo_commit": "14d70e2",
      "source_commit": "14d70e2"
    }
  }
}
```

`version` is parsed from `name_VERSION_arch.deb` and empty for images;
`provision.sh` compares it against `dpkg` inside the rootfs to decide whether
the `data` phase can be skipped. `source_commit` is the tree that produced the
artifact — for `kernel` that is `droidian/kernel`, a **separate checkout**, and
the one that mattered when a reverted DT patch stayed flashed. Both commit
fields carry a `-dirty` suffix when the tree has uncommitted changes.

## Contract 2 — `plan.json` (provision.sh writes, build.sh reads)

Deliberately minimal. It says *what to build*, never what to flash, so it stays
small enough to move by any means:

```json
{ "build": ["kernel", "rootfs"], "force": false }
```

## Contract 3 — phases

| Phase | Skips when | Destructive |
|---|---|---|
| `edl` | vendor fingerprint is OOS9 `9.0.17` **and** the GPT already has `linuxroot` | **yes** — rewrites the GPT |
| `boot` | `boot_<slot>` sha256 matches the manifest | no |
| `data` | `linuxroot` holds our rootfs at the manifest's package versions | **yes** |
| `activate` | `current-slot` is already the Droidian slot | no |
| `verify` | never skipped | no |

## Targets

| Target | Delegates to | Produces | Depends on |
|---|---|---|---|
| `kernel` | `droidian/build-kernel.sh` | `droidian/out/images/{boot,recovery,vbmeta}.img` | — |
| `camera` | `droidian/build-camera.sh` | `droidian/out-camera/*.deb` | — |
| `adaptation` | `droidian/adaptation/build-adaptation.sh` | `droidian/out-adaptation/*.deb` | — |
| `rootfs` | `droidian/build-rootfs.sh` | `droidian/userdata.img` | `camera`, `adaptation` |

`rootfs` depending on `camera` and `adaptation` is real and already enforced at
runtime: `build-rootfs.sh` aborts with `no .debs found` without them.

---
### Task 1: Test harness and the fake target

**Files:**
- Create: `tests/fixtures/fake-target`
- Create: `tests/run-tests.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `run-tests.sh` with `expect_contains` / `expect_absent` / `pass` /
  `fail` counters, extended by every later task. `fake-target` records each
  invocation so tests can assert ordering.

- [ ] **Step 1: Write the fake target**

It appends its own name to `$FT_LOG` and creates whatever output paths it is
given, so tests can assert both *what ran* and *in what order* without running
a real build.

`tests/fixtures/fake-target`:

```bash
#!/usr/bin/env bash
# Stands in for a real per-target build script. Records that it ran, in order,
# and creates the artifacts it was told to, so build.sh can be exercised
# end-to-end in milliseconds instead of twenty minutes.
set -euo pipefail
printf '%s\n' "${FT_NAME:?FT_NAME must be set}" >> "${FT_LOG:?FT_LOG must be set}"
for out in ${FT_OUTPUTS:-}; do
    mkdir -p "$(dirname "$out")"
    printf 'artifact %s\n' "$FT_NAME" > "$out"
done
exit "${FT_RC:-0}"
```

- [ ] **Step 2: Write the test runner**

`tests/run-tests.sh`:

```bash
#!/usr/bin/env bash
# Offline tests for build.sh. No phone, no network, no real builds.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
BUILD="$ROOT/build.sh"
pass=0; fail=0

expect_contains() {   # expect_contains <name> <file> <string>
    if grep -qF -- "$3" "$2"; then
        echo "  PASS  $1"; pass=$((pass+1))
    else
        echo "  FAIL  $1: expected to find: $3"
        sed 's/^/        /' "$2" | head -20
        fail=$((fail+1))
    fi
}

expect_absent() {   # expect_absent <name> <file> <string>
    if grep -qF -- "$3" "$2"; then
        echo "  FAIL  $1: should not contain: $3"; fail=$((fail+1))
    else
        echo "  PASS  $1"; pass=$((pass+1))
    fi
}

expect_rc() {   # expect_rc <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  PASS  $1"; pass=$((pass+1))
    else
        echo "  FAIL  $1: expected rc=$2 got rc=$3"; fail=$((fail+1))
    fi
}

echo ">>> build.sh tests"
# Task 2+ append their cases below this line.

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 3: Run it to confirm the harness works**

```bash
chmod +x tests/run-tests.sh tests/fixtures/fake-target
./tests/run-tests.sh
```

Expected: prints `>>> build.sh tests` then `passed=0 failed=0`, exits 0.

- [ ] **Step 4: Commit**

```bash
git add tests
git commit -m "test(build): offline harness and a fake build target"
```

---

### Task 2: `--list`, the target table, and the command seam

**Files:**
- Create: `build.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `fake-target` and the runner from Task 1.
- Produces: `build.sh` with `targets`, `target_outputs <name>`, `target_deps <name>`,
  `target_cmd <name>`, and a `--list` flag. Later tasks call these.
  `BUILD_TARGET_CMD_<name>` overrides the command a target runs; this is the
  seam every later test relies on.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-tests.sh` above the final `echo`:

```bash
out=$("$BUILD" --list 2>&1); rc=$?
echo "$out" > /tmp/b-list.$$
expect_rc "--list exits 0" 0 "$rc"
expect_contains "lists kernel"     /tmp/b-list.$$ 'kernel'
expect_contains "lists camera"     /tmp/b-list.$$ 'camera'
expect_contains "lists adaptation" /tmp/b-list.$$ 'adaptation'
expect_contains "lists rootfs"     /tmp/b-list.$$ 'rootfs'
expect_contains "shows the rootfs dependency" /tmp/b-list.$$ 'camera adaptation'
expect_contains "shows an output path" /tmp/b-list.$$ 'droidian/userdata.img'

out=$("$BUILD" nosuchtarget 2>&1); rc=$?
echo "$out" > /tmp/b-bad.$$
expect_rc "unknown target fails" 1 "$rc"
expect_contains "unknown target names itself" /tmp/b-bad.$$ 'nosuchtarget'
rm -f /tmp/b-list.$$ /tmp/b-bad.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: every case FAILs — `build.sh` does not exist yet.

- [ ] **Step 3: Write build.sh**

```bash
#!/usr/bin/env bash
#
# Build every artifact the phone needs, on a machine with cores.
#
#   ./build.sh                     # everything that is missing or stale
#   ./build.sh kernel rootfs       # only these targets, plus their deps
#   ./build.sh --list              # show targets, outputs and dependencies
#   ./build.sh --plan plan.json    # build what a provision.sh plan asks for
#   FORCE=1 ./build.sh             # rebuild even if up to date
#
# This never touches a phone. It is an orchestrator: every target delegates to
# a script that already exists and is already proven on hardware. What it adds
# is dependency ordering, provenance, and staleness detection -- the three
# things those scripts cannot do for themselves, and whose absence has already
# shipped a reverted patch to a device.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORCE="${FORCE:-0}"

say()  { printf '\n>>> %s\n' "$*"; }
die()  { echo "build.sh: $*" >&2; exit 1; }

targets() { echo "kernel camera adaptation rootfs"; }

target_deps() {
    case "$1" in
        # build-rootfs.sh installs these .debs into rootfs.img and aborts with
        # "no .debs found" without them. The order is real, not cosmetic.
        rootfs) echo "camera adaptation" ;;
        *)      echo "" ;;
    esac
}

target_outputs() {
    case "$1" in
        kernel)     echo "droidian/out/images/boot.img droidian/out/images/vbmeta.img" ;;
        camera)     echo "droidian/out-camera" ;;
        adaptation) echo "droidian/out-adaptation" ;;
        rootfs)     echo "droidian/userdata.img" ;;
        *)          echo "" ;;
    esac
}

# The command seam. Tests override BUILD_TARGET_CMD_<name> so the orchestrator
# can be exercised without a twenty-minute kernel build.
target_cmd() {
    local override
    override="BUILD_TARGET_CMD_$1"
    if [ -n "${!override:-}" ]; then printf '%s\n' "${!override}"; return; fi
    case "$1" in
        kernel)     echo "$HERE/droidian/build-kernel.sh" ;;
        camera)     echo "$HERE/droidian/build-camera.sh" ;;
        adaptation) echo "$HERE/droidian/adaptation/build-adaptation.sh" ;;
        rootfs)     echo "$HERE/droidian/build-rootfs.sh" ;;
        *)          echo "" ;;
    esac
}

is_target() {
    local t
    for t in $(targets); do [ "$t" = "$1" ] && return 0; done
    return 1
}

do_list() {
    printf '%-12s %-28s %s\n' TARGET DEPENDS OUTPUTS
    local t
    for t in $(targets); do
        printf '%-12s %-28s %s\n' "$t" "$(target_deps "$t")" "$(target_outputs "$t")"
    done
}

# ------------------------------------------------------------------ arguments
want=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list) do_list; exit 0 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) die "unknown flag: $1" ;;
        *)  is_target "$1" || die "unknown target: $1 (try --list)"
            want+=("$1"); shift ;;
    esac
done

[ ${#want[@]} -gt 0 ] || want=($(targets))
```

- [ ] **Step 4: Run to verify it passes**

```bash
chmod +x build.sh
./tests/run-tests.sh
```

Expected: `passed=9 failed=0`.

- [ ] **Step 5: Commit**

```bash
git add build.sh tests/run-tests.sh
git commit -m "feat(build): target table, --list, and the command seam

Targets delegate to the per-target scripts that are already proven on
hardware. BUILD_TARGET_CMD_<name> makes the orchestrator testable offline
without invoking a real twenty-minute build."
```

---

### Task 3: Dependency resolution and build order

**Files:**
- Modify: `build.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `target_deps`, `target_cmd`, `targets` from Task 2.
- Produces: `resolve <targets...>` printing a deduplicated, dependency-first
  build order on stdout, and `run_target <name>` which executes it. Task 4 wraps
  `run_target` with staleness checks; Task 5 feeds `resolve` from a plan file.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-tests.sh`:

```bash
ftlog=$(mktemp)
run_fake() {   # run_fake <args...>   -- runs build.sh with every target faked
    : > "$ftlog"
    local t
    local -a env=()
    for t in kernel camera adaptation rootfs; do
        env+=("BUILD_TARGET_CMD_$t=env FT_NAME=$t FT_LOG=$ftlog $HERE/fixtures/fake-target")
    done
    env FORCE=1 "${env[@]}" "$BUILD" "$@" > /tmp/b-run.$$ 2>&1
}

run_fake rootfs
expect_contains "rootfs pulls in camera"     "$ftlog" 'camera'
expect_contains "rootfs pulls in adaptation" "$ftlog" 'adaptation'
expect_contains "rootfs itself runs"         "$ftlog" 'rootfs'
expect_absent  "rootfs does not pull kernel" "$ftlog" 'kernel'

# Dependencies must come first, or build-rootfs.sh aborts with "no .debs found".
if [ "$(tail -1 "$ftlog")" = rootfs ]; then
    echo "  PASS  dependencies run before rootfs"; pass=$((pass+1))
else
    echo "  FAIL  dependencies run before rootfs: order was $(tr '\n' ' ' < "$ftlog")"; fail=$((fail+1))
fi

# A target named twice, directly and as a dependency, must run once.
run_fake camera rootfs
expect_rc "camera built exactly once" 1 "$(grep -c '^camera$' "$ftlog")"

# A failing target stops the build; nothing after it runs.
: > "$ftlog"
env FORCE=1 \
    "BUILD_TARGET_CMD_camera=env FT_NAME=camera FT_LOG=$ftlog FT_RC=1 $HERE/fixtures/fake-target" \
    "BUILD_TARGET_CMD_adaptation=env FT_NAME=adaptation FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "BUILD_TARGET_CMD_rootfs=env FT_NAME=rootfs FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "$BUILD" rootfs > /tmp/b-fail.$$ 2>&1
rc=$?
expect_rc "a failing dependency fails the build" 1 "$rc"
expect_absent "nothing runs after a failure" "$ftlog" 'rootfs'
expect_contains "the failing target is named" /tmp/b-fail.$$ 'camera'
rm -f "$ftlog" /tmp/b-run.$$ /tmp/b-fail.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: the new cases FAIL — nothing runs targets yet.

- [ ] **Step 3: Implement resolve and run_target**

Insert above the `# ---- arguments` block in `build.sh`:

```bash
# Depth-first, dependencies before dependants, each target once. The graph is
# four nodes and one edge; it does not need a topological sort library.
resolve() {
    local seen="" out="" t d
    _visit() {
        local n=$1 dep
        case " $seen " in *" $n "*) return ;; esac
        seen="$seen $n"
        for dep in $(target_deps "$n"); do _visit "$dep"; done
        out="$out $n"
    }
    for t in "$@"; do _visit "$t"; done
    printf '%s\n' $out
}

run_target() {
    local name=$1 cmd
    cmd=$(target_cmd "$name")
    [ -n "$cmd" ] || die "no command for target: $name"
    say "building $name"
    if ! eval "$cmd"; then
        die "target failed: $name"
    fi
}
```

- [ ] **Step 4: Drive it from the argument block**

Append to the end of `build.sh`:

```bash
order=$(resolve "${want[@]}")
say "build order:$(printf ' %s' $order)"
for t in $order; do
    run_target "$t"
done
say "done"
```

- [ ] **Step 5: Run to verify it passes**

```bash
./tests/run-tests.sh
```

Expected: `passed=17 failed=0`.

- [ ] **Step 6: Commit**

```bash
git add build.sh tests/run-tests.sh
git commit -m "feat(build): resolve dependencies and stop on the first failure

rootfs consumes the camera and adaptation .debs, and build-rootfs.sh aborts
without them. That ordering lived only in a human's head and was got wrong;
now it is enforced and tested."
```

---

### Task 4: Provenance and `manifest.json`

**Files:**
- Modify: `build.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `target_outputs`, `resolve` from Tasks 2–3.
- Produces: `git_commit <dir>` and `write_manifest <targets...>`, emitting
  `droidian/manifest.json`. `provision.sh` consumes this file; the schema below
  is the contract and later plans depend on these exact key names.

**Schema.** One object, `artifacts` keyed by path:

```json
{
  "generated": 1788545435,
  "repo_commit": "14d70e2",
  "artifacts": {
    "droidian/out/images/boot.img": {
      "target": "kernel",
      "version": "",
      "sha256": "1123a5...",
      "bytes": 33140736,
      "repo_commit": "14d70e2",
      "source_commit": "a11cace"
    },
    "droidian/out-adaptation/halium-hostdev-perms_1.0.0_all.deb": {
      "target": "adaptation",
      "version": "1.0.0",
      "sha256": "9f2b1c...",
      "bytes": 5632,
      "repo_commit": "14d70e2",
      "source_commit": "14d70e2"
    }
  }
}
```

`version` is the Debian version parsed from a `.deb` filename
(`name_VERSION_arch.deb`) and empty for images. `provision.sh` compares it
against `dpkg` inside the rootfs to decide whether the `data` phase can be
skipped, which is why it is recorded rather than re-derived later.

`repo_commit` is this repo at build time. `source_commit` is the tree that
actually produced the artifact — for `kernel` that is `droidian/kernel`, which
is a *separate* checkout and the one that mattered when a reverted DT patch
stayed flashed on the device. Both carry a `-dirty` suffix when the tree has
uncommitted changes.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-tests.sh`:

```bash
export BUILD_GIT_CMD="$HERE/fixtures/fake-git"
cat > "$HERE/fixtures/fake-git" <<'FG'
#!/usr/bin/env bash
# Deterministic stand-in for git rev-parse / status, so manifest tests do not
# depend on the state of the real repository.
case "${FG_DIRTY:-0}:$1" in
    1:*) echo "cafe123-dirty" ;;
    *)   echo "cafe123" ;;
esac
FG
chmod +x "$HERE/fixtures/fake-git"

run_fake kernel
M=droidian/manifest.json
if [ -f "$ROOT/$M" ]; then
    echo "  PASS  manifest is written"; pass=$((pass+1))
else
    echo "  FAIL  manifest is written"; fail=$((fail+1))
fi
python3 -c "import json,sys; json.load(open('$ROOT/$M'))" 2>/dev/null \
    && { echo "  PASS  manifest is valid JSON"; pass=$((pass+1)); } \
    || { echo "  FAIL  manifest is valid JSON"; fail=$((fail+1)); }
cp "$ROOT/$M" /tmp/b-man.$$
expect_contains "manifest records the artifact"    /tmp/b-man.$$ 'boot.img'
expect_contains "manifest records the target"      /tmp/b-man.$$ 'kernel'
expect_contains "manifest records a sha256"        /tmp/b-man.$$ 'sha256'
expect_contains "manifest records the repo commit" /tmp/b-man.$$ 'cafe123'
expect_contains "manifest records a source commit" /tmp/b-man.$$ 'source_commit'
expect_contains "manifest has a version field"     /tmp/b-man.$$ 'version'

# A dirty tree must be visible, not silently identical to a clean one.
FG_DIRTY=1 run_fake kernel
cp "$ROOT/$M" /tmp/b-dirty.$$
expect_contains "a dirty tree is marked" /tmp/b-dirty.$$ 'cafe123-dirty'
rm -f /tmp/b-man.$$ /tmp/b-dirty.$$
```

Note `run_fake` must be extended to pass `FG_DIRTY` through; change its `env`
invocation to `env FORCE=1 FG_DIRTY="${FG_DIRTY:-0}" ...`.

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: the manifest cases FAIL — no manifest is written yet.

- [ ] **Step 3: Implement provenance**

Add to `build.sh` above `resolve`:

```bash
# Overridable so manifest tests do not depend on the real repository state.
git_commit() {
    local dir=$1
    if [ -n "${BUILD_GIT_CMD:-}" ]; then "$BUILD_GIT_CMD" "$dir"; return; fi
    [ -d "$dir/.git" ] || { echo "unknown"; return; }
    local c dirty=""
    c=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null) || { echo "unknown"; return; }
    [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ] && dirty="-dirty"
    printf '%s%s\n' "$c" "$dirty"
}

# The tree that actually produced the artifact. For the kernel this is a
# SEPARATE checkout from the repo, and it is the one that matters: a DT patch
# was reverted here while the built boot.img stayed on the device, with nothing
# recording the divergence.
source_commit() {
    case "$1" in
        kernel) git_commit "$HERE/droidian/kernel" ;;
        *)      git_commit "$HERE" ;;
    esac
}
```

- [ ] **Step 4: Implement write_manifest**

Add below `run_target`:

```bash
# Expand a target's outputs to real files. Directory outputs (the .deb dirs)
# contribute each file they contain.
target_files() {
    local o
    for o in $(target_outputs "$1"); do
        if [ -d "$HERE/$o" ]; then
            find "$HERE/$o" -type f -name '*.deb' 2>/dev/null | sed "s|^$HERE/||"
        elif [ -f "$HERE/$o" ]; then
            printf '%s\n' "$o"
        fi
    done
}

write_manifest() {
    local repo; repo=$(git_commit "$HERE")
    local tmp; tmp=$(mktemp)
    local t f
    for t in "$@"; do
        local sc; sc=$(source_commit "$t")
        while read -r f; do
            [ -n "$f" ] || continue
            # name_VERSION_arch.deb -> VERSION; empty for images.
            local ver=""
            case "$f" in *_*_*.deb) ver=$(basename "$f" | cut -d_ -f2) ;; esac
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$f" "$t" "$(sha256sum "$HERE/$f" | cut -d' ' -f1)" \
                "$(stat -c%s "$HERE/$f")" "$sc" "$ver"
        done < <(target_files "$t")
    done > "$tmp"

    REPO_COMMIT="$repo" python3 - "$tmp" "$HERE/droidian/manifest.json" <<'PY'
import json, os, sys, time
rows, out = sys.argv[1], sys.argv[2]
artifacts = {}
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
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(f"manifest: {len(artifacts)} artifacts -> {out}")
PY
}
```

- [ ] **Step 5: Call it after the build loop**

Replace the trailing `say "done"` in `build.sh` with:

```bash
write_manifest $order
say "done"
```

- [ ] **Step 6: Run to verify it passes**

```bash
./tests/run-tests.sh
```

Expected: `passed=26 failed=0`.

- [ ] **Step 7: Ignore the manifest**

`manifest.json` describes one machine's output tree, so it is not tracked.
Append to `.gitignore`:

```
droidian/manifest.json
```

- [ ] **Step 8: Commit**

```bash
git add build.sh tests .gitignore
git commit -m "feat(build): record what each artifact was actually built from

manifest.json carries the sha256 plus the repo commit and the source-tree
commit per artifact. The kernel tree is a separate checkout, and that is
exactly the case that went wrong: a DT patch was reverted in the repo while
the built boot.img stayed flashed, with nothing recording the divergence."
```

---

### Task 5: Staleness — rebuild when the source moved

**Files:**
- Modify: `build.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `write_manifest`, `source_commit`, `target_files` from Task 4.
- Produces: `is_stale <target>` returning 0 when the target must be rebuilt.
  Task 6 lets a plan file force a rebuild regardless.

**The rule.** A target is stale when any of these hold:

1. `FORCE=1`.
2. It has no outputs on disk.
3. `manifest.json` is missing, unreadable, or has no entry for an output.
4. The recorded `source_commit` differs from the current one.
5. The recorded `source_commit` ends in `-dirty` — an uncommitted tree is not
   reproducible, so its output can never be assumed current.

Rule 4 is the one that matters. Existence-only checks are what let a `boot.img`
built from a since-reverted patch stay on a device.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-tests.sh`:

```bash
# A second identical run rebuilds nothing.
run_fake kernel                      # FORCE=1, always builds, writes manifest
: > "$ftlog"
env FG_DIRTY=0 BUILD_GIT_CMD="$HERE/fixtures/fake-git" \
    "BUILD_TARGET_CMD_kernel=env FT_NAME=kernel FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "$BUILD" kernel > /tmp/b-skip.$$ 2>&1
expect_absent  "an up-to-date target is skipped" "$ftlog" 'kernel'
expect_contains "the skip is reported"           /tmp/b-skip.$$ 'up to date'

# Move the source commit: it must rebuild.
cat > "$HERE/fixtures/fake-git" <<'FG'
#!/usr/bin/env bash
echo "beef456"
FG
chmod +x "$HERE/fixtures/fake-git"
: > "$ftlog"
env BUILD_GIT_CMD="$HERE/fixtures/fake-git" \
    "BUILD_TARGET_CMD_kernel=env FT_NAME=kernel FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "$BUILD" kernel > /tmp/b-moved.$$ 2>&1
expect_contains "a moved source commit rebuilds" "$ftlog" 'kernel'
expect_contains "the reason is reported"         /tmp/b-moved.$$ 'source moved'

# A dirty tree is never considered up to date.
cat > "$HERE/fixtures/fake-git" <<'FG'
#!/usr/bin/env bash
echo "beef456-dirty"
FG
chmod +x "$HERE/fixtures/fake-git"
env BUILD_GIT_CMD="$HERE/fixtures/fake-git" \
    "BUILD_TARGET_CMD_kernel=env FT_NAME=kernel FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "$BUILD" kernel > /dev/null 2>&1
: > "$ftlog"
env BUILD_GIT_CMD="$HERE/fixtures/fake-git" \
    "BUILD_TARGET_CMD_kernel=env FT_NAME=kernel FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "$BUILD" kernel > /tmp/b-dirty2.$$ 2>&1
expect_contains "a dirty tree always rebuilds" "$ftlog" 'kernel'
expect_contains "the dirty reason is reported" /tmp/b-dirty2.$$ 'dirty'

# A deleted artifact rebuilds even when the commit matches.
cat > "$HERE/fixtures/fake-git" <<'FG'
#!/usr/bin/env bash
echo "cafe123"
FG
chmod +x "$HERE/fixtures/fake-git"
run_fake kernel
rm -f "$ROOT/droidian/out/images/boot.img"
: > "$ftlog"
env BUILD_GIT_CMD="$HERE/fixtures/fake-git" \
    "BUILD_TARGET_CMD_kernel=env FT_NAME=kernel FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "$BUILD" kernel > /tmp/b-gone.$$ 2>&1
expect_contains "a missing artifact rebuilds" "$ftlog" 'kernel'
expect_contains "the missing reason is reported" /tmp/b-gone.$$ 'missing'
rm -f /tmp/b-skip.$$ /tmp/b-moved.$$ /tmp/b-dirty2.$$ /tmp/b-gone.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: the staleness cases FAIL — every run currently builds.

- [ ] **Step 3: Implement is_stale**

Add to `build.sh` above `run_target`:

```bash
MANIFEST="$HERE/droidian/manifest.json"

# Prints a human reason on stdout and returns 0 when the target must be built.
# "Exists" is deliberately NOT sufficient: an artifact built from a commit the
# repo has since moved past is exactly how a reverted patch stayed on a device.
is_stale() {
    local name=$1 cur; cur=$(source_commit "$name")

    [ "$FORCE" = 1 ] && { echo "FORCE=1"; return 0; }

    case "$cur" in
        *-dirty) echo "source tree is dirty ($cur)"; return 0 ;;
        unknown) echo "source commit unknown"; return 0 ;;
    esac

    local files; files=$(target_files "$name")
    [ -n "$files" ] || { echo "outputs missing"; return 0; }

    local o
    for o in $(target_outputs "$name"); do
        [ -e "$HERE/$o" ] || { echo "output missing: $o"; return 0; }
    done

    [ -f "$MANIFEST" ] || { echo "no manifest"; return 0; }

    local recorded
    recorded=$(MAN="$MANIFEST" FILES="$files" CUR="$cur" python3 - <<'PY'
import json, os, sys
try:
    doc = json.load(open(os.environ["MAN"]))
except Exception:
    print("unreadable manifest"); sys.exit(0)
arts = doc.get("artifacts", {})
for f in os.environ["FILES"].split():
    a = arts.get(f)
    if a is None:
        print(f"not in manifest: {f}"); sys.exit(0)
    if a.get("source_commit") != os.environ["CUR"]:
        print(f"source moved: {a.get('source_commit')} -> {os.environ['CUR']}")
        sys.exit(0)
print("")
PY
)
    [ -n "$recorded" ] && { echo "$recorded"; return 0; }
    return 1
}
```

- [ ] **Step 4: Use it in the build loop**

Replace the loop at the end of `build.sh` with:

```bash
built=()
for t in $order; do
    if reason=$(is_stale "$t"); then
        say "building $t  ($reason)"
        run_target "$t"
        built+=("$t")
    else
        printf '    %-12s up to date\n' "$t"
    fi
done
write_manifest $order
say "done${built[*]+ (built: ${built[*]})}"
```

Note `run_target` no longer prints its own `building` line; delete the
`say "building $name"` from it so the reason is not printed twice.

- [ ] **Step 5: Run to verify it passes**

```bash
./tests/run-tests.sh
```

Expected: `passed=34 failed=0`.

- [ ] **Step 6: Commit**

```bash
git add build.sh tests/run-tests.sh
git commit -m "feat(build): rebuild when the source moved, not merely when absent

Existence is not freshness. A boot.img built from a DT patch the repo later
reverted stayed flashed on the device with nothing recording it. A target is
now stale when its recorded source_commit differs from the current one, and a
dirty tree is never considered up to date because it is not reproducible."
```

---

### Task 6: `--plan plan.json`, and the real end-to-end run

**Files:**
- Modify: `build.sh`
- Modify: `tests/run-tests.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: `resolve` and `is_stale` from Tasks 3 and 5.
- Produces: the `--plan` flag, consuming Contract 2. Task 9
  (`provision.sh --plan-only`) writes exactly this file, and Task 9 tests the
  round trip between them.

**Input schema.** Contract 2, repeated here for the implementer:

```json
{ "build": ["kernel", "rootfs"], "force": false }
```

`force: true` rebuilds even when up to date, for when the phone host has
evidence the worker cannot see.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-tests.sh`:

```bash
printf '{"build":["camera"],"force":false}\n' > /tmp/b-plan.$$
: > "$ftlog"
env BUILD_GIT_CMD="$HERE/fixtures/fake-git" \
    "BUILD_TARGET_CMD_camera=env FT_NAME=camera FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "$BUILD" --plan /tmp/b-plan.$$ > /tmp/b-planout.$$ 2>&1
expect_contains "a plan selects its targets" "$ftlog" 'camera'
expect_absent  "a plan builds nothing else"  "$ftlog" 'kernel'

printf '{"build":["nosuch"]}\n' > /tmp/b-badplan.$$
"$BUILD" --plan /tmp/b-badplan.$$ > /tmp/b-badout.$$ 2>&1; rc=$?
expect_rc "a plan naming an unknown target fails" 1 "$rc"
expect_contains "the unknown target is named" /tmp/b-badout.$$ 'nosuch'

"$BUILD" --plan /tmp/does-not-exist.json > /tmp/b-nofile.$$ 2>&1; rc=$?
expect_rc "a missing plan file fails" 1 "$rc"

printf 'not json at all\n' > /tmp/b-junk.$$
"$BUILD" --plan /tmp/b-junk.$$ > /tmp/b-junkout.$$ 2>&1; rc=$?
expect_rc "a malformed plan fails loudly" 1 "$rc"
rm -f /tmp/b-plan.$$ /tmp/b-planout.$$ /tmp/b-badplan.$$ /tmp/b-badout.$$ \
      /tmp/b-nofile.$$ /tmp/b-junk.$$ /tmp/b-junkout.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: the `--plan` cases FAIL — the flag does not exist.

- [ ] **Step 3: Implement --plan**

Add to `build.sh` above the argument loop:

```bash
read_plan() {
    local f=$1
    [ -f "$f" ] || die "no such plan file: $f"
    PLAN_FILE="$f" python3 - <<'PY' || exit 1
import json, os, sys
try:
    doc = json.load(open(os.environ["PLAN_FILE"]))
except Exception as e:
    print(f"build.sh: malformed plan: {e}", file=sys.stderr); sys.exit(1)
targets = doc.get("build") or []
if not isinstance(targets, list) or not all(isinstance(t, str) for t in targets):
    print("build.sh: plan 'build' must be a list of strings", file=sys.stderr); sys.exit(1)
print(" ".join(targets))
print("1" if doc.get("force") else "0")
PY
}
```

Add a `--plan` case to the argument loop, before the `-*` catch-all:

```bash
        --plan)
            shift; [ $# -gt 0 ] || die "--plan needs a file"
            plan_out=$(read_plan "$1") || exit 1
            plan_targets=$(printf '%s\n' "$plan_out" | sed -n 1p)
            [ "$(printf '%s\n' "$plan_out" | sed -n 2p)" = 1 ] && FORCE=1
            for t in $plan_targets; do
                is_target "$t" || die "unknown target in plan: $t (try --list)"
                want+=("$t")
            done
            shift ;;
```

- [ ] **Step 4: Run to verify it passes**

```bash
./tests/run-tests.sh
```

Expected: `passed=40 failed=0`.

- [ ] **Step 5: Run it for real, on the worker**

This is the acceptance test. It must run on taichi, not the workstation — the
whole point is that building happens where the cores are.

```bash
git bundle create /tmp/op6t.bundle main
scp /tmp/op6t.bundle taichi:/tmp/
ssh taichi 'cd ~/oneplus6t && git fetch -q /tmp/op6t.bundle main && git reset -q --hard FETCH_HEAD'
ssh taichi 'cd ~/oneplus6t && ./check-env.sh build'
ssh taichi 'cd ~/oneplus6t && ./build.sh --list'
ssh taichi 'cd ~/oneplus6t && ./build.sh adaptation'
ssh taichi 'cd ~/oneplus6t && python3 -m json.tool droidian/manifest.json'
```

Expected: `adaptation` builds, three `.deb`s appear in the manifest with a
`source_commit` matching `git -C ~/oneplus6t rev-parse --short HEAD`.

- [ ] **Step 6: Prove the staleness rule on real artifacts**

```bash
ssh taichi 'cd ~/oneplus6t && ./build.sh adaptation'
```

Expected: `adaptation    up to date`, and nothing rebuilds.

```bash
ssh taichi 'cd ~/oneplus6t && touch droidian/adaptation/tests/run-tests.sh && ./build.sh adaptation'
```

Expected: rebuilds, reporting `source tree is dirty`. This is the check that a
timestamp-only or existence-only design would miss.

- [ ] **Step 7: Rebuild the kernel and settle the outstanding divergence**

The device is currently running a `boot.img` built from a DT patch that commit
`14d70e2` reverted. This is the first real use of the tool:

```bash
ssh taichi 'cd ~/oneplus6t && ./build.sh kernel'
```

Expected: it rebuilds — `source moved` or `source tree is dirty` — rather than
reporting the existing patched image as up to date. Record the new
`source_commit` from the manifest; Task 12 flashes it.

- [ ] **Step 8: Document it**

In `README.md`, replace the `build.sh` row status in the pipeline table with
**works**, and add beneath the table:

```markdown
`build.sh` runs on the worker and never touches a phone. It resolves target
dependencies, delegates to the per-target scripts, and writes
`droidian/manifest.json` recording the sha256 and the source commit of every
artifact. A target is rebuilt when its source commit has moved, not merely when
its output is missing — an artifact built from a since-reverted patch is
otherwise indistinguishable from a current one, which has already happened here.
```

- [ ] **Step 9: Commit**

```bash
git add build.sh tests/run-tests.sh README.md
git commit -m "feat(build): accept a provision plan and document the tool

plan.json says what to build, never what to flash, so it stays small enough to
move between the two machines by any means. Malformed or unknown input fails
loudly rather than silently building nothing."
```

---


### Task 7: `lib/probe.sh` — read real evidence, write nothing

**Files:**
- Create: `lib/probe.sh`
- Create: `tests/fixtures/probe-droidian.txt`, `tests/fixtures/probe-fastboot.txt`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `./device.sh state` (already on hardware).
- Produces: `probe_all` printing `key=value` lines on stdout, one per fact.
  Tasks 8–13 consume these keys and no others:

  | key | meaning | source |
  |---|---|---|
  | `state` | `droidian`/`fastboot`/`edl`/`off`/… | `device.sh state` |
  | `slot` | active slot, `a` or `b` | `fastboot getvar current-slot`, or ssh |
  | `vendor_fp` | vendor build fingerprint — **diagnostic only**, no phase decides on it; `oos_version` is the discriminator | `/vendor/build.prop` over ssh |
  | `oos_version` | e.g. `9.0.17` | `ro.oxygen.version` |
  | `has_linuxroot` | `yes`/`no` | GPT partition names |
  | `boot_sha` | sha256 of the active `boot` partition | EDL/fastboot read-back |
  | `pkg_<name>` | installed version inside the rootfs | `dpkg` over ssh |
  | `probe_complete` | `yes` only when every key above was obtained | — |

**Rule.** A fact that could not be read is emitted as `key=unknown`, never
omitted and never guessed. `probe_complete=no` then forces every phase to run
rather than silently skipping on absent evidence — the failure mode that a
missing value would otherwise cause is a skipped destructive step.

- [ ] **Step 1: Capture the fixtures from the real device**

These must be captured, not invented, so the parser is tested against the exact
shape the hardware produces:

```bash
./device.sh state
.venv/bin/python droidian/ssh.py -r 'grep -E "^ro\.(build\.fingerprint|oxygen\.version)" /vendor/build.prop /system/build.prop 2>/dev/null; echo ---; dpkg -l halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita droidian-camera 2>/dev/null | grep "^ii"' \
  > tests/fixtures/probe-droidian.txt
./device.sh goto fastboot
{ fastboot getvar current-slot; fastboot getvar all; } 2>&1 | head -40 \
  > tests/fixtures/probe-fastboot.txt
```

Commit both. If a future Droidian changes these formats, the tests fail here
rather than in a flash phase.

- [ ] **Step 2: Write the failing tests**

Append to `tests/run-tests.sh`:

```bash
PROBE="$ROOT/lib/probe.sh"

# Droidian: everything readable over ssh.
PROBE_STATE=droidian PROBE_SSH_FIXTURE="$HERE/fixtures/probe-droidian.txt" \
    bash "$PROBE" probe_all > /tmp/p-dro.$$ 2>&1
expect_contains "state is reported"        /tmp/p-dro.$$ 'state=droidian'
expect_contains "oxygen version is parsed" /tmp/p-dro.$$ 'oos_version=9.0.17'
expect_contains "package versions parsed"  /tmp/p-dro.$$ 'pkg_halium-hostdev-perms=1.0.0'
expect_contains "probe is complete"        /tmp/p-dro.$$ 'probe_complete=yes'

# fastboot: less is readable, and what is missing must say so.
PROBE_STATE=fastboot PROBE_FB_FIXTURE="$HERE/fixtures/probe-fastboot.txt" \
    bash "$PROBE" probe_all > /tmp/p-fb.$$ 2>&1
expect_contains "slot is parsed in fastboot" /tmp/p-fb.$$ 'slot='
expect_contains "unreadable facts say unknown" /tmp/p-fb.$$ '=unknown'
expect_contains "an incomplete probe says so"  /tmp/p-fb.$$ 'probe_complete=no'

# A powered-off phone must not produce confident answers.
PROBE_STATE=off bash "$PROBE" probe_all > /tmp/p-off.$$ 2>&1
expect_contains "off reports its state"   /tmp/p-off.$$ 'state=off'
expect_contains "off is never complete"   /tmp/p-off.$$ 'probe_complete=no'
expect_absent  "off invents no versions"  /tmp/p-off.$$ 'oos_version=9'
rm -f /tmp/p-dro.$$ /tmp/p-fb.$$ /tmp/p-off.$$
```

- [ ] **Step 3: Write lib/probe.sh**

```bash
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
SSHPY="$HERE/.venv/bin/python $HERE/droidian/ssh.py"

device_state() {
    [ -n "${PROBE_STATE:-}" ] && { printf '%s\n' "$PROBE_STATE"; return; }
    "$HERE/device.sh" state 2>/dev/null || echo unknown
}

ssh_blob() {
    [ -n "${PROBE_SSH_FIXTURE:-}" ] && { cat "$PROBE_SSH_FIXTURE"; return; }
    $SSHPY -r 'grep -E "^ro\.(build\.fingerprint|oxygen\.version)" /vendor/build.prop /system/build.prop 2>/dev/null; echo ---; dpkg -l halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita droidian-camera 2>/dev/null | grep "^ii"' 2>/dev/null
}

fb_blob() {
    [ -n "${PROBE_FB_FIXTURE:-}" ] && { cat "$PROBE_FB_FIXTURE"; return; }
    { fastboot getvar current-slot; fastboot getvar all; } 2>&1
}

emit() { printf '%s=%s\n' "$1" "${2:-unknown}"; }

probe_all() {
    local state; state=$(device_state)
    emit state "$state"

    local slot=unknown vfp=unknown oos=unknown lr=unknown bootsha=unknown
    local complete=no blob=""

    case "$state" in
        droidian)
            blob=$(ssh_blob)
            oos=$(sed -n 's/^.*ro\.oxygen\.version=//p'      <<<"$blob" | head -1)
            vfp=$(sed -n 's/^.*ro\.build\.fingerprint=//p'   <<<"$blob" | head -1)
            slot=$(printf '%s' "${PROBE_SLOT:-}")
            # Package versions: "ii  name  version  arch  desc"
            while read -r _ name ver _; do
                [ -n "${name:-}" ] || continue
                emit "pkg_$name" "$ver"
            done < <(grep '^ii' <<<"$blob")
            [ -n "$oos" ] && [ -n "$vfp" ] && complete=yes
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
    emit boot_sha       "${bootsha:-unknown}"
    emit probe_complete "$complete"
}

"${@:-probe_all}"
```

- [ ] **Step 4: Run to verify it passes**

```bash
chmod +x lib/probe.sh
./tests/run-tests.sh
```

Expected: `passed=50 failed=0`.

- [ ] **Step 5: Run it against the real phone**

```bash
./lib/probe.sh probe_all
```

Expected: `state=droidian`, `oos_version=9.0.17`, a `pkg_` line per adaptation
package, `probe_complete=yes`. If any line reads `unknown` that a fixture says
should parse, fix the parser — not the fixture.

- [ ] **Step 6: Commit**

```bash
git add lib/probe.sh tests
git commit -m "feat(provision): read device evidence, writing nothing

Facts that cannot be read are emitted as unknown rather than omitted, and
probe_complete gates skipping. An absent key would otherwise let a destructive
phase skip itself on missing evidence, which is the dangerous direction."
```

---

### Task 8: `provision.sh --plan-only` and the round trip

**Files:**
- Create: `provision.sh`
- Modify: `tests/run-tests.sh`
- Create: `tests/fixtures/manifest.json`

**Interfaces:**
- Consumes: `probe_all` (Task 7), `manifest.json` (Task 4), `build.sh --plan`
  (Task 6).
- Produces: `decide_build <probe-file> <manifest-file>` printing the target
  names that need building, and `provision.sh --plan-only` writing Contract 2.

**Decision rule.** A target needs building when the manifest has no artifact for
it, or when the probe shows the device does not already carry it. When
`probe_complete=no`, every target is requested — an unreadable device is never
evidence that something can be skipped.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-tests.sh`:

```bash
PROV="$ROOT/provision.sh"
cat > "$HERE/fixtures/manifest.json" <<'MJ'
{
  "generated": 1788545435,
  "repo_commit": "cafe123",
  "artifacts": {
    "droidian/out/images/boot.img": {
      "target": "kernel", "version": "", "sha256": "aaaa",
      "bytes": 1, "repo_commit": "cafe123", "source_commit": "cafe123"
    },
    "droidian/userdata.img": {
      "target": "rootfs", "version": "", "sha256": "bbbb",
      "bytes": 1, "repo_commit": "cafe123", "source_commit": "cafe123"
    }
  }
}
MJ

printf 'state=droidian\nprobe_complete=yes\noos_version=9.0.17\nboot_sha=aaaa\n' > /tmp/pr-ok.$$
"$PROV" --plan-only --probe-file /tmp/pr-ok.$$ --manifest "$HERE/fixtures/manifest.json" \
    > /tmp/pl-ok.$$ 2>/dev/null
python3 -c "import json;json.load(open('/tmp/pl-ok.$$'))" \
    && { echo "  PASS  plan-only emits valid JSON"; pass=$((pass+1)); } \
    || { echo "  FAIL  plan-only emits valid JSON"; fail=$((fail+1)); }
expect_contains "plan has a build list" /tmp/pl-ok.$$ '"build"'

# An incomplete probe must request everything, never skip.
printf 'state=fastboot\nprobe_complete=no\n' > /tmp/pr-part.$$
"$PROV" --plan-only --probe-file /tmp/pr-part.$$ --manifest "$HERE/fixtures/manifest.json" \
    > /tmp/pl-part.$$ 2>/dev/null
expect_contains "incomplete probe requests kernel" /tmp/pl-part.$$ 'kernel'
expect_contains "incomplete probe requests rootfs" /tmp/pl-part.$$ 'rootfs'

# A missing artifact is always requested.
printf '{"artifacts":{},"repo_commit":"x"}\n' > /tmp/m-empty.$$
"$PROV" --plan-only --probe-file /tmp/pr-ok.$$ --manifest /tmp/m-empty.$$ \
    > /tmp/pl-empty.$$ 2>/dev/null
expect_contains "an absent artifact is requested" /tmp/pl-empty.$$ 'kernel'

# THE ROUND TRIP: build.sh must accept what provision.sh emits.
: > "$ftlog"
env BUILD_GIT_CMD="$HERE/fixtures/fake-git" \
    "BUILD_TARGET_CMD_kernel=env FT_NAME=kernel FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "BUILD_TARGET_CMD_camera=env FT_NAME=camera FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "BUILD_TARGET_CMD_adaptation=env FT_NAME=adaptation FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "BUILD_TARGET_CMD_rootfs=env FT_NAME=rootfs FT_LOG=$ftlog $HERE/fixtures/fake-target" \
    "$BUILD" --plan /tmp/pl-part.$$ > /tmp/rt.$$ 2>&1
expect_rc "build.sh accepts a provision plan" 0 "$?"
expect_contains "the round trip actually builds" "$ftlog" 'kernel'
rm -f /tmp/pr-ok.$$ /tmp/pl-ok.$$ /tmp/pr-part.$$ /tmp/pl-part.$$ \
      /tmp/m-empty.$$ /tmp/pl-empty.$$ /tmp/rt.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: the new cases FAIL — `provision.sh` does not exist.

- [ ] **Step 3: Write provision.sh**

```bash
#!/usr/bin/env bash
#
# Probe the phone, decide what is needed, flash it, verify it.
#
#   ./provision.sh --plan-only > plan.json   # probe and decide; touch nothing
#   ./provision.sh --artifacts ./out         # flash using prebuilt artifacts
#   BUILD_HOST=taichi ./provision.sh         # build remotely, fetch, flash
#   PHASE=boot ./provision.sh                # run a single phase
#   VERIFY=1 ./provision.sh                  # full sha256 instead of cheap probes
#
# This never builds. It probes for real evidence and skips only what the device
# demonstrably already has. No state file is written or trusted: such a record
# lies the moment anything changes outside the pipeline, and this repo has been
# bricked once already by believing a claim over reality.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST:-$HERE/droidian/manifest.json}"
PROBE_FILE=""
MODE=full

die() { echo "provision.sh: $*" >&2; exit 1; }

# Decide from evidence, never from a marker.
decide_build() {
    local probe=$1 manifest=$2
    PROBE="$probe" MANIFEST="$manifest" python3 - <<'PY'
import json, os, sys

def load_probe(path):
    facts = {}
    with open(path) as fh:
        for line in fh:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                facts[k] = v
    return facts

facts = load_probe(os.environ["PROBE"])
try:
    man = json.load(open(os.environ["MANIFEST"]))
except Exception:
    man = {"artifacts": {}}

ALL = ["kernel", "camera", "adaptation", "rootfs"]
have = {a.get("target") for a in man.get("artifacts", {}).values()}

# An unreadable device is not evidence that anything can be skipped, so an
# incomplete probe asks for everything rather than guessing.
if facts.get("probe_complete") != "yes":
    print(" ".join(ALL)); raise SystemExit

print(" ".join(t for t in ALL if t not in have))
PY
}

emit_plan() {
    local targets=$1
    TARGETS="$targets" python3 - <<'PY'
import json, os
targets = os.environ["TARGETS"].split()
print(json.dumps({"build": targets, "force": False}, indent=2, sort_keys=True))
PY
}

while [ $# -gt 0 ]; do
    case "$1" in
        --plan-only)  MODE=plan; shift ;;
        --probe-file) shift; PROBE_FILE="${1:?--probe-file needs a path}"; shift ;;
        --manifest)   shift; MANIFEST="${1:?--manifest needs a path}"; shift ;;
        -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [ -z "$PROBE_FILE" ]; then
    PROBE_FILE=$(mktemp); trap 'rm -f "$PROBE_FILE"' EXIT
    "$HERE/lib/probe.sh" probe_all > "$PROBE_FILE" || die "probe failed"
fi

if [ "$MODE" = plan ]; then
    emit_plan "$(decide_build "$PROBE_FILE" "$MANIFEST")"
    exit 0
fi

die "flash phases are not implemented yet (Tasks 10-13); use --plan-only"
```

- [ ] **Step 4: Run to verify it passes**

```bash
chmod +x provision.sh
./tests/run-tests.sh
```

Expected: `passed=57 failed=0`.

- [ ] **Step 5: Commit**

```bash
git add provision.sh tests
git commit -m "feat(provision): probe, decide, and emit plan.json

Skipping is decided from device evidence, never from a stored marker. An
incomplete probe requests every target: an unreadable device is not evidence
that a destructive phase can be skipped. The build.sh round trip is tested."
```

---

### Task 9: `BUILD_HOST` — move the plan out, bring the artifacts back

**Files:**
- Modify: `provision.sh`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `emit_plan` (Task 8), `build.sh --plan` (Task 6).
- Produces: `remote_build <host> <plan-file>`, leaving artifacts and
  `manifest.json` under `$HERE/droidian/`. Tasks 10–13 read them from there.

**Transfer is by git bundle, not by pushing to a forge.** A bundle carries the
exact commits, needs no network service, no credentials and no public push, and
leaves the worker's git state honest rather than a pile of rsynced files. This
is the sequence already used by hand:

```bash
git bundle create /tmp/op6t.bundle main
scp /tmp/op6t.bundle HOST:/tmp/
ssh HOST 'cd ~/oneplus6t && git fetch -q /tmp/op6t.bundle main && git reset -q --hard FETCH_HEAD'
```

- [ ] **Step 1: Write the failing tests**

`remote_build` runs through a command seam so the test needs no second machine.

Append to `tests/run-tests.sh`:

```bash
rlog=$(mktemp)
cat > /tmp/fake-ssh.$$ <<FS
#!/usr/bin/env bash
echo "SSH \$*" >> $rlog
exit 0
FS
cat > /tmp/fake-scp.$$ <<FS
#!/usr/bin/env bash
echo "SCP \$*" >> $rlog
exit 0
FS
chmod +x /tmp/fake-ssh.$$ /tmp/fake-scp.$$

printf '{"build":["adaptation"],"force":false}\n' > /tmp/rp.$$
: > "$rlog"
PROV_SSH=/tmp/fake-ssh.$$ PROV_SCP=/tmp/fake-scp.$$ \
    "$PROV" --remote-build taichi --plan-file /tmp/rp.$$ > /tmp/rb.$$ 2>&1
rc=$?
expect_rc "remote build succeeds"            0 "$rc"
expect_contains "the bundle is copied over"  "$rlog" 'SCP'
expect_contains "the worker resets to it"    "$rlog" 'FETCH_HEAD'
expect_contains "build.sh runs with the plan" "$rlog" 'build.sh --plan'
expect_contains "artifacts are fetched back" "$rlog" 'manifest.json'

# A worker that fails must fail the run, not silently continue to flashing.
cat > /tmp/fake-ssh.$$ <<'FS'
#!/usr/bin/env bash
exit 3
FS
chmod +x /tmp/fake-ssh.$$
PROV_SSH=/tmp/fake-ssh.$$ PROV_SCP=/tmp/fake-scp.$$ \
    "$PROV" --remote-build taichi --plan-file /tmp/rp.$$ > /tmp/rb2.$$ 2>&1
expect_rc "a failing worker fails the run" 1 "$?"
rm -f "$rlog" /tmp/fake-ssh.$$ /tmp/fake-scp.$$ /tmp/rp.$$ /tmp/rb.$$ /tmp/rb2.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: the remote cases FAIL — the flag does not exist.

- [ ] **Step 3: Implement remote_build**

Add to `provision.sh` above the argument loop:

```bash
SSH_CMD="${PROV_SSH:-ssh}"
SCP_CMD="${PROV_SCP:-scp}"
REMOTE_DIR="${REMOTE_DIR:-oneplus6t}"

# Ship the exact commits by bundle: no forge, no credentials, no public push,
# and the worker keeps an honest git state instead of a pile of copied files.
remote_build() {
    local host=$1 plan=$2
    local bundle=/tmp/op6t-$$.bundle
    git -C "$HERE" bundle create "$bundle" main >/dev/null 2>&1 \
        || die "could not create a git bundle"

    "$SCP_CMD" -q "$bundle" "$host:/tmp/op6t.bundle" || die "could not copy the bundle to $host"
    "$SCP_CMD" -q "$plan"   "$host:/tmp/plan.json"   || die "could not copy the plan to $host"
    rm -f "$bundle"

    "$SSH_CMD" "$host" "cd $REMOTE_DIR && git fetch -q /tmp/op6t.bundle main && git reset -q --hard FETCH_HEAD" \
        || die "could not update $host to this commit"
    "$SSH_CMD" "$host" "cd $REMOTE_DIR && ./check-env.sh build" \
        || die "$host is missing build prerequisites"
    "$SSH_CMD" "$host" "cd $REMOTE_DIR && ./build.sh --plan /tmp/plan.json" \
        || die "the build failed on $host"

    # Bring back the manifest first: if it is absent the build produced nothing
    # trustworthy and flashing must not proceed.
    "$SCP_CMD" -q "$host:$REMOTE_DIR/droidian/manifest.json" "$HERE/droidian/manifest.json" \
        || die "no manifest.json came back from $host"
    for f in droidian/out/images/boot.img droidian/out/images/vbmeta.img droidian/userdata.img; do
        "$SCP_CMD" -q "$host:$REMOTE_DIR/$f" "$HERE/$f" 2>/dev/null || true
    done
}
```

Add to the argument loop:

```bash
        --remote-build) shift; REMOTE_HOST="${1:?--remote-build needs a host}"; MODE=remote; shift ;;
        --plan-file)    shift; PLAN_FILE="${1:?--plan-file needs a path}"; shift ;;
```

and before the final `die`:

```bash
if [ "$MODE" = remote ]; then
    [ -n "${PLAN_FILE:-}" ] || {
        PLAN_FILE=$(mktemp)
        emit_plan "$(decide_build "$PROBE_FILE" "$MANIFEST")" > "$PLAN_FILE"
    }
    remote_build "$REMOTE_HOST" "$PLAN_FILE"
    echo "provision.sh: artifacts and manifest fetched from $REMOTE_HOST"
    exit 0
fi
```

- [ ] **Step 4: Run to verify it passes**

```bash
./tests/run-tests.sh
```

Expected: `passed=64 failed=0`.

- [ ] **Step 5: Run it against the real worker**

```bash
./provision.sh --plan-only > /tmp/plan.json
cat /tmp/plan.json
./provision.sh --remote-build taichi --plan-file /tmp/plan.json
python3 -m json.tool droidian/manifest.json | head -20
```

Expected: taichi updates to this commit, builds only what the plan asked for,
and `manifest.json` arrives locally. This is the first time the two halves run
together on real machines.

- [ ] **Step 6: Commit**

```bash
git add provision.sh tests/run-tests.sh
git commit -m "feat(provision): drive the worker over a git bundle

A bundle carries exact commits with no forge, no credentials and no public
push, and leaves the worker's git state honest. The manifest is fetched first:
without it the build produced nothing trustworthy and flashing must not start."
```

---

### Task 10: `lib/phases.sh` — the runner, dry by default

**Files:**
- Create: `lib/phases.sh`
- Modify: `provision.sh`, `tests/run-tests.sh`

**Interfaces:**
- Consumes: probe keys (Task 7), `manifest.json` (Task 4).
- Produces: `phase_order`, `phase_should_skip <phase> <probe-file> <manifest>`,
  and `run_phases <probe-file> <manifest>`. Tasks 11–13 fill in the bodies;
  this task builds the runner and the skip logic with **every phase a no-op**.

**Why the runner lands before any phase body.** Skip logic is where a
destructive step gets wrongly skipped, and it is fully testable with no phone.
Getting it right first means the dangerous code arrives into a harness that
already refuses to run it under the wrong conditions.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-tests.sh`:

```bash
PH="$ROOT/lib/phases.sh"
mkprobe() { printf '%s\n' "$@" > /tmp/ph-probe.$$; }

# Everything already correct -> the destructive phases skip.
mkprobe 'probe_complete=yes' 'oos_version=9.0.17' 'has_linuxroot=yes' \
        'boot_sha=aaaa' 'slot=b' 'pkg_adaptation-oneplus-fajita=1.0.0'
bash "$PH" phase_should_skip edl /tmp/ph-probe.$$ "$HERE/fixtures/manifest.json" \
    && { echo "  PASS  edl skips when OOS9 and linuxroot are present"; pass=$((pass+1)); } \
    || { echo "  FAIL  edl skips when OOS9 and linuxroot are present"; fail=$((fail+1)); }

# Wrong Android -> edl must run.
mkprobe 'probe_complete=yes' 'oos_version=11.1.2.2' 'has_linuxroot=yes'
bash "$PH" phase_should_skip edl /tmp/ph-probe.$$ "$HERE/fixtures/manifest.json" \
    && { echo "  FAIL  edl skipped on the wrong Android"; fail=$((fail+1)); } \
    || { echo "  PASS  edl runs on the wrong Android"; pass=$((pass+1)); }

# No linuxroot -> edl must run even though the Android is right.
mkprobe 'probe_complete=yes' 'oos_version=9.0.17' 'has_linuxroot=no'
bash "$PH" phase_should_skip edl /tmp/ph-probe.$$ "$HERE/fixtures/manifest.json" \
    && { echo "  FAIL  edl skipped with no linuxroot"; fail=$((fail+1)); } \
    || { echo "  PASS  edl runs with no linuxroot"; pass=$((pass+1)); }

# THE IMPORTANT ONE: an incomplete probe must never permit a skip.
mkprobe 'probe_complete=no' 'oos_version=9.0.17' 'has_linuxroot=yes' 'boot_sha=aaaa'
for p in edl boot data activate; do
    if bash "$PH" phase_should_skip "$p" /tmp/ph-probe.$$ "$HERE/fixtures/manifest.json"; then
        echo "  FAIL  $p skipped on an incomplete probe"; fail=$((fail+1))
    else
        echo "  PASS  $p runs on an incomplete probe"; pass=$((pass+1))
    fi
done

# verify is never skipped, whatever the evidence says.
mkprobe 'probe_complete=yes' 'oos_version=9.0.17' 'has_linuxroot=yes' 'boot_sha=aaaa' 'slot=b'
bash "$PH" phase_should_skip verify /tmp/ph-probe.$$ "$HERE/fixtures/manifest.json" \
    && { echo "  FAIL  verify was skipped"; fail=$((fail+1)); } \
    || { echo "  PASS  verify is never skipped"; pass=$((pass+1)); }

# boot skips only when the flashed sha matches the manifest.
mkprobe 'probe_complete=yes' 'boot_sha=aaaa' 'slot=b' 'oos_version=9.0.17' 'has_linuxroot=yes'
bash "$PH" phase_should_skip boot /tmp/ph-probe.$$ "$HERE/fixtures/manifest.json" \
    && { echo "  PASS  boot skips on a matching sha"; pass=$((pass+1)); } \
    || { echo "  FAIL  boot skips on a matching sha"; fail=$((fail+1)); }
mkprobe 'probe_complete=yes' 'boot_sha=zzzz' 'slot=b' 'oos_version=9.0.17' 'has_linuxroot=yes'
bash "$PH" phase_should_skip boot /tmp/ph-probe.$$ "$HERE/fixtures/manifest.json" \
    && { echo "  FAIL  boot skipped on a mismatched sha"; fail=$((fail+1)); } \
    || { echo "  PASS  boot runs on a mismatched sha"; pass=$((pass+1)); }
rm -f /tmp/ph-probe.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: the phase cases FAIL — `lib/phases.sh` does not exist.

- [ ] **Step 3: Write lib/phases.sh with empty phase bodies**

```bash
#!/usr/bin/env bash
# The five flash phases and, more importantly, when NOT to run them.
#
# Every skip is decided from probed evidence. The dangerous direction is
# skipping a destructive phase that was actually needed, so the rule is:
# skip only on positive, complete evidence. probe_complete=no means run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

phase_order() { echo "edl boot data activate verify"; }

fact() {   # fact <probe-file> <key>
    sed -n "s/^$2=//p" "$1" | head -1
}

manifest_sha() {   # manifest_sha <manifest> <path>
    MAN="$1" P="$2" python3 - <<'PY'
import json, os
try:
    doc = json.load(open(os.environ["MAN"]))
except Exception:
    print(""); raise SystemExit
print(doc.get("artifacts", {}).get(os.environ["P"], {}).get("sha256", ""))
PY
}

# Returns 0 (true) when the phase may be skipped.
phase_should_skip() {
    local phase=$1 probe=$2 manifest=$3

    # verify asserts the user-visible outcome and is the whole point; it runs
    # even when everything else was skipped.
    [ "$phase" = verify ] && return 1

    # Evidence we could not read is not evidence that the work is done.
    [ "$(fact "$probe" probe_complete)" = yes ] || return 1

    case "$phase" in
        edl)
            [ "$(fact "$probe" oos_version)"   = "9.0.17" ] || return 1
            [ "$(fact "$probe" has_linuxroot)" = "yes" ]    || return 1
            return 0 ;;
        boot)
            local want; want=$(manifest_sha "$manifest" droidian/out/images/boot.img)
            [ -n "$want" ] || return 1
            [ "$(fact "$probe" boot_sha)" = "$want" ] || return 1
            return 0 ;;
        data)
            # Skipped only when the rootfs already carries the manifest's
            # package versions. Task 12 tightens this to a per-package check.
            [ "$(fact "$probe" pkg_adaptation-oneplus-fajita)" != "" ] || return 1
            return 0 ;;
        activate)
            [ "$(fact "$probe" slot)" = "${DROIDIAN_SLOT:-b}" ] || return 1
            return 0 ;;
    esac
    return 1
}

# Phase bodies land in Tasks 11-13. Until then every one is a no-op, so the
# runner and its skip logic can be exercised with no risk.
phase_edl()      { echo "phase edl: not implemented"; }
phase_boot()     { echo "phase boot: not implemented"; }
phase_data()     { echo "phase data: not implemented"; }
phase_activate() { echo "phase activate: not implemented"; }
phase_verify()   { "$HERE/droidian/verify-device.sh"; }

run_phases() {
    local probe=$1 manifest=$2 only="${PHASE:-}"
    local p
    for p in $(phase_order); do
        [ -n "$only" ] && [ "$only" != "$p" ] && continue
        if phase_should_skip "$p" "$probe" "$manifest"; then
            printf '    %-9s skip\n' "$p"
        else
            printf '\n>>> phase %s\n' "$p"
            "phase_$p" || return 1
        fi
    done
}

"${@:-run_phases}"
```

- [ ] **Step 4: Run to verify it passes**

```bash
chmod +x lib/phases.sh
./tests/run-tests.sh
```

Expected: `passed=74 failed=0`.

- [ ] **Step 5: Commit**

```bash
git add lib/phases.sh tests/run-tests.sh
git commit -m "feat(provision): phase runner and skip logic, with empty phases

Skip logic lands before any phase body, because wrongly skipping a destructive
phase is the dangerous failure and it is fully testable with no phone. Skips
require positive complete evidence; an incomplete probe runs everything, and
verify is never skipped."
```

---

### Task 11: The non-destructive phases — `boot`, `activate`, `verify`

**Files:**
- Modify: `lib/phases.sh`, `provision.sh`, `tests/run-tests.sh`

**Interfaces:**
- Consumes: `device.sh goto`, `droidian/flash.sh`, `droidian/verify-device.sh`.
- Produces: working `phase_boot`, `phase_activate`, `phase_verify`. Task 12
  adds `data`; Task 13 adds `edl`.

These write only to `boot_<slot>`, `vbmeta_<slot>` and the slot flag. None of
them touches the partition table or user data, so they are safe to exercise on
the phone before the destructive work exists.

- [ ] **Step 1: Write the failing tests**

Append to `tests/run-tests.sh`:

```bash
flog=$(mktemp)
cat > /tmp/fake-fastboot.$$ <<FS
#!/usr/bin/env bash
echo "fastboot \$*" >> $flog
exit 0
FS
chmod +x /tmp/fake-fastboot.$$

: > "$flog"
PH_FASTBOOT=/tmp/fake-fastboot.$$ PH_SLOT=b \
    bash "$PH" phase_boot > /tmp/ph-boot.$$ 2>&1
expect_contains "boot flashes the boot partition"   "$flog" 'flash boot_b'
expect_contains "boot flashes vbmeta"               "$flog" 'flash vbmeta_b'
expect_absent  "boot never erases dtbo"             "$flog" 'erase dtbo'
expect_absent  "boot never wipes"                   "$flog" '-w'
expect_absent  "boot never touches userdata"        "$flog" 'flash userdata'

: > "$flog"
PH_FASTBOOT=/tmp/fake-fastboot.$$ PH_SLOT=b \
    bash "$PH" phase_activate > /tmp/ph-act.$$ 2>&1
expect_contains "activate sets the slot" "$flog" 'set_active b'
rm -f "$flog" /tmp/fake-fastboot.$$ /tmp/ph-boot.$$ /tmp/ph-act.$$
```

`erase dtbo` and `-w` are asserted absent deliberately: `flash-pmos.sh` erases
`dtbo` and that would break Droidian, which reuses OxygenOS 9's; and
`fastboot -w` bootloops this device.

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: the new cases FAIL — the phases are still no-ops.

- [ ] **Step 3: Implement the three phases**

Replace the stubs in `lib/phases.sh`:

```bash
FASTBOOT="${PH_FASTBOOT:-fastboot}"
SLOT="${PH_SLOT:-${DROIDIAN_SLOT:-b}}"

# Droidian reuses the dtbo already on the device -- OxygenOS 9's, which already
# carries the fajita overlays. kernel-info.mk sets KERNEL_IMAGE_WITH_DTB_OVERLAY=0
# and the flash config says DEVICE_HAS_DTBO_PARTITION=no. Never erase dtbo here:
# flash-pmos.sh does, because mainline needs its own, and doing it for Droidian
# breaks the boot.
phase_boot() {
    local boot="$HERE/droidian/out/images/boot.img"
    local vbmeta="$HERE/droidian/out/images/vbmeta.img"
    [ -f "$boot" ]   || { echo "phase boot: missing $boot" >&2; return 1; }
    [ -f "$vbmeta" ] || { echo "phase boot: missing $vbmeta" >&2; return 1; }
    "$HERE/device.sh" goto fastboot || return 1
    "$FASTBOOT" flash "boot_$SLOT"   "$boot"   || return 1
    "$FASTBOOT" flash "vbmeta_$SLOT" "$vbmeta" || return 1
}

# A custom boot image will not verify against stock vbmeta, so verification is
# disabled on the slot we own. Only that slot.
phase_activate() {
    "$HERE/device.sh" goto fastboot || return 1
    "$FASTBOOT" set_active "$SLOT" || return 1
}

phase_verify() {
    "$HERE/device.sh" goto droidian || return 1
    "$HERE/droidian/verify-device.sh"
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
./tests/run-tests.sh
```

Expected: `passed=81 failed=0`.

- [ ] **Step 5: Run the non-destructive phases on the real phone**

This settles the outstanding divergence: the device is running a `boot.img`
built from a DT patch that was later reverted.

```bash
./provision.sh --remote-build taichi          # rebuilds kernel; source moved
PHASE=boot ./provision.sh --artifacts droidian
PHASE=verify ./provision.sh --artifacts droidian
```

Expected: `boot` flashes, `verify` reports `ALL PASS`. Confirm the flashed image
now matches the manifest:

```bash
python3 -c "import json;print(json.load(open('droidian/manifest.json'))['artifacts']['droidian/out/images/boot.img']['sha256'])"
sha256sum droidian/out/images/boot.img
```

- [ ] **Step 6: Commit**

```bash
git add lib/phases.sh tests/run-tests.sh
git commit -m "feat(provision): boot, activate and verify phases

These touch only boot, vbmeta and the slot flag -- no partition table, no user
data -- so they are safe to run before the destructive phases exist. Tests
assert dtbo is never erased and -w is never passed: the first breaks Droidian,
the second bootloops this device."
```

---

### Task 12: The `data` phase

**Files:**
- Modify: `lib/phases.sh`, `tests/run-tests.sh`

**Interfaces:**
- Consumes: `droidian/userdata.img`, manifest package versions.
- Produces: `phase_data`, and a tightened `data` skip predicate comparing every
  `pkg_*` probe fact against the manifest rather than checking one name.

**Destructive:** writes `userdata`. Everything on the Droidian side is lost;
that is the intent, since `userdata.img` carries the whole rootfs.

- [ ] **Step 1: Write the failing tests**

```bash
# data skips only when EVERY manifest package matches the device.
cat > /tmp/m-pkgs.$$ <<'MJ'
{"repo_commit":"x","artifacts":{
 "droidian/out-adaptation/halium-hostdev-perms_1.0.0_all.deb":
   {"target":"adaptation","version":"1.0.0","sha256":"a","bytes":1,
    "repo_commit":"x","source_commit":"x"},
 "droidian/out-adaptation/adaptation-oneplus-fajita_1.0.0_all.deb":
   {"target":"adaptation","version":"1.0.0","sha256":"b","bytes":1,
    "repo_commit":"x","source_commit":"x"}}}
MJ
mkprobe 'probe_complete=yes' 'pkg_halium-hostdev-perms=1.0.0' \
        'pkg_adaptation-oneplus-fajita=1.0.0'
bash "$PH" phase_should_skip data /tmp/ph-probe.$$ /tmp/m-pkgs.$$ \
    && { echo "  PASS  data skips when every package matches"; pass=$((pass+1)); } \
    || { echo "  FAIL  data skips when every package matches"; fail=$((fail+1)); }

mkprobe 'probe_complete=yes' 'pkg_halium-hostdev-perms=1.0.0' \
        'pkg_adaptation-oneplus-fajita=0.9.0'
bash "$PH" phase_should_skip data /tmp/ph-probe.$$ /tmp/m-pkgs.$$ \
    && { echo "  FAIL  data skipped on an older package"; fail=$((fail+1)); } \
    || { echo "  PASS  data runs on an older package"; pass=$((pass+1)); }

mkprobe 'probe_complete=yes' 'pkg_halium-hostdev-perms=1.0.0'
bash "$PH" phase_should_skip data /tmp/ph-probe.$$ /tmp/m-pkgs.$$ \
    && { echo "  FAIL  data skipped with a package absent"; fail=$((fail+1)); } \
    || { echo "  PASS  data runs with a package absent"; pass=$((pass+1)); }

: > "$flog"
PH_FASTBOOT=/tmp/fake-fastboot.$$ bash "$PH" phase_data > /tmp/ph-data.$$ 2>&1
expect_contains "data flashes userdata" "$flog" 'flash userdata'
expect_absent  "data never passes -w"   "$flog" '-w'
rm -f /tmp/m-pkgs.$$ /tmp/ph-data.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: the version-comparison cases FAIL — the predicate checks one name.

- [ ] **Step 3: Tighten the predicate and implement the phase**

Replace the `data)` branch in `phase_should_skip`:

```bash
        data)
            # Every package the manifest builds must be present on the device at
            # the same version. Checking one name would let a stale rootfs pass.
            local mismatch
            mismatch=$(MAN="$manifest" PROBE="$probe" python3 - <<'PY'
import json, os
facts = {}
for line in open(os.environ["PROBE"]):
    if "=" in line:
        k, v = line.rstrip("\n").split("=", 1)
        facts[k] = v
try:
    doc = json.load(open(os.environ["MAN"]))
except Exception:
    print("no manifest"); raise SystemExit
for path, a in doc.get("artifacts", {}).items():
    if not path.endswith(".deb"):
        continue
    name = os.path.basename(path).split("_")[0]
    if facts.get(f"pkg_{name}") != a.get("version"):
        print(f"{name}: device={facts.get(f'pkg_{name}')} manifest={a.get('version')}")
        raise SystemExit
print("")
PY
)
            [ -z "$mismatch" ] || return 1
            return 0 ;;
```

and replace the `phase_data` stub:

```bash
# Writes userdata. Everything on the Droidian side goes; that is the intent,
# since userdata.img carries the entire rootfs.
#
# fastboot format/-w is never used here: this bootloader answers f2fs while
# vendor fstab requires ext4 for /data, so -w bootloops the device.
phase_data() {
    local img="$HERE/droidian/userdata.img"
    [ -f "$img" ] || { echo "phase data: missing $img" >&2; return 1; }
    "$HERE/device.sh" goto fastboot || return 1
    "$FASTBOOT" flash userdata "$img"
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
./tests/run-tests.sh
```

Expected: `passed=86 failed=0`.

- [ ] **Step 5: Run it on the phone**

```bash
PHASE=data ./provision.sh --artifacts droidian
PHASE=verify ./provision.sh --artifacts droidian
```

Expected: `ALL PASS`, on a first boot, with no manual step.

- [ ] **Step 6: Commit**

```bash
git add lib/phases.sh tests/run-tests.sh
git commit -m "feat(provision): data phase, skipping on full package agreement

The skip compares every package in the manifest against the device. Checking a
single name would let a rootfs missing one fix look current."
```

---

### Task 13: The `edl` phase — the dangerous one

**Files:**
- Modify: `lib/phases.sh`, `tests/run-tests.sh`, `README.md`

**Interfaces:**
- Consumes: `restore-android.py` with `RELEASE=oos9 LAYOUT=dualboot`.
- Produces: `phase_edl`, gated behind an explicit acknowledgement.

**This is the highest-risk step in the project.** It rewrites the LUN0 partition
table. `LAYOUT=dualboot` is code-complete with a passing selftest but **has
never touched hardware**. A half-written GPT costs a full EDL recovery cycle,
and this repo exists because `edl qfil` destroyed that table once already.

**Gate.** `phase_edl` refuses to run unless `I_UNDERSTAND_THIS_REWRITES_THE_GPT=1`.
Not to protect data — there is none worth keeping — but so the step is never
reached by accident through a wrong skip predicate.

- [ ] **Step 1: Write the failing tests**

```bash
rlog2=$(mktemp)
cat > /tmp/fake-restore.$$ <<FS
#!/usr/bin/env bash
echo "restore \$* LAYOUT=\$LAYOUT RELEASE=\$RELEASE" >> $rlog2
exit 0
FS
chmod +x /tmp/fake-restore.$$

# Without the acknowledgement it must refuse and run nothing.
: > "$rlog2"
PH_RESTORE=/tmp/fake-restore.$$ bash "$PH" phase_edl > /tmp/ph-edl.$$ 2>&1
expect_rc "edl refuses without acknowledgement" 1 "$?"
expect_contains "the refusal explains itself" /tmp/ph-edl.$$ 'I_UNDERSTAND_THIS_REWRITES_THE_GPT'
if [ -s "$rlog2" ]; then
    echo "  FAIL  edl ran something despite refusing"; fail=$((fail+1))
else
    echo "  PASS  edl ran nothing when refused"; pass=$((pass+1))
fi

# With it, the right release and layout are requested.
: > "$rlog2"
I_UNDERSTAND_THIS_REWRITES_THE_GPT=1 PH_RESTORE=/tmp/fake-restore.$$ \
    bash "$PH" phase_edl > /tmp/ph-edl2.$$ 2>&1
expect_contains "edl asks for the dualboot layout" "$rlog2" 'LAYOUT=dualboot'
expect_contains "edl asks for OxygenOS 9"          "$rlog2" 'RELEASE=oos9'
expect_absent  "edl never calls qfil"              "$rlog2" 'qfil'
rm -f "$rlog2" /tmp/fake-restore.$$ /tmp/ph-edl.$$ /tmp/ph-edl2.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./tests/run-tests.sh
```

Expected: FAIL — `phase_edl` is still a stub.

- [ ] **Step 3: Implement phase_edl**

```bash
# THE HIGHEST-RISK STEP IN THIS PROJECT. It rewrites the LUN0 partition table.
#
# LAYOUT=dualboot has a passing offline selftest but has never run on hardware.
# A half-written GPT costs a full EDL recovery cycle. This repo exists because
# edl qfil wrote a backup GPT over the primary one and bricked the device; the
# restore path here never calls qfil.
#
# Gated so it can never be reached by accident through a wrong skip predicate.
phase_edl() {
    if [ "${I_UNDERSTAND_THIS_REWRITES_THE_GPT:-0}" != 1 ]; then
        cat >&2 <<'MSG'
phase edl: refusing to rewrite the partition table.

This repartitions LUN0 and wipes /data. LAYOUT=dualboot has never run on
hardware. Re-run with:

    I_UNDERSTAND_THIS_REWRITES_THE_GPT=1 PHASE=edl ./provision.sh
MSG
        return 1
    fi
    "$HERE/device.sh" goto edl || return 1
    env RELEASE=oos9 LAYOUT=dualboot \
        "${PH_RESTORE:-$HERE/.venv/bin/python $HERE/restore-android.py}"
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
./tests/run-tests.sh
```

Expected: `passed=91 failed=0`.

- [ ] **Step 5: Dry-run against real hardware, writing nothing**

`restore-android.py` already has the two safe modes. Use them before any write:

```bash
SELFTEST=1 .venv/bin/python restore-android.py          # offline GPT checks
./device.sh goto edl
DRY=1 LAYOUT=dualboot RELEASE=oos9 .venv/bin/python restore-android.py
```

Expected: the selftest asserts the dualboot table is consistent —
`linuxroot` present, no gap or overlap with `userdata`, both CRCs correct — and
`DRY=1` resolves and size-checks all 46 partitions without writing. **Do not
proceed if either reports anything unexpected.**

- [ ] **Step 6: The real run**

```bash
I_UNDERSTAND_THIS_REWRITES_THE_GPT=1 PHASE=edl ./provision.sh
```

Then confirm the table before going further:

```bash
./device.sh goto fastboot
fastboot getvar all 2>&1 | grep -iE "partition-size:(userdata|linuxroot|system_a)"
```

Expected: `linuxroot` exists, `userdata` is about half its previous size, and
`system_a` is still present. If `system_a` is missing the LUN0 table is damaged
and the recovery path is `RELEASE=oos11 restore-android.py` from EDL.

- [ ] **Step 7: Commit**

```bash
git add lib/phases.sh tests/run-tests.sh
git commit -m "feat(provision): edl phase, gated behind an explicit acknowledgement

Rewrites the LUN0 partition table, and LAYOUT=dualboot had never run on
hardware. The gate is not about protecting data -- there is none worth keeping
-- but about never reaching this step through a wrong skip predicate."
```

---

### Task 14: One command, end to end

**Files:**
- Modify: `provision.sh`, `README.md`
- Modify: `tests/run-tests.sh`

**Interfaces:**
- Consumes: everything above.
- Produces: the default `provision.sh` path — probe, build remotely if
  `BUILD_HOST` is set, run every phase, verify.

- [ ] **Step 1: Wire the phases into provision.sh**

Replace the trailing `die "flash phases are not implemented yet..."` with:

```bash
if [ -n "${BUILD_HOST:-}" ]; then
    PLAN_FILE=$(mktemp)
    emit_plan "$(decide_build "$PROBE_FILE" "$MANIFEST")" > "$PLAN_FILE"
    remote_build "$BUILD_HOST" "$PLAN_FILE"
    # The device may have moved while the worker built; probe again rather than
    # deciding from stale evidence.
    "$HERE/lib/probe.sh" probe_all > "$PROBE_FILE" || die "re-probe failed"
fi

[ -f "$MANIFEST" ] || die "no manifest at $MANIFEST -- run build.sh, or set BUILD_HOST"
"$HERE/lib/phases.sh" run_phases "$PROBE_FILE" "$MANIFEST"
```

- [ ] **Step 2: Test that a missing manifest stops before any phase**

```bash
printf 'state=droidian\nprobe_complete=yes\n' > /tmp/pr-nm.$$
MANIFEST=/tmp/does-not-exist.json "$PROV" --probe-file /tmp/pr-nm.$$ > /tmp/nm.$$ 2>&1
expect_rc "a missing manifest stops the run" 1 "$?"
expect_contains "and says why" /tmp/nm.$$ 'no manifest'
rm -f /tmp/pr-nm.$$ /tmp/nm.$$
```

Expected after implementing: `passed=93 failed=0`.

- [ ] **Step 3: The acceptance run**

From a booted Droidian, with everything already correct, this must do almost
nothing — that is the proof skip detection works:

```bash
BUILD_HOST=taichi ./provision.sh
```

Expected: every phase reports `skip` except `verify`, which reports `ALL PASS`.

Then prove it repairs a real regression:

```bash
.venv/bin/python droidian/ssh.py -r 'rm -f /run/udev/rules.d/70-halium-hostdev-perms.rules; systemctl stop halium-hostdev-perms'
PHASE=verify ./provision.sh          # must FAIL
BUILD_HOST=taichi ./provision.sh     # must repair
```

- [ ] **Step 4: Document it**

Update the pipeline table in `README.md` so `build.sh` and `provision.sh` read
**works**, and remove the note saying they are not written yet.

- [ ] **Step 5: Commit**

```bash
git add provision.sh tests/run-tests.sh README.md
git commit -m "feat(provision): one command from any USB-reachable state

Probes, builds on the worker when BUILD_HOST is set, re-probes because the
device may have moved while the worker built, then runs each phase only when
the device does not already demonstrably have its outcome."
```

---

## Done when

- `./tests/run-tests.sh` passes offline: no phone, no worker, no real builds.
- `./build.sh --list` documents every target, dependency and output.
- `./build.sh rootfs` builds `camera` and `adaptation` first, unprompted.
- A second `./build.sh` reports everything up to date; moving `HEAD` or dirtying
  a tree makes the affected target rebuild, and says why.
- `./provision.sh --plan-only` emits a `plan.json` that `./build.sh --plan`
  accepts, tested as a round trip.
- `BUILD_HOST=taichi ./provision.sh` builds on the worker and flashes here.
- On an already-correct device every phase reports `skip` except `verify`,
  which reports `ALL PASS`.
- After `LAYOUT=dualboot`, `fastboot set_active a` boots OxygenOS 9 and
  `set_active b` boots Droidian.

## Ordering, and why it is not negotiable

Tasks 1–10 write nothing to the phone. Task 11 writes only `boot`, `vbmeta` and
the slot flag. Task 12 writes `userdata`. Task 13 rewrites the partition table.
The skip logic that protects the destructive phases is built and tested in Task
10, before either of them exists. Do not reorder.
