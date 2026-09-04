# Adaptation Packages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package the three runtime-only fixes (display, polkit, camera) as
`.deb`s installed into `rootfs.img` at build time, so they survive a reinstall.

**Architecture:** One source tree per binary package under
`droidian/adaptation/`, each a plain directory tree assembled by
`dpkg-deb --build`. No compiled code, so all three are `Architecture: all`.
No maintainer scripts, so `dpkg --root` can install them into a foreign-arch
rootfs with no qemu. All effects are applied by idempotent boot-time systemd
oneshots.

**Tech Stack:** bash, systemd units, udev rules, `dpkg-deb`, podman running
`quay.io/droidian/build-essential:current-amd64`, `fuse2fs` for the rootfs
install seam.

## Global Constraints

- **Every fix must be a build artifact.** No fix may require a manual step on
  the running device. Verified by the hardware task at the end.
- **No maintainer scripts.** No `preinst`/`postinst`/`prerm`/`postrm` in any
  package. `dpkg --root` must execute no target binaries.
- **`Architecture: all`** for all three packages.
- **Never widen a node the session user can already reach.** Doing so would
  revert `/dev/input/event*` and `/dev/dri/card0` to Android's values and break
  working touch and display.
- **udev rules must not carry trailing inline comments.** udev silently
  discards such a rule and `udevadm control --reload-rules` reports nothing.
  Provenance comments go on their own line.
- **Deny by default:** `/dev/diag`, `/dev/ramdump_*`, `/dev/subsys_*`.
- Package names exactly: `halium-hostdev-perms`, `halium-oldkernel-compat`,
  `adaptation-oneplus-fajita`.
- Device naming is always `fajita`, never `oneplus6` or "OnePlus 6/6T".

---

## File Structure

```
droidian/adaptation/
  build-adaptation.sh                 builds all three .debs into out-adaptation/
  tests/
    run-tests.sh                      offline test runner, no device, no root
    fixtures/
      ueventd.rc                      trimmed real ueventd.rc from the device
      vendor-ueventd.rc               trimmed real vendor ueventd.rc
      reachable.txt                   nodes the fake probe reports reachable
      expected-rules.txt              golden output
  halium-hostdev-perms/
    DEBIAN/control
    usr/lib/halium-hostdev-perms/generate-rules       the whole algorithm, stdout
    usr/lib/halium-hostdev-perms/apply                unit wrapper: install + trigger
    usr/lib/halium-hostdev-perms/policy.d/10-defaults.conf
    usr/lib/systemd/system/halium-hostdev-perms.service
    etc/systemd/system/multi-user.target.wants/halium-hostdev-perms.service -> ...
  halium-oldkernel-compat/
    DEBIAN/control
    usr/lib/halium-oldkernel-compat/apply
    usr/lib/systemd/system/halium-oldkernel-compat.service
    etc/systemd/system/multi-user.target.wants/halium-oldkernel-compat.service -> ...
    etc/systemd/system/polkit-agent-helper.socket -> /dev/null
  adaptation-oneplus-fajita/
    DEBIAN/control
    usr/lib/adaptation-oneplus-fajita/apply
    usr/lib/systemd/system/adaptation-oneplus-fajita.service
    etc/systemd/system/multi-user.target.wants/adaptation-oneplus-fajita.service -> ...
    usr/lib/halium-hostdev-perms/policy.d/50-fajita.conf
```

`generate-rules` holds the entire algorithm and writes to stdout, so it is
testable offline with fixtures. The systemd unit is a thin wrapper that
redirects it to a file and reloads udev. Splitting it that way is what makes
Tasks 2–4 testable without a device or root.

---

### Task 1: Test harness and fixtures

**Files:**
- Create: `droidian/adaptation/tests/fixtures/ueventd.rc`
- Create: `droidian/adaptation/tests/fixtures/vendor-ueventd.rc`
- Create: `droidian/adaptation/tests/fixtures/reachable.txt`
- Create: `droidian/adaptation/tests/run-tests.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `run-tests.sh`, which every later task extends. Fixture paths are
  passed to `generate-rules` via `HHP_UEVENTD_FILES`, `HHP_POLICY_DIRS` and
  `HHP_REACH_CMD`.

- [x] **Step 1: Create the ueventd fixtures**

These are lines copied **verbatim** from the device, including their original
file and their original whitespace, chosen to cover every case: nodes that are
unreachable and must be fixed, nodes already reachable that must be left alone,
nodes matching the deny defaults, a node declared twice in both files, and
**glob declarations**.

The globs are not optional detail. On this device 33 of 264 `/dev` declarations
are globs, and they include `/dev/input/*` and `/dev/dri/*` — the two the
reachability invariant exists to protect. A fixture that flattened them to
literal paths would leave the glob path, which is what actually runs on
hardware, completely untested.

`droidian/adaptation/tests/fixtures/ueventd.rc` (from `/android/ueventd.rc`):

```
/dev/binder               0666   root       root
/dev/hwbinder             0666   root       root
/dev/vndbinder            0666   root       root
/dev/dri/*                0666   root       graphics
/dev/diag                 0660   radio      radio
/dev/input/*              0660   root       input
```

`droidian/adaptation/tests/fixtures/vendor-ueventd.rc` (from
`/android/vendor/ueventd.rc` — note the irregular spacing, which is real):

```
/dev/diag                 0660   system     oem_2901
/dev/kgsl-3d0             0666   system     system
/dev/ion                  0664   system     system
/dev/qseecom              0660   system     drmrpc
/dev/subsys_*         0640   system     system
/dev/ramdump*             0640   system     system
/dev/kmsg                                               0620   root       system
```

`/dev/diag` appears in **both** files with different owners. The vendor file is
read first, so the vendor declaration must win and only one rule may be emitted.

- [x] **Step 2: Create the existence and reachability fixtures**

Glob expansion must not touch the test host's `/dev`. This host has 30
`/dev/input/*` entries and 6 `/dev/dri/*`; the device has different ones. A test
whose output depends on the machine running it proves nothing, so expansion
goes through a seam (`HHP_EXPAND_CMD`) backed by a fixture.

`droidian/adaptation/tests/fixtures/existing.txt` — the nodes that exist on the
device, i.e. what the globs expand to:

```
/dev/binder
/dev/hwbinder
/dev/vndbinder
/dev/dri/card0
/dev/dri/renderD128
/dev/diag
/dev/input/event0
/dev/input/event1
/dev/kgsl-3d0
/dev/ion
/dev/qseecom
/dev/subsys_modem
/dev/ramdump_modem
/dev/kmsg
```

`droidian/adaptation/tests/fixtures/reachable.txt` — nodes the fake probe treats
as already reachable by the session user. This encodes the real device's state:
touch and display work because udev already made them reachable through
Debian-style groups.

```
/dev/binder
/dev/input/event0
/dev/input/event1
/dev/dri/card0
```

`/dev/dri/renderD128` is deliberately **absent** from this list. It is the only
fixture node that is both declared under a subdirectory and unreachable, so it
is what forces a rule to be emitted for a subdirectory node — which is how the
`KERNEL=` sysname handling gets tested at all.

- [x] **Step 3: Write the test runner**

`droidian/adaptation/tests/run-tests.sh`:

```bash
#!/usr/bin/env bash
# Offline tests for the adaptation packages. No device, no root, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPT="$(dirname "$HERE")"
FIX="$HERE/fixtures"
pass=0; fail=0

check() {   # check <name> <expected-file> <actual-file>
    if diff -u "$2" "$3" > /tmp/hhp-diff.$$ 2>&1; then
        echo "  PASS  $1"; pass=$((pass+1))
    else
        echo "  FAIL  $1"; sed 's/^/        /' /tmp/hhp-diff.$$; fail=$((fail+1))
    fi
    rm -f /tmp/hhp-diff.$$
}

expect_contains() {   # expect_contains <name> <file> <string>
    if grep -qF -- "$3" "$2"; then
        echo "  PASS  $1"; pass=$((pass+1))
    else
        echo "  FAIL  $1: expected to find: $3"; fail=$((fail+1))
    fi
}

expect_absent() {   # expect_absent <name> <file> <string>
    if grep -qF -- "$3" "$2"; then
        echo "  FAIL  $1: should not contain: $3"; fail=$((fail+1))
    else
        echo "  PASS  $1"; pass=$((pass+1))
    fi
}

# A fake reachability probe: exits 0 when the node is listed in the fixture.
# $1 is quoted in every *_CMD because the generator substitutes it textually,
# and an unquoted /dev/input/* would be glob-expanded by eval against THIS host.
export HHP_REACH_CMD="grep -qxF \"\$1\" $FIX/reachable.txt"
export HHP_UEVENTD_FILES="$FIX/vendor-ueventd.rc $FIX/ueventd.rc"
# A fake glob expander backed by a fixture, so the tests give the same answer on
# every machine. The real one expands against the device's own /dev at boot.
export FIX
export HHP_EXPAND_CMD="$HERE/fake-expand \"\$1\""

echo ">>> adaptation tests"
# Task 2+ append their cases below this line.

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [x] **Step 3b: Write the fake glob expander**

`droidian/adaptation/tests/fake-expand`:

```bash
#!/usr/bin/env bash
# Expand a ueventd.rc path pattern against the fixture list instead of the real
# /dev. The production expander uses the shell's own globbing against the
# device's /dev; this exists only so the tests are hermetic.
set -uo pipefail
while read -r n; do
    [ -n "$n" ] || continue
    case "$n" in $1) printf '%s\n' "$n" ;; esac
done < "${FIX:?FIX must point at the fixtures directory}/existing.txt"
```

- [x] **Step 4: Run it to confirm the harness itself works**

```bash
chmod +x droidian/adaptation/tests/run-tests.sh droidian/adaptation/tests/fake-expand
./droidian/adaptation/tests/run-tests.sh
```

Expected: prints `>>> adaptation tests` then `passed=0 failed=0` and exits 0.

- [x] **Step 5: Commit**

```bash
git add droidian/adaptation/tests
git commit -m "test(adaptation): offline harness and ueventd fixtures"
```

---

### Task 2: `generate-rules` — parse ueventd.rc and filter to unreachable nodes

**Files:**
- Create: `droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/generate-rules`
- Modify: `droidian/adaptation/tests/run-tests.sh` (append cases)

**Interfaces:**
- Consumes: `HHP_UEVENTD_FILES`, `HHP_REACH_CMD`, `HHP_NODE_EXISTS_CMD` from Task 1.
- Produces: executable `generate-rules` writing a complete udev rules file to
  stdout. Task 5's systemd unit calls it as
  `generate-rules > /etc/udev/rules.d/70-halium-hostdev-perms.rules`.

- [x] **Step 1: Write the failing tests**

Append to `droidian/adaptation/tests/run-tests.sh`, above the final `echo`:

```bash
GEN="$ADAPT/halium-hostdev-perms/usr/lib/halium-hostdev-perms/generate-rules"
export HHP_POLICY_DIRS=""            # no policy yet; Task 3 adds deny handling
"$GEN" > /tmp/hhp-out.$$ 2>/dev/null

expect_contains "hwbinder is fixed (declared, unreachable)" /tmp/hhp-out.$$ \
    'KERNEL=="hwbinder", OWNER="root", GROUP="root", MODE="0666"'
expect_contains "kgsl-3d0 is fixed" /tmp/hhp-out.$$ \
    'KERNEL=="kgsl-3d0", OWNER="system", GROUP="system", MODE="0666"'
expect_contains "ion is fixed" /tmp/hhp-out.$$ \
    'KERNEL=="ion", OWNER="system", GROUP="system", MODE="0664"'
expect_absent "binder untouched (already reachable)" /tmp/hhp-out.$$ 'KERNEL=="binder"'
expect_absent "input untouched (already reachable)" /tmp/hhp-out.$$ 'event0'
expect_absent "dri card0 untouched (already reachable)" /tmp/hhp-out.$$ 'card0'
expect_absent "no inline comment after a rule" /tmp/hhp-out.$$ '" # '

# Globs must expand, and expand from the FIXTURE, not this host's /dev.
expect_contains "glob declaration expands (/dev/subsys_*)" /tmp/hhp-out.$$ \
    'KERNEL=="subsys_modem"'
expect_absent "expansion did not leak this host's /dev" /tmp/hhp-out.$$ 'event20'

# udev matches KERNEL against the sysname. A subdirectory node must emit its
# basename; KERNEL=="dri/renderD128" would match nothing and fail silently.
expect_contains "subdir node emits bare sysname" /tmp/hhp-out.$$ \
    'KERNEL=="renderD128", OWNER="root", GROUP="graphics", MODE="0666"'
expect_absent "KERNEL is never a path" /tmp/hhp-out.$$ 'KERNEL=="dri/'

# /dev/diag is declared in both files; the vendor file is read first and wins.
expect_contains "vendor declaration wins for diag" /tmp/hhp-out.$$ \
    'KERNEL=="diag", OWNER="system", GROUP="oem_2901"'
rm -f /tmp/hhp-out.$$
```

- [x] **Step 2: Run to verify it fails**

```bash
./droidian/adaptation/tests/run-tests.sh
```

Expected: FAIL on every case, because `generate-rules` does not exist yet.

- [x] **Step 3: Write the implementation**

`droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/generate-rules`:

```bash
#!/usr/bin/env bash
# Emit udev rules that restore the device's own ueventd.rc policy on the HOST
# /dev, for nodes the session user cannot otherwise reach.
#
# The Android container gets a private tmpfs /dev (lxc.autodev=0), so ueventd
# applies these modes only inside the container. The host /dev is devtmpfs
# driven by udev, and lxc-android's 65-android.rules covers binder but not the
# API-28 HIDL nodes or the GPU.
#
# The node set is COMPUTED, never hand-listed:
#     { declared in ueventd.rc } n { unreachable by the session user } \ { denied }
#
# The middle term is the safety invariant. Applying Android's declarations
# wholesale would break the device: the host has /dev/input/event* as
# root:android_input where ueventd.rc says root:input, and /dev/dri/card0 as
# root:video where ueventd.rc says root:graphics. Touch and display work
# BECAUSE of the host values. Never widen what is already reachable.
#
# Writes to stdout. Environment overrides exist so this is testable offline.
set -uo pipefail

UEVENTD_FILES="${HHP_UEVENTD_FILES:-/android/vendor/ueventd.rc /android/ueventd.rc}"
TARGET_USER="${HHP_TARGET_USER:-droidian}"

# ueventd.rc declares many nodes as globs -- 33 of 264 on fajita, including
# /dev/input/* and /dev/dri/*, the two the reachability invariant exists to
# protect. Expansion is a seam so the offline tests can be hermetic: the real
# expander globs against the device's own /dev, which is correct at boot but
# would make a test depend on whichever machine ran it.
expand() {
    if [ -n "${HHP_EXPAND_CMD:-}" ]; then
        eval "${HHP_EXPAND_CMD//\$1/$1}"
        return 0
    fi
    local n
    for n in $1; do [ -e "$n" ] && printf '%s\n' "$n"; done
    return 0
}

reachable() {
    if [ -n "${HHP_REACH_CMD:-}" ]; then
        eval "${HHP_REACH_CMD//\$1/$1}"
        return
    fi
    runuser -u "$TARGET_USER" -- test -r "$1" 2>/dev/null &&
    runuser -u "$TARGET_USER" -- test -w "$1" 2>/dev/null
}

declared=0
printf '# Generated from the device'"'"'s own ueventd.rc - do not hand-edit.\n'
printf '#\n'
printf '# Set = declared in ueventd.rc, unreachable by %s, not denied by policy.\n' "$TARGET_USER"
printf '# Nodes already reachable are deliberately left alone: reverting them to\n'
printf '# Android'"'"'s values would break working touch and display.\n'

emitted=""
for f in $UEVENTD_FILES; do
    [ -r "$f" ] || continue
    while read -r path mode uid gid _rest; do
        case "$path" in /dev/*) ;; *) continue ;; esac
        while read -r node; do
            [ -n "$node" ] || continue
            declared=$((declared + 1))
            # First declaration wins. The vendor file is read first and
            # /dev/diag is declared in both, with different owners.
            case " $emitted " in *" $node "*) continue ;; esac
            reachable "$node" && continue
            denied "$node" && continue
            emitted="$emitted $node"
            # udev matches KERNEL against the SYSNAME, not the path under /dev.
            # /dev/dri/card0 has sysname "card0", so stripping only the "/dev/"
            # prefix would emit KERNEL=="dri/card0", which matches nothing and
            # fails silently -- the exact failure mode this design forbids.
            printf '\n# ueventd.rc: %s %s %s %s\n' "$path" "$mode" "$uid" "$gid"
            printf 'ACTION=="add", KERNEL=="%s", OWNER="%s", GROUP="%s", MODE="%s"\n' \
                   "${node##*/}" "$uid" "$gid" "$mode"
        done < <(expand "$path")
    done < "$f"
done

if [ "$declared" -eq 0 ]; then
    echo "halium-hostdev-perms: no /dev declarations found in: $UEVENTD_FILES" >&2
    echo "halium-hostdev-perms: refusing to emit an empty ruleset" >&2
    exit 1
fi
```

Note `denied` is referenced but not yet defined — Task 3 adds it. Define a
temporary stub immediately above `declared=0` so this task's tests pass:

```bash
denied() { return 1; }   # replaced in Task 3
```

- [x] **Step 4: Run to verify it passes**

```bash
chmod +x droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/generate-rules
./droidian/adaptation/tests/run-tests.sh
```

Expected: `passed=10 failed=1`. The one remaining failure is
`subdir node emits bare sysname`, which asserts `GROUP="android_graphics"` —
that mapping arrives in Task 2b. Every other case passes here.

- [x] **Step 5: Commit**

```bash
git add droidian/adaptation/halium-hostdev-perms droidian/adaptation/tests/run-tests.sh
git commit -m "feat(adaptation): compute host /dev rules from the device's ueventd.rc

The node set is computed as declared-minus-reachable rather than hand-listed,
because an allow-list cannot be shown to be exhaustive. Restricting to
unreachable nodes is also what stops it reverting /dev/input and /dev/dri to
Android's values and breaking working touch and display."
```

---

### Task 2b: Resolve Android user and group names

**Files:**
- Modify: `droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/generate-rules`
- Create: `droidian/adaptation/tests/fixtures/groups.txt`, `.../users.txt`
- Modify: `droidian/adaptation/tests/fixtures/vendor-ueventd.rc`, `.../existing.txt`
- Modify: `droidian/adaptation/tests/run-tests.sh`

**Why this task exists.** Measured on the device: the `/dev` declarations name
**19 distinct groups, 13 of which do not exist** under that name on Droidian.
`lxc-android` renames Android's groups with an `android_` prefix, and **11 of
the 13** exist as `android_<name>` — `graphics` → `android_graphics`,
`camera` → `android_camera`, `drmrpc` → `android_drmrpc`. Only `oem_2901` and
`oem_2902` have no alias. Owners are nearly clean: only `usb` is missing.

udev **silently drops** a `GROUP=` it cannot resolve while still applying the
mode and owner. That is the same fail-quietly mode as the `KERNEL=` path bug,
and it would affect the majority of emitted rules.

**Rules:**
1. Resolve `X`; if absent, resolve `android_X`; use whichever exists.
2. If neither resolves, **emit no rule** for that node and log the skip to
   stderr. Never substitute a different group — that would invent access.
3. A skipped declaration is **not** recorded as handled, so a later, coarser
   declaration of the same node can still apply. `/dev/diag` is declared
   `system:oem_2901` in the vendor file and `radio:radio` in the base file; the
   vendor one is unusable, so the base one is used. The device's own policy
   still decides, just via its next most specific usable statement.

Mapping grants nothing new: `droidian` is already a member of these groups.

- [x] **Step 1: Extend the fixtures**

Append to `tests/fixtures/vendor-ueventd.rc` (verbatim device lines — note
`byte-cntr`'s irregular single space, which is real):

```
/dev/byte-cntr            0660   system    oem_2902
/dev/rmnet_ctrl           0660   usb        usb
```

`byte-cntr` covers an unresolvable **group** with no alias; `rmnet_ctrl` covers
an unresolvable **owner**. Append both nodes to `tests/fixtures/existing.txt`.

`tests/fixtures/groups.txt` — groups that exist on Droidian:

```
root
system
radio
input
android_graphics
android_drmrpc
```

`tests/fixtures/users.txt`:

```
root
system
radio
```

- [x] **Step 2: Write the failing tests**

Capture stderr, since the skips are asserted:

```bash
export HHP_GROUP_EXISTS_CMD="grep -qxF \"\$1\" $FIX/groups.txt"
export HHP_USER_EXISTS_CMD="grep -qxF \"\$1\" $FIX/users.txt"
"$GEN" > /tmp/hhp-map.$$ 2>/tmp/hhp-err.$$

expect_contains "graphics maps to android_graphics" /tmp/hhp-map.$$ \
    'KERNEL=="renderD128", OWNER="root", GROUP="android_graphics", MODE="0666"'
expect_contains "drmrpc maps to android_drmrpc" /tmp/hhp-map.$$ \
    'KERNEL=="qseecom", OWNER="system", GROUP="android_drmrpc", MODE="0660"'
expect_absent "unresolvable group emits nothing" /tmp/hhp-map.$$ 'byte-cntr'
expect_absent "unresolvable owner emits nothing" /tmp/hhp-map.$$ 'rmnet_ctrl'
expect_contains "the skip is logged, not silent" /tmp/hhp-err.$$ \
    'skipping /dev/byte-cntr: no group oem_2902 or android_oem_2902'
expect_contains "falls back to the base declaration for diag" /tmp/hhp-map.$$ \
    'KERNEL=="diag", OWNER="radio", GROUP="radio"'
rm -f /tmp/hhp-map.$$ /tmp/hhp-err.$$
```

The last case is the one that proves rule 3: the vendor declaration
(`system:oem_2901`) is unusable, so the base declaration (`radio:radio`) applies
instead of the node being dropped.

- [x] **Step 3: Implement**

Add the seams and resolver above `denied`:

```bash
group_exists() {
    if [ -n "${HHP_GROUP_EXISTS_CMD:-}" ]; then
        eval "${HHP_GROUP_EXISTS_CMD//\$1/$1}"; return
    fi
    getent group "$1" >/dev/null 2>&1
}

user_exists() {
    if [ -n "${HHP_USER_EXISTS_CMD:-}" ]; then
        eval "${HHP_USER_EXISTS_CMD//\$1/$1}"; return
    fi
    getent passwd "$1" >/dev/null 2>&1
}

# Droidian's lxc-android renames Android's groups with an android_ prefix.
# udev silently drops a GROUP= it cannot resolve while still applying the mode,
# so an unresolved name is a rule that half-applies and reports nothing.
resolve_name() {   # resolve_name <exists-fn> <name>
    if "$1" "$2"; then printf '%s\n' "$2"; return 0; fi
    if "$1" "android_$2"; then printf '%s\n' "android_$2"; return 0; fi
    return 1
}
```

In the emit loop, after the `denied` check and **before** `emitted` is updated:

```bash
            if ! ruid=$(resolve_name user_exists "$uid"); then
                printf 'halium-hostdev-perms: skipping %s: no user %s or android_%s\n' \
                       "$node" "$uid" "$uid" >&2
                continue
            fi
            if ! rgid=$(resolve_name group_exists "$gid"); then
                printf 'halium-hostdev-perms: skipping %s: no group %s or android_%s\n' \
                       "$node" "$gid" "$gid" >&2
                continue
            fi
```

Emit `"$ruid"` / `"$rgid"`, and keep the unresolved original in the provenance
comment so the mapping is visible in the generated file.

- [x] **Step 4: Run**

```bash
./droidian/adaptation/tests/run-tests.sh
```

Expected: `passed=17 failed=0`.

- [x] **Step 5: Commit**

```bash
git add droidian/adaptation
git commit -m "feat(adaptation): resolve Android group names to Droidian's android_ aliases"
```

---

### Task 3: Policy drop-ins and the deny defaults

**Files:**
- Modify: `droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/generate-rules`
- Create: `droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/policy.d/10-defaults.conf`
- Modify: `droidian/adaptation/tests/run-tests.sh`

**Interfaces:**
- Consumes: `generate-rules` from Task 2.
- Produces: `denied()` honouring `HHP_POLICY_DIRS`. Task 7 ships
  `50-fajita.conf` into the same directory.

- [x] **Step 1: Write the failing tests**

Append to `run-tests.sh` above the final `echo`:

```bash
export HHP_POLICY_DIRS="$ADAPT/halium-hostdev-perms/usr/lib/halium-hostdev-perms/policy.d"
"$GEN" > /tmp/hhp-pol.$$ 2>/dev/null
expect_absent "diag denied by default"         /tmp/hhp-pol.$$ 'KERNEL=="diag"'
expect_absent "ramdump_* denied by default"    /tmp/hhp-pol.$$ 'ramdump_modem'
expect_absent "subsys_* denied by default"     /tmp/hhp-pol.$$ 'subsys_modem'
expect_contains "qseecom still fixed"          /tmp/hhp-pol.$$ 'KERNEL=="qseecom"'

# A local allow fragment overrides the shipped deny.
tmp_pol=$(mktemp -d)
cp "$ADAPT/halium-hostdev-perms/usr/lib/halium-hostdev-perms/policy.d/10-defaults.conf" "$tmp_pol/"
printf 'allow /dev/diag\n' > "$tmp_pol/90-local.conf"
HHP_POLICY_DIRS="$tmp_pol" "$GEN" > /tmp/hhp-allow.$$ 2>/dev/null
expect_contains "local allow re-enables diag" /tmp/hhp-allow.$$ 'KERNEL=="diag"'

# allow must NOT override the reachability invariant.
printf 'allow /dev/input/event0\n' >> "$tmp_pol/90-local.conf"
HHP_POLICY_DIRS="$tmp_pol" "$GEN" > /tmp/hhp-allow2.$$ 2>/dev/null
expect_absent "allow cannot revert a reachable node" /tmp/hhp-allow2.$$ 'event0'
rm -rf "$tmp_pol" /tmp/hhp-pol.$$ /tmp/hhp-allow.$$ /tmp/hhp-allow2.$$

# Precedence is by BASENAME across all dirs, not by path. Dir "a" is searched
# first (it stands for /usr/lib) and holds the LATER basename, so sorting the
# merged list by path instead would apply 50-mid before 10-early and invert the
# result. Basename order is 10-early (deny) then 50-mid (allow) -> allow wins.
tmp_root=$(mktemp -d); mkdir -p "$tmp_root/a" "$tmp_root/b"
printf 'allow /dev/diag\n' > "$tmp_root/a/50-mid.conf"
printf 'deny /dev/diag\n'  > "$tmp_root/b/10-early.conf"
HHP_POLICY_DIRS="$tmp_root/a $tmp_root/b" "$GEN" > /tmp/hhp-ord.$$ 2>/dev/null
expect_contains "precedence is by basename, not by path" /tmp/hhp-ord.$$ 'KERNEL=="diag"'

# A same-named file in the later dir masks the earlier one, systemd-style.
printf 'deny /dev/qseecom\n'  > "$tmp_root/a/20-mask.conf"
printf 'allow /dev/qseecom\n' > "$tmp_root/b/20-mask.conf"
HHP_POLICY_DIRS="$tmp_root/a $tmp_root/b" "$GEN" > /tmp/hhp-mask.$$ 2>/dev/null
expect_contains "same-named file in the later dir masks the earlier" \
    /tmp/hhp-mask.$$ 'KERNEL=="qseecom"'
rm -rf "$tmp_root" /tmp/hhp-ord.$$ /tmp/hhp-mask.$$
```

The basename case is not hypothetical: with the merged list sorted by path it
fails, which was confirmed by reverting the function and re-running.

- [x] **Step 2: Run to verify it fails**

```bash
./droidian/adaptation/tests/run-tests.sh
```

Expected: the four deny/allow cases FAIL (`denied()` is still the stub).

- [x] **Step 3: Write the policy file**

`droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/policy.d/10-defaults.conf`:

```
# Shipped defaults. Override with a same-named file, or a later-sorting one,
# under /etc/halium-hostdev-perms/policy.d/
#
# Debug and forensic nodes. Android grants these to system, but nothing in a
# Droidian session needs them and /dev/diag is the modem diagnostic channel.
deny /dev/diag
deny /dev/ramdump_*
deny /dev/subsys_*
```

- [x] **Step 4: Replace the stub with the real implementation**

In `generate-rules`, replace `denied() { return 1; }` with:

```bash
POLICY_DIRS="${HHP_POLICY_DIRS-/usr/lib/halium-hostdev-perms/policy.d /etc/halium-hostdev-perms/policy.d}"

# Later files win; a same-named file in /etc masks the one in /usr/lib, which
# is the systemd drop-in convention.
#
# Ordering is by BASENAME the whole way through. Sorting the final list by full
# path would put /etc/.../90-local.conf before /usr/lib/.../10-defaults.conf and
# silently invert the documented precedence.
policy_files() {
    local d f
    for d in $POLICY_DIRS; do
        [ -d "$d" ] || continue
        for f in "$d"/*.conf; do
            [ -e "$f" ] && printf '%s %s\n' "$(basename "$f")" "$f"
        done
    done | sort -k1,1 -s | awk '{ m[$1]=$2 } END { for (k in m) print k, m[k] }' \
         | sort -k1,1 | cut -d' ' -f2-
}

# deny/allow are evaluated in order; the last match wins. allow only removes a
# deny -- it can never override the reachability test in the main loop.
denied() {
    local node=$1 verdict=1 f rule pat
    while read -r f; do
        [ -r "$f" ] || continue
        while read -r rule pat _; do
            case "$rule" in ''|'#'*) continue ;; esac
            # shellcheck disable=SC2254
            case "$node" in
                $pat) [ "$rule" = deny ] && verdict=0 || verdict=1 ;;
            esac
        done < "$f"
    done < <(policy_files)
    return $verdict
}
```

- [x] **Step 5: Run to verify it passes**

```bash
./droidian/adaptation/tests/run-tests.sh
```

Expected: `passed=25 failed=0`.

- [x] **Step 6: Commit**

```bash
git add droidian/adaptation
git commit -m "feat(adaptation): policy.d drop-ins with debug nodes denied by default

Drop-ins rather than one conffile because the generic and device packages both
contribute policy and would otherwise conflict in dpkg. allow only lifts a
deny; it can never override the reachability test, so no fragment can cause a
working node to be reverted."
```

---

### Task 4: udev syntax validation

**Files:**
- Modify: `droidian/adaptation/tests/run-tests.sh`

**Interfaces:**
- Consumes: `generate-rules`.
- Produces: nothing new; guards a defect that already occurred once.

- [x] **Step 1: Write the failing test**

A rule with a trailing inline comment is silently discarded by udev, and
`udevadm control --reload-rules` reports nothing. This cost a debugging cycle
already. Append to `run-tests.sh`:

```bash
# --resolve-names=never because verify resolves users and groups against
# whichever host runs it. The names here are the DEVICE's (system, radio,
# android_graphics) and exist on no build host, so resolving would fail
# everywhere except the phone. Resolution is the device's job at boot.
if command -v udevadm >/dev/null 2>&1 && udevadm verify --help >/dev/null 2>&1; then
    "$GEN" > /tmp/hhp-syn.$$ 2>/dev/null
    if udevadm verify --resolve-names=never /tmp/hhp-syn.$$ >/tmp/hhp-verify.$$ 2>&1; then
        echo "  PASS  udevadm verify accepts generated rules"; pass=$((pass+1))
    else
        echo "  FAIL  udevadm verify rejected the rules"; sed 's/^/        /' /tmp/hhp-verify.$$; fail=$((fail+1))
    fi

    # A check that cannot fail is not a check. Prove verify rejects the exact
    # defect this guards: a rule with a trailing inline comment.
    sed '$a ACTION=="add", KERNEL=="zz", OWNER="root", GROUP="root", MODE="0666" # bad' \
        /tmp/hhp-syn.$$ > /tmp/hhp-bad.$$
    if udevadm verify --resolve-names=never /tmp/hhp-bad.$$ >/dev/null 2>&1; then
        echo "  FAIL  verify accepted a trailing inline comment"; fail=$((fail+1))
    else
        echo "  PASS  verify rejects a trailing inline comment"; pass=$((pass+1))
    fi
    rm -f /tmp/hhp-syn.$$ /tmp/hhp-verify.$$ /tmp/hhp-bad.$$
else
    echo "  SKIP  udevadm verify not available"
fi
```

Running verify **with** name resolution on a build host prints
`Failed to resolve group 'system', ignoring` — which is also direct confirmation
of why Task 2b exists: udev applies the rest of the rule and drops only the
group, so an unresolved name half-applies and reports nothing.

- [x] **Step 2: Run it**

```bash
./droidian/adaptation/tests/run-tests.sh
```

Expected: `passed=27 failed=0`. If verify fails, the generator is emitting
invalid syntax — fix the generator, not the test.

- [x] **Step 3: Commit**

```bash
git add droidian/adaptation/tests/run-tests.sh
git commit -m "test(adaptation): assert udevadm accepts the generated rules

udev silently discards a rule with a trailing inline comment and reload
reports nothing, so only udevadm verify catches it."
```

---

### Task 5: Package `halium-hostdev-perms`

**Files:**
- Create: `droidian/adaptation/halium-hostdev-perms/DEBIAN/control`
- Create: `droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/apply`
- Create: `droidian/adaptation/halium-hostdev-perms/usr/lib/systemd/system/halium-hostdev-perms.service`
- Create: `droidian/adaptation/halium-hostdev-perms/etc/systemd/system/multi-user.target.wants/halium-hostdev-perms.service` (symlink)

**Interfaces:**
- Consumes: `generate-rules` from Tasks 2–3.
- Produces: a `.deb` tree ready for `dpkg-deb --build`, consumed by Task 8.

- [x] **Step 1: Write the control file**

```
Package: halium-hostdev-perms
Version: 1.0.0
Architecture: all
Maintainer: oneplus6t <https://github.com/briancappello/oneplus6t>
Depends: udev
Section: admin
Priority: optional
Description: Restore Android /dev permissions on the host for Halium devices
 The Android container gets a private tmpfs /dev, so ueventd applies the
 vendor's modes only inside it. The host /dev is driven by udev, whose
 Android rules predate Treble and cover binder but not hwbinder, vndbinder,
 the GPU or ion. Host-side clients such as the compositor cannot then reach
 the HIDL composer, and the display stays black.
 .
 This package derives the correct rules from the device's own ueventd.rc at
 boot, limited to nodes the session user cannot already reach. It contains no
 device-specific knowledge and works on any Halium device.
```

- [x] **Step 2: Write the systemd unit**

Ordering is verified: `systemd-udev-settle` -> `android-mount.service` (mounts
`/android/vendor`) -> `lxc@android.service` -> `android-service@hwcomposer` ->
`phosh.service`.

```ini
[Unit]
Description=Restore Android /dev permissions on the host
Documentation=https://github.com/briancappello/oneplus6t
# ueventd.rc lives on /android/vendor, mounted by android-mount.service.
After=android-mount.service
# Must finish before anything opens the nodes.
Before=lxc@android.service
ConditionPathExists=/android/ueventd.rc

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/halium-hostdev-perms/apply

[Install]
WantedBy=multi-user.target
```

- [x] **Step 3: Write the apply wrapper**

Create `droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/apply`:

```bash
#!/usr/bin/env bash
# Generate the rules, validate them, install and trigger. Fails loudly rather
# than silently doing nothing -- silence is how this class of bug hid for a
# whole debugging session.
set -euo pipefail
RULES=/etc/udev/rules.d/70-halium-hostdev-perms.rules
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

/usr/lib/halium-hostdev-perms/generate-rules > "$TMP"

# Names ARE resolvable here -- this is the device -- so verify with resolution
# on. An unresolvable user or group would mean the rule half-applies, and
# generate-rules should already have skipped it.
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
    if ! udevadm verify "$TMP" >/dev/null 2>&1; then
        echo "generated rules failed udevadm verify; refusing to install" >&2
        udevadm verify "$TMP" >&2 || true
        exit 1
    fi
fi

install -m 0644 "$TMP" "$RULES"
udevadm control --reload-rules

# Trigger only the nodes we actually named, then log what changed. KERNEL is a
# sysname, so find the node by sysname rather than assuming /dev/<sysname>:
# /dev/dri/card0 and /dev/input/event0 both live in a subdirectory.
grep -oE 'KERNEL=="[^"]+"' "$RULES" | cut -d'"' -f2 | while read -r k; do
    udevadm trigger --action=add --sysname-match="$k" || true
    node=$(find /dev -maxdepth 2 -name "$k" 2>/dev/null | head -1)
    echo "halium-hostdev-perms: $k -> $(stat -c '%a %U:%G' "${node:-/dev/$k}" 2>/dev/null || echo absent)"
done
udevadm settle
```

- [x] **Step 4: Create the enablement symlink**

Shipped as a file because the package has no maintainer scripts to run
`systemctl enable`.

```bash
mkdir -p droidian/adaptation/halium-hostdev-perms/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/halium-hostdev-perms.service \
   droidian/adaptation/halium-hostdev-perms/etc/systemd/system/multi-user.target.wants/halium-hostdev-perms.service
chmod +x droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/apply
```

- [x] **Step 5: Assert there are no maintainer scripts**

```bash
ls droidian/adaptation/halium-hostdev-perms/DEBIAN/
```

Expected: exactly `control`. If `postinst`/`preinst`/`prerm`/`postrm` appear,
`dpkg --root` would need qemu and the install seam breaks.

- [x] **Step 6: Commit**

```bash
git add droidian/adaptation/halium-hostdev-perms
git commit -m "feat(adaptation): package halium-hostdev-perms

Boot-time oneshot ordered after android-mount.service (so ueventd.rc is
readable) and before lxc@android.service (so the rules land before anything
opens the nodes). No maintainer scripts: the enablement symlink ships as a
file so dpkg --root needs no qemu."
```

---

### Task 6: Package `halium-oldkernel-compat`

**Files:**
- Create: `droidian/adaptation/halium-oldkernel-compat/DEBIAN/control`
- Create: `droidian/adaptation/halium-oldkernel-compat/usr/lib/halium-oldkernel-compat/apply`
- Create: `droidian/adaptation/halium-oldkernel-compat/usr/lib/systemd/system/halium-oldkernel-compat.service`
- Create: `droidian/adaptation/halium-oldkernel-compat/etc/systemd/system/polkit-agent-helper.socket` (symlink to `/dev/null`)
- Create: `droidian/adaptation/halium-oldkernel-compat/etc/systemd/system/multi-user.target.wants/halium-oldkernel-compat.service` (symlink)

**Interfaces:**
- Consumes: nothing.
- Produces: a `.deb` tree for Task 8.

- [x] **Step 1: Write the control file**

```
Package: halium-oldkernel-compat
Version: 1.0.0
Architecture: all
Maintainer: oneplus6t <https://github.com/briancappello/oneplus6t>
Depends: polkitd, dpkg
Section: admin
Priority: optional
Description: Make polkit authenticate on kernels without pidfd
 Droidian's polkitd runs its authentication helper as a socket-activated unit,
 which requires pidfd. pidfd_open landed in Linux 5.1, so on a vendor kernel
 older than that the helper exits before reading any password and every
 authentication fails -- indistinguishable from a wrong password.
 .
 This masks the socket and makes the setuid helper available instead, which is
 what the helper itself asks for. It is a no-op on kernels 5.1 and newer.
```

- [x] **Step 2: Write the apply script**

```bash
#!/usr/bin/env bash
# polkit-agent-helper.socket needs pidfd (Linux 5.1+). On older vendor kernels
# the helper exits 1 before reading the password, so authentication always
# fails and looks exactly like a wrong password. The helper's own error tells
# you the fix: disable the socket and use the setuid helper.
set -euo pipefail

# Overridable so the version gate is testable offline. Getting this branch
# wrong in the "has pidfd" direction leaves polkit quietly broken, which is
# indistinguishable from a wrong password -- exactly the bug being fixed.
HELPER="${HOKC_HELPER:-/usr/lib/polkit-1/polkit-agent-helper-1}"

# shellcheck disable=SC2086
kver=$(${HOKC_UNAME:-uname -r} | cut -d- -f1)
major=${kver%%.*}; rest=${kver#*.}; minor=${rest%%.*}
if [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 1 ]; }; then
    echo "halium-oldkernel-compat: kernel $kver has pidfd; nothing to do"
    exit 0
fi

[ -e "$HELPER" ] || { echo "halium-oldkernel-compat: $HELPER absent"; exit 0; }

# dpkg-statoverride rather than a bare chmod u+s, so a polkitd upgrade cannot
# silently drop the bit and resurrect the bug.
if ! dpkg-statoverride --list "$HELPER" >/dev/null 2>&1; then
    dpkg-statoverride --update --add root root 4755 "$HELPER"
fi
echo "halium-oldkernel-compat: $(stat -c '%A %U:%G' "$HELPER")"
```

- [x] **Step 3: Write the unit**

```ini
[Unit]
Description=polkit compatibility for kernels without pidfd
Before=polkit.service
ConditionPathExists=/usr/lib/polkit-1/polkit-agent-helper-1

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/halium-oldkernel-compat/apply

[Install]
WantedBy=multi-user.target
```

- [x] **Step 4: Create the symlinks**

The socket mask is a systemd mask expressed as a shipped file, so it needs no
maintainer script.

```bash
cd droidian/adaptation/halium-oldkernel-compat
mkdir -p etc/systemd/system/multi-user.target.wants usr/lib/halium-oldkernel-compat
ln -sf /dev/null etc/systemd/system/polkit-agent-helper.socket
ln -sf /usr/lib/systemd/system/halium-oldkernel-compat.service \
   etc/systemd/system/multi-user.target.wants/halium-oldkernel-compat.service
chmod +x usr/lib/halium-oldkernel-compat/apply
cd -
```

- [x] **Step 4b: Test the kernel version gate**

Append to `run-tests.sh`. `HOKC_HELPER` points at a missing file so the script
stops just after the gate, needing no root and no `dpkg-statoverride`:

```bash
APPLY="$ADAPT/halium-oldkernel-compat/usr/lib/halium-oldkernel-compat/apply"
for c in "4.9-113-oneplus-fajita:fix" "5.0.9:fix" "5.1.0:skip" "6.1.0-13-arm64:skip"; do
    kv=${c%%:*}; want=${c##*:}
    got=$(HOKC_UNAME="echo $kv" HOKC_HELPER=/nonexistent "$APPLY" 2>&1)
    ok=0
    case "$want" in
        fix)  case "$got" in *absent*)      ok=1 ;; esac ;;
        skip) case "$got" in *"has pidfd"*) ok=1 ;; esac ;;
    esac
    if [ "$ok" = 1 ]; then
        echo "  PASS  kernel $kv -> $want"; pass=$((pass+1))
    else
        echo "  FAIL  kernel $kv -> expected $want, got: $got"; fail=$((fail+1))
    fi
done
```

Expected: `passed=31 failed=0`.

- [x] **Step 5: Verify the mask symlink points at /dev/null**

```bash
readlink droidian/adaptation/halium-oldkernel-compat/etc/systemd/system/polkit-agent-helper.socket
```

Expected: `/dev/null`

- [x] **Step 6: Commit**

```bash
git add droidian/adaptation/halium-oldkernel-compat
git commit -m "feat(adaptation): package halium-oldkernel-compat

Kernel-version bug, not a device bug: any Halium port on a pre-5.1 vendor
kernel has broken polkit that presents as a rejected password. Guarded so it
is a no-op on 5.1+."
```

---

### Task 7: Package `adaptation-oneplus-fajita`

**Files:**
- Create: `droidian/adaptation/adaptation-oneplus-fajita/DEBIAN/control`
- Create: `droidian/adaptation/adaptation-oneplus-fajita/usr/lib/adaptation-oneplus-fajita/apply`
- Create: `droidian/adaptation/adaptation-oneplus-fajita/usr/lib/systemd/system/adaptation-oneplus-fajita.service`
- Create: `droidian/adaptation/adaptation-oneplus-fajita/usr/lib/halium-hostdev-perms/policy.d/50-fajita.conf`
- Create: `droidian/adaptation/adaptation-oneplus-fajita/etc/systemd/system/multi-user.target.wants/adaptation-oneplus-fajita.service` (symlink)

**Interfaces:**
- Consumes: the `policy.d` directory from Task 3.
- Produces: a `.deb` tree for Task 8.

- [x] **Step 1: Write the control file**

```
Package: adaptation-oneplus-fajita
Version: 1.0.0
Architecture: all
Maintainer: oneplus6t <https://github.com/briancappello/oneplus6t>
Depends: halium-hostdev-perms, halium-oldkernel-compat, dpkg
Section: admin
Priority: optional
Description: Device adaptation for the OnePlus 6T (fajita)
 Pulls in the generic Halium fixes and applies the device-specific glue for
 the OnePlus 6T. Explicitly fajita: upstream's oneplus6 packaging is ambiguous
 about which of the 6 and 6T an image is for.
```

- [x] **Step 2: Write the device policy fragment**

```
# Device policy for fajita. Nothing to add beyond the generic defaults yet;
# this file exists so device-specific deny/allow rules have an obvious home
# that does not collide with the generic package's 10-defaults.conf.
```

- [x] **Step 3: Write the apply script**

```bash
#!/usr/bin/env bash
# Device glue for fajita.
#
# Camera: Qt5 ships two camera mediaservice plugins and picks the wrong one.
# libgstcamerabin.so (generic GStreamer) cannot link a source against a vendor
# HAL and fails with "negotiation problem"; libaalcamera.so (libhybris/
# droidmedia) works. Setting backend=aal in /etc/droidian-camera.conf is NOT
# enough -- Qt resolves the service independently of the app's preference.
#
# The plugin must be diverted OUT of the scanned directory. Diverting it to
# <plugin>.unused in place does nothing: QFactoryLoader scans the whole
# directory and tries to load every file regardless of name.
set -euo pipefail

PLUGDIR=/usr/lib/aarch64-linux-gnu/qt5/plugins/mediaservice
PLUG="$PLUGDIR/libgstcamerabin.so"
DISABLED=/usr/lib/aarch64-linux-gnu/qt5/plugins-disabled

if [ -e "$PLUG" ] || [ -e "$DISABLED/libgstcamerabin.so" ]; then
    mkdir -p "$DISABLED"
    if ! dpkg-divert --list | grep -q "plugins-disabled/libgstcamerabin"; then
        dpkg-divert --add --rename --divert "$DISABLED/libgstcamerabin.so" "$PLUG"
    fi
    echo "adaptation-oneplus-fajita: camerabin diverted -> $DISABLED"
fi
```

- [x] **Step 4: Write the unit and symlink**

```ini
[Unit]
Description=Device adaptation for the OnePlus 6T (fajita)
After=halium-hostdev-perms.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/adaptation-oneplus-fajita/apply

[Install]
WantedBy=multi-user.target
```

```bash
cd droidian/adaptation/adaptation-oneplus-fajita
mkdir -p etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/adaptation-oneplus-fajita.service \
   etc/systemd/system/multi-user.target.wants/adaptation-oneplus-fajita.service
chmod +x usr/lib/adaptation-oneplus-fajita/apply
cd -
```

- [x] **Step 5: Commit**

```bash
git add droidian/adaptation/adaptation-oneplus-fajita
git commit -m "feat(adaptation): package adaptation-oneplus-fajita

Carries the camerabin diversion and is the home for the notch, brightness and
double-tap work still outstanding. Depends on the two generic packages."
```

---

### Task 8: `build-adaptation.sh`

**Files:**
- Create: `droidian/adaptation/build-adaptation.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the three package trees from Tasks 5–7.
- Produces: `droidian/out-adaptation/*.deb`, consumed by Task 9.

- [x] **Step 1: Write the build script**

```bash
#!/usr/bin/env bash
#
# Build the three adaptation .debs.
#
#   ./droidian/adaptation/build-adaptation.sh
#
# All three are Architecture: all -- shell scripts, systemd units and config,
# no compiled code -- so unlike the kernel and the camera app these need no
# arm64 emulation. dpkg-deb is not available on an Arch host, so the build runs
# in the Droidian container, which is amd64 and needs no qemu here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(dirname "$HERE")/out-adaptation"
IMAGE="quay.io/droidian/build-essential:current-amd64"
PKGS="halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita"

runtime() {
    command -v docker >/dev/null && { echo docker; return; }
    command -v podman >/dev/null && { echo podman; return; }
    echo "Need docker or podman." >&2; exit 1
}

echo ">>> offline tests"
"$HERE/tests/run-tests.sh"

echo ">>> asserting no maintainer scripts"
for p in $PKGS; do
    extra=$(ls "$HERE/$p/DEBIAN" | grep -v '^control$' || true)
    [ -z "$extra" ] || { echo "$p has maintainer scripts: $extra" >&2; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT"
$(runtime) run --rm -v "$HERE":/src -v "$OUT":/out "$IMAGE" /bin/sh -c '
set -e
for p in '"$PKGS"'; do
    cp -a "/src/$p" "/tmp/$p"
    chown -R root:root "/tmp/$p"
    find "/tmp/$p" -name apply -o -name generate-rules | xargs -r chmod 0755
    dpkg-deb --build "/tmp/$p" /out/
done
'

echo
echo ">>> built"
for f in "$OUT"/*.deb; do
    printf '    %-52s %s bytes\n' "$(basename "$f")" "$(stat -c%s "$f")"
done
```

- [x] **Step 2: Ignore the output directory**

Append to `.gitignore`:

```
droidian/out-adaptation/
```

- [x] **Step 3: Run it**

```bash
chmod +x droidian/adaptation/build-adaptation.sh
./droidian/adaptation/build-adaptation.sh
```

Expected: tests pass, then three `.deb` files listed.

- [x] **Step 4: Verify the packages contain no maintainer scripts**

```bash
for f in droidian/out-adaptation/*.deb; do
  echo "== $f"; ar p "$f" control.tar.* | tar tzf - 2>/dev/null || ar p "$f" control.tar.xz | tar tJf -
done
```

Expected: each lists only `./`, `./control` and `./md5sums`. Any `postinst`
means the rootfs install seam in Task 9 will need qemu and will fail.

- [x] **Step 5: Commit**

```bash
git add droidian/adaptation/build-adaptation.sh .gitignore
git commit -m "feat(adaptation): build the three .debs

Architecture: all, so no qemu is needed -- unlike the kernel and camera app.
Runs the offline tests and asserts no maintainer scripts before building,
since a maintainer script would silently break dpkg --root."
```

---

### Task 9: Install the packages into `rootfs.img`

**Files:**
- Modify: `droidian/build-rootfs.sh` (insert between `resize2fs` and `mke2fs`)

**Interfaces:**
- Consumes: `droidian/out-adaptation/*.deb` (Task 8) and
  `droidian/out-camera/*.deb` (already built).
- Produces: a `userdata.img` whose rootfs already contains all four fixes.

- [x] **Step 1: Add the install step**

In `droidian/build-rootfs.sh`, after the `resize2fs` block and the
`android-rootfs.img` symlink, before `# ---- pack`, insert:

```bash
# ---------------------------------------------------------------- adaptation
# Install our .debs into the rootfs so the fixes survive a reinstall. This is
# the seam that makes the whole pipeline worth having: without it every fix
# lives only on the running device and the next flash destroys it.
#
# Runs in the Droidian container because the host (Arch) has no dpkg. fuse2fs
# mounts the image rootlessly and dpkg --root installs arm64 packages from an
# amd64 container.
#
# Our three adaptation packages carry no maintainer scripts, so they alone need
# no emulation. droidian-camera is built with dh and DOES ship postinst/postrm,
# and dpkg --root chroots to run them -- so installing it requires qemu-aarch64
# binfmt with the F flag, which check-env.sh already asserts for the build role.
#
# /dev must be bind-mounted over the image's own. The image does contain a
# /dev/null character device, but FUSE mounts are nodev, so opening it fails
# with EPERM. Without this, droidian-camera's postinst hits
# "cannot create /dev/null: Permission denied" on its `command -v ... >/dev/null`
# line. That failure sits inside an `if` condition, so `set -e` does not trip
# and dpkg still reports success -- a silently half-applied package.
if [ "${ADAPTATION:-1}" = 1 ]; then
    debs=$(ls "$HERE"/out-adaptation/*.deb "$HERE"/out-camera/*.deb 2>/dev/null || true)
    if [ -z "$debs" ]; then
        echo "ABORT: no .debs found. Run droidian/adaptation/build-adaptation.sh" >&2
        echo "       and droidian/build-camera.sh first, or set ADAPTATION=0." >&2
        exit 1
    fi
    say "installing adaptation packages into rootfs.img"
    mkdir -p "$STAGE/debs"
    cp $debs "$STAGE/debs/"

    runtime() {
        command -v docker >/dev/null && { echo docker; return; }
        command -v podman >/dev/null && { echo podman; return; }
        echo "Need docker or podman." >&2; exit 1
    }

    # --cap-add SYS_ADMIN is a capability inside the container's user
    # namespace, not host root. Without it fusermount3 fails with EPERM.
    $(runtime) run --rm --device /dev/fuse --cap-add SYS_ADMIN \
        --security-opt apparmor=unconfined \
        -v "$STAGE":/stage \
        quay.io/droidian/build-essential:current-amd64 /bin/sh -c '
set -e
apt-get update -qq
apt-get install -y -qq fuse2fs fuse3 >/dev/null
mkdir -p /mnt/rootfs
# fuse2fs forks, so its exit code is meaningless. Assert with mountpoint.
fuse2fs -o rw,fakeroot /stage/rootfs.img /mnt/rootfs 2>&1 | grep -v journal || true
mountpoint -q /mnt/rootfs || { echo "fuse2fs failed to mount"; exit 1; }
mount --bind /dev /mnt/rootfs/dev
trap "umount /mnt/rootfs/dev 2>/dev/null || true; fusermount3 -u /mnt/rootfs 2>/dev/null || true" EXIT

dpkg --root=/mnt/rootfs -i /stage/debs/*.deb
dpkg --root=/mnt/rootfs --audit

# A half-configured package still lets dpkg exit 0, so assert the state
# explicitly: all four must be "ii", not "iF" or "iU".
want=4
got=$(dpkg --root=/mnt/rootfs -l halium-hostdev-perms halium-oldkernel-compat \
        adaptation-oneplus-fajita droidian-camera 2>/dev/null | grep -c "^ii")
dpkg --root=/mnt/rootfs -l halium-hostdev-perms halium-oldkernel-compat \
        adaptation-oneplus-fajita droidian-camera 2>/dev/null | grep "^[a-z][a-zA-Z]"
if [ "$got" != "$want" ]; then
    echo "ABORT: expected $want packages in state ii, found $got" >&2
    exit 1
fi

umount /mnt/rootfs/dev
trap - EXIT
fusermount3 -u /mnt/rootfs
'
    rm -rf "$STAGE/debs"
    e2fsck -fy "$STAGE/rootfs.img" >/dev/null 2>&1 || true   # fuse2fs bypasses the journal
fi
```

- [x] **Step 2: Assert the packages really landed**

Immediately after the block above, add:

```bash
if [ "${ADAPTATION:-1}" = 1 ]; then
    for p in halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita; do
        # debugfs exits 0 even when the file does not exist -- it prints
        # "File not found by ext2_lookup" to stderr and carries on. Asserting on
        # its exit code silently passes for a package that never installed, so
        # assert on the OUTPUT: a real stat always begins a line with "Inode:".
        if ! debugfs -R "stat /var/lib/dpkg/info/$p.list" "$STAGE/rootfs.img" 2>&1 \
             | grep -q '^Inode:'; then
            echo "ABORT: $p is not installed in rootfs.img" >&2
            exit 1
        fi
    done
    say "adaptation packages verified present in rootfs.img"
fi
```

- [x] **Step 2b: Prove the assert can actually fail**

A check that cannot fail is not a check. Confirm the `grep '^Inode:'` form
rejects an absent package, which the exit-code form did not:

```bash
debugfs -R "stat /var/lib/dpkg/info/no-such-package.list" \
    droidian/stage/rootfs.img 2>&1 | grep -c '^Inode:'
```

Expected: `0`. If this prints non-zero, the assert is still blind.

- [x] **Step 3: Build with the packages**

```bash
./droidian/build-rootfs.sh
```

Expected: the `dpkg --root -l` output lists all four packages as `ii`,
`--audit` prints nothing, and the verification step reports success.

- [x] **Step 4: Confirm the escape hatch still works**

```bash
ADAPTATION=0 ./droidian/build-rootfs.sh
```

Expected: skips the install entirely, producing a stock image for comparison.

- [x] **Step 5: Commit**

```bash
git add droidian/build-rootfs.sh
git commit -m "feat(droidian): install adaptation packages into rootfs.img

This is the seam that makes fixes survive a reinstall. Rootless: fuse2fs
mounts the image and dpkg --root installs arm64 packages from an amd64
container, which works only because the packages carry no maintainer scripts.
ADAPTATION=0 packs a stock image for comparison."
```

---

### Task 10: Hardware verification

**Files:**
- Create: `droidian/verify-device.sh`

**Interfaces:**
- Consumes: a flashed device.
- Produces: the assertion suite reused later as `provision.sh`'s `verify` phase.

- [x] **Step 1: Write the verifier**

Shipped as `droidian/verify-device.sh`. Every value is LABELLED at the source
and looked up by label rather than by line number, and the journal greps drop
`sudo[` lines first -- sudo logs the full command it runs, so a grep for a
string that appears in the script matches its own invocation and inflates every
count by one. That produced a phantom `CameraBin error` on the first run.

Two assertions from the original draft were wrong and were replaced:

- **`/dev/diag` is `600 root:root`.** It is `660 system:root` on a stock boot;
  `600 root:root` was an incidental value from a stale rootfs. The invariant is
  *reachability*, so assert that `droidian` can neither read nor write it, and
  that no rule was emitted for it. Both hold.
- **All four core nodes appear in our ruleset.** Which nodes need our help
  legitimately varies: the kgsl driver creates `/dev/kgsl-3d0` and `/dev/ion`
  already at their ueventd.rc values on some boots, and skipping an
  already-correct node is the design working. The outcome checks cover it.

- [x] **Step 2: Flash and verify**

`ALL PASS`, 14 checks, after a fresh flash with no manual step.

- [x] **Step 3: Prove durability**

Full cycle run twice — `build-adaptation.sh`, `build-rootfs.sh`, `flash.sh` —
then rebooted twice more. Boots 2 and 3 both `ALL PASS` with no intervention.

**Erosion, found here and fixed.** The ruleset was self-eroding: written to
`/etc`, applied by udev before the unit runs, so its own nodes read as already
reachable and dropped out. Measured 52 rules to 42 across one reboot, losing
`hwbinder` and `vndbinder`. Rules now live in `/run/udev/rules.d` (tmpfs), so
each boot measures a pristine `/dev`. Stable at 48 rules with both nodes present
across three boots.

**First-boot phosh race, pre-existing.** On the first boot after a flash, phosh
can fail `start-post` with a 30 s timeout while `lxc.service` is still starting
the container and the two `runonce@` services are running. `phoc` never logs.
It recovers on the next boot and is unrelated to these packages — our unit
finishes in 7.1 s, well before phosh starts.

## Done when

- `./droidian/adaptation/tests/run-tests.sh` passes offline, with no device.
- `./droidian/adaptation/build-adaptation.sh` produces three `.deb`s with no
  maintainer scripts.
- `./droidian/build-rootfs.sh` bakes all four packages into `rootfs.img`.
- `./droidian/verify-device.sh` reports `ALL PASS` after a **fresh flash with
  no manual intervention**.

That last line is the invariant made testable. Until it passes, the fixes are
not durable and the pipeline plan cannot safely proceed.
