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

- [ ] **Step 1: Create the ueventd fixtures**

These are real lines taken from the device, chosen to cover every case: a node
that is unreachable and must be fixed, nodes that are already reachable and
must be left alone, and nodes matching the deny defaults.

`droidian/adaptation/tests/fixtures/ueventd.rc`:

```
/dev/binder                0666   root       root
/dev/hwbinder              0666   root       root
/dev/vndbinder             0666   root       root
/dev/kmsg                  0620   root       system
```

`droidian/adaptation/tests/fixtures/vendor-ueventd.rc`:

```
/dev/kgsl-3d0              0666   system     system
/dev/ion                   0664   system     system
/dev/input/event0          0660   root       input
/dev/dri/card0             0666   root       graphics
/dev/diag                  0660   system     oem_2901
/dev/ramdump_modem         0640   system     system
/dev/subsys_modem          0640   system     system
/dev/qseecom               0660   system     drmrpc
```

- [ ] **Step 2: Create the reachability fixture**

Nodes the fake probe treats as already reachable by the session user. This
encodes the real device's state: touch and display work because udev already
made them reachable through Debian-style groups.

`droidian/adaptation/tests/fixtures/reachable.txt`:

```
/dev/binder
/dev/input/event0
/dev/dri/card0
```

- [ ] **Step 3: Write the test runner**

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
export HHP_REACH_CMD="grep -qxF \$1 $FIX/reachable.txt"
export HHP_UEVENTD_FILES="$FIX/vendor-ueventd.rc $FIX/ueventd.rc"
export HHP_NODE_EXISTS_CMD="true"

echo ">>> adaptation tests"
# Task 2+ append their cases below this line.

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
```

- [ ] **Step 4: Run it to confirm the harness itself works**

```bash
chmod +x droidian/adaptation/tests/run-tests.sh
./droidian/adaptation/tests/run-tests.sh
```

Expected: prints `>>> adaptation tests` then `passed=0 failed=0` and exits 0.

- [ ] **Step 5: Commit**

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

- [ ] **Step 1: Write the failing tests**

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
expect_absent "dri untouched (already reachable)" /tmp/hhp-out.$$ 'card0'
expect_absent "no inline comment after a rule" /tmp/hhp-out.$$ '" # '
rm -f /tmp/hhp-out.$$
```

- [ ] **Step 2: Run to verify it fails**

```bash
./droidian/adaptation/tests/run-tests.sh
```

Expected: FAIL on every case, because `generate-rules` does not exist yet.

- [ ] **Step 3: Write the implementation**

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
NODE_EXISTS_CMD="${HHP_NODE_EXISTS_CMD:-}"
TARGET_USER="${HHP_TARGET_USER:-droidian}"

node_exists() {
    [ -n "$NODE_EXISTS_CMD" ] && { eval "$NODE_EXISTS_CMD"; return; }
    [ -e "$1" ]
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
        for node in $path; do
            node_exists "$node" || continue
            declared=$((declared + 1))
            case " $emitted " in *" $node "*) continue ;; esac
            reachable "$node" && continue
            denied "$node" && continue
            emitted="$emitted $node"
            printf '\n# ueventd.rc: %s %s %s %s\n' "$path" "$mode" "$uid" "$gid"
            printf 'ACTION=="add", KERNEL=="%s", OWNER="%s", GROUP="%s", MODE="%s"\n' \
                   "${node#/dev/}" "$uid" "$gid" "$mode"
        done
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

- [ ] **Step 4: Run to verify it passes**

```bash
chmod +x droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/generate-rules
./droidian/adaptation/tests/run-tests.sh
```

Expected: `passed=7 failed=0`.

- [ ] **Step 5: Commit**

```bash
git add droidian/adaptation/halium-hostdev-perms droidian/adaptation/tests/run-tests.sh
git commit -m "feat(adaptation): compute host /dev rules from the device's ueventd.rc

The node set is computed as declared-minus-reachable rather than hand-listed,
because an allow-list cannot be shown to be exhaustive. Restricting to
unreachable nodes is also what stops it reverting /dev/input and /dev/dri to
Android's values and breaking working touch and display."
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

- [ ] **Step 1: Write the failing tests**

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
```

- [ ] **Step 2: Run to verify it fails**

```bash
./droidian/adaptation/tests/run-tests.sh
```

Expected: the four deny/allow cases FAIL (`denied()` is still the stub).

- [ ] **Step 3: Write the policy file**

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

- [ ] **Step 4: Replace the stub with the real implementation**

In `generate-rules`, replace `denied() { return 1; }` with:

```bash
POLICY_DIRS="${HHP_POLICY_DIRS-/usr/lib/halium-hostdev-perms/policy.d /etc/halium-hostdev-perms/policy.d}"

# Later files win; a same-named file in /etc masks the one in /usr/lib, which
# is the systemd drop-in convention.
policy_files() {
    local d f seen=""
    for d in $POLICY_DIRS; do
        [ -d "$d" ] || continue
        for f in "$d"/*.conf; do [ -e "$f" ] && echo "$(basename "$f") $f"; done
    done | sort -k1,1 -s | awk '{ m[$1]=$2 } END { for (k in m) print m[k] }' | sort
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

- [ ] **Step 5: Run to verify it passes**

```bash
./droidian/adaptation/tests/run-tests.sh
```

Expected: `passed=13 failed=0`.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write the failing test**

A rule with a trailing inline comment is silently discarded by udev, and
`udevadm control --reload-rules` reports nothing. This cost a debugging cycle
already. Append to `run-tests.sh`:

```bash
if command -v udevadm >/dev/null 2>&1; then
    "$GEN" > /tmp/hhp-syn.$$ 2>/dev/null
    if udevadm verify /tmp/hhp-syn.$$ >/tmp/hhp-verify.$$ 2>&1; then
        echo "  PASS  udevadm verify accepts generated rules"; pass=$((pass+1))
    else
        echo "  FAIL  udevadm verify rejected the rules"; sed 's/^/        /' /tmp/hhp-verify.$$; fail=$((fail+1))
    fi
    rm -f /tmp/hhp-syn.$$ /tmp/hhp-verify.$$
else
    echo "  SKIP  udevadm not present"
fi
```

- [ ] **Step 2: Run it**

```bash
./droidian/adaptation/tests/run-tests.sh
```

Expected: PASS. If it fails, the generator is emitting invalid syntax — fix
the generator, not the test.

- [ ] **Step 3: Commit**

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

- [ ] **Step 1: Write the control file**

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

- [ ] **Step 2: Write the systemd unit**

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

- [ ] **Step 3: Write the apply wrapper**

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

if command -v udevadm >/dev/null && ! udevadm verify "$TMP" >/dev/null 2>&1; then
    echo "generated rules failed udevadm verify; refusing to install" >&2
    udevadm verify "$TMP" >&2 || true
    exit 1
fi

install -m 0644 "$TMP" "$RULES"
udevadm control --reload-rules

# Trigger only the nodes we actually named, then log what changed.
grep -oE 'KERNEL=="[^"]+"' "$RULES" | cut -d'"' -f2 | while read -r k; do
    udevadm trigger --action=add --sysname-match="$k" || true
    echo "halium-hostdev-perms: $k -> $(stat -c '%a %U:%G' "/dev/$k" 2>/dev/null || echo absent)"
done
udevadm settle
```

- [ ] **Step 4: Create the enablement symlink**

Shipped as a file because the package has no maintainer scripts to run
`systemctl enable`.

```bash
mkdir -p droidian/adaptation/halium-hostdev-perms/etc/systemd/system/multi-user.target.wants
ln -sf /usr/lib/systemd/system/halium-hostdev-perms.service \
   droidian/adaptation/halium-hostdev-perms/etc/systemd/system/multi-user.target.wants/halium-hostdev-perms.service
chmod +x droidian/adaptation/halium-hostdev-perms/usr/lib/halium-hostdev-perms/apply
```

- [ ] **Step 5: Assert there are no maintainer scripts**

```bash
ls droidian/adaptation/halium-hostdev-perms/DEBIAN/
```

Expected: exactly `control`. If `postinst`/`preinst`/`prerm`/`postrm` appear,
`dpkg --root` would need qemu and the install seam breaks.

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write the control file**

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

- [ ] **Step 2: Write the apply script**

```bash
#!/usr/bin/env bash
# polkit-agent-helper.socket needs pidfd (Linux 5.1+). On older vendor kernels
# the helper exits 1 before reading the password, so authentication always
# fails and looks exactly like a wrong password. The helper's own error tells
# you the fix: disable the socket and use the setuid helper.
set -euo pipefail

HELPER=/usr/lib/polkit-1/polkit-agent-helper-1

kver=$(uname -r | cut -d- -f1)
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

- [ ] **Step 3: Write the unit**

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

- [ ] **Step 4: Create the symlinks**

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

- [ ] **Step 5: Verify the mask symlink points at /dev/null**

```bash
readlink droidian/adaptation/halium-oldkernel-compat/etc/systemd/system/polkit-agent-helper.socket
```

Expected: `/dev/null`

- [ ] **Step 6: Commit**

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

- [ ] **Step 1: Write the control file**

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

- [ ] **Step 2: Write the device policy fragment**

```
# Device policy for fajita. Nothing to add beyond the generic defaults yet;
# this file exists so device-specific deny/allow rules have an obvious home
# that does not collide with the generic package's 10-defaults.conf.
```

- [ ] **Step 3: Write the apply script**

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

- [ ] **Step 4: Write the unit and symlink**

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

- [ ] **Step 5: Commit**

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

- [ ] **Step 1: Write the build script**

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

- [ ] **Step 2: Ignore the output directory**

Append to `.gitignore`:

```
droidian/out-adaptation/
```

- [ ] **Step 3: Run it**

```bash
chmod +x droidian/adaptation/build-adaptation.sh
./droidian/adaptation/build-adaptation.sh
```

Expected: tests pass, then three `.deb` files listed.

- [ ] **Step 4: Verify the packages contain no maintainer scripts**

```bash
for f in droidian/out-adaptation/*.deb; do
  echo "== $f"; ar p "$f" control.tar.* | tar tzf - 2>/dev/null || ar p "$f" control.tar.xz | tar tJf -
done
```

Expected: each lists only `./`, `./control` and `./md5sums`. Any `postinst`
means the rootfs install seam in Task 9 will need qemu and will fail.

- [ ] **Step 5: Commit**

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

- [ ] **Step 1: Add the install step**

In `droidian/build-rootfs.sh`, after the `resize2fs` block and the
`android-rootfs.img` symlink, before `# ---- pack`, insert:

```bash
# ---------------------------------------------------------------- adaptation
# Install our .debs into the rootfs so the fixes survive a reinstall. This is
# the seam that makes the whole pipeline worth having: without it every fix
# lives only on the running device and the next flash destroys it.
#
# Runs in the Droidian container because the host (Arch) has no dpkg. fuse2fs
# mounts the image rootlessly; dpkg --root installs arm64 packages from an
# amd64 container, which works ONLY because these packages have no maintainer
# scripts, so no target binary is ever executed.
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
dpkg --root=/mnt/rootfs -i /stage/debs/*.deb
dpkg --root=/mnt/rootfs -l | grep -E "halium-hostdev-perms|halium-oldkernel-compat|adaptation-oneplus-fajita|droidian-camera"
dpkg --root=/mnt/rootfs --audit
fusermount3 -u /mnt/rootfs
'
    rm -rf "$STAGE/debs"
    e2fsck -fy "$STAGE/rootfs.img" >/dev/null 2>&1 || true   # fuse2fs bypasses the journal
fi
```

- [ ] **Step 2: Assert the packages really landed**

Immediately after the block above, add:

```bash
if [ "${ADAPTATION:-1}" = 1 ]; then
    for p in halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita; do
        debugfs -R "stat /var/lib/dpkg/info/$p.list" "$STAGE/rootfs.img" >/dev/null 2>&1 \
            || { echo "ABORT: $p is not installed in rootfs.img" >&2; exit 1; }
    done
    say "adaptation packages verified present in rootfs.img"
fi
```

- [ ] **Step 3: Build with the packages**

```bash
./droidian/build-rootfs.sh
```

Expected: the `dpkg --root -l` output lists all four packages as `ii`,
`--audit` prints nothing, and the verification step reports success.

- [ ] **Step 4: Confirm the escape hatch still works**

```bash
ADAPTATION=0 ./droidian/build-rootfs.sh
```

Expected: skips the install entirely, producing a stock image for comparison.

- [ ] **Step 5: Commit**

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

- [ ] **Step 1: Write the verifier**

```bash
#!/usr/bin/env bash
#
# Assert the device is actually fixed. Checks user-visible outcomes, not that
# files exist, and asserts the NEGATIVE cases too -- the two ways this design
# could silently do the wrong thing.
#
#   ./droidian/verify-device.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH="$(dirname "$HERE")/.venv/bin/python $HERE/ssh.py"
fail=0
ck() { if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; fail=1; fi; }

out=$($SSH -r 'systemctl is-active phosh; echo ---
stat -c "%a %U:%G" /dev/hwbinder /dev/kgsl-3d0 /dev/diag /dev/input/event0; echo ---
journalctl -b --no-pager | grep -c "GL renderer: Adreno" ; echo ---
dpkg -l halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita 2>/dev/null | grep -c "^ii"; echo ---
dpkg-divert --list | grep -c plugins-disabled/libgstcamerabin' 2>/dev/null)

echo "$out"
ck "phosh active"                 "grep -q '^active' <<<\"\$out\""
ck "hwbinder widened"             "grep -q '666 root:root' <<<\"\$out\""
ck "kgsl widened"                 "grep -q '666 system:system' <<<\"\$out\""
ck "diag STILL denied"            "grep -q '600 root:root' <<<\"\$out\""
ck "input STILL android_input"    "grep -q 'root:android_input' <<<\"\$out\""
ck "hardware GL (not pixman)"     "grep -qx '[1-9][0-9]*' <<<\"\$(sed -n '7p' <<<\"\$out\")\""
ck "3 adaptation packages"        "grep -qx '3' <<<\"\$out\""
ck "camerabin diverted"           "grep -qx '1' <<<\"\$out\""
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit $fail
```

- [ ] **Step 2: Flash and verify**

```bash
./droidian/flash.sh
# wait for boot, then
./droidian/verify-device.sh
```

Expected: `ALL PASS`. The two `STILL` assertions are the important ones — they
prove the deny default held and that we did not revert a working convention.

- [ ] **Step 3: Prove durability, which is the whole point**

```bash
./droidian/build-rootfs.sh && ./droidian/flash.sh
# wait for boot
./droidian/verify-device.sh
```

Expected: `ALL PASS` again, with **no manual step in between**. If this needs
any `ssh` fix-up, the invariant is broken and the offending fix must be moved
into a package.

- [ ] **Step 4: Commit**

```bash
git add droidian/verify-device.sh
git commit -m "test(droidian): assert the device fixes survive a reinstall

Checks user-visible outcomes and the negative cases: /dev/diag must still be
denied and /dev/input must still be root:android_input, proving the deny
default and the reachability invariant both held."
```

---

## Done when

- `./droidian/adaptation/tests/run-tests.sh` passes offline, with no device.
- `./droidian/adaptation/build-adaptation.sh` produces three `.deb`s with no
  maintainer scripts.
- `./droidian/build-rootfs.sh` bakes all four packages into `rootfs.img`.
- `./droidian/verify-device.sh` reports `ALL PASS` after a **fresh flash with
  no manual intervention**.

That last line is the invariant made testable. Until it passes, the fixes are
not durable and the pipeline plan cannot safely proceed.
