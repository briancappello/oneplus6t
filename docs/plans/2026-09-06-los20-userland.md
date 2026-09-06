# Userland swap to api33 (Phase 4 of the LineageOS 20 roadmap)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the Droidian rootfs on `linuxroot` and the Android container inside
it are the api33 set (`rootfs-api33`, `android-system-gsi-33`,
`adaptation-hybris-api33-phone`), and `lxc@android` runs that GSI against
the LineageOS 20 `vendor` on slot b, on the Phase 3 kernel.

**Architecture:** nothing structural changes. `build-rootfs.sh` already
selects the rootfs by `API=`; the api33 zip has the same layout and the same
`setup.sh` as the api28 one, and it already carries every api33 package, so
the swap is one default plus the guards that keep it honest: the pipeline
must be able to SEE which GSI a built image carries (today it cannot, and
would skip the flash), the device-side glue must stop bind-mounting OxygenOS
9 files over the LineageOS vendor (it does today, by an mtime bug), and
`verify-device.sh` gains the container invariants the roadmap's exit
criteria name but which do not exist yet.

**Tech Stack:** `droidian/build-rootfs.sh` (podman `build-essential`,
e2fsprogs), `build.sh` manifest, `provision.sh` + `lib/{probe,phases}.sh`,
`droidian/verify-device.sh`, the `adaptation-oneplus-fajita` package,
`tests/run-tests.sh` (162 today), `droidian/adaptation/tests/run-tests.sh`
(43 today).

## Global Constraints

- Branch `los20-port`. Slot b only; slot a is not touched. Never
  `fastboot -w`, never erase `dtbo`, never flash `userdata`.
- The rootfs artifact stays `droidian/linuxroot.img` / `.simg`, flashed to
  `linuxroot` by `provision.sh`'s `data` phase. No renames.
- Zero device-side hand edits: every fix is a script change, a package
  change, or a defconfig/cmdline line, and lands through `provision.sh`.
- Both suites stay green and grow: `tests/run-tests.sh` 162 -> more,
  `droidian/adaptation/tests/run-tests.sh` 43 -> more. A test that encodes
  the old API is updated, not deleted.
- Long runs launch as `setsid nohup ... > log 2>&1 < /dev/null &`, watched
  with `bin/watch-log`. Never edit a running script.
- No AI attribution in commits. Conventional commits.
- Display is NOT in scope (Phase 5). `phosh active` and `hardware GL` in
  `verify-device.sh` are expected to FAIL at the end of this phase.

---

## Facts this plan relies on (verified 2026-09-06)

**The api33 rootfs zip.** `droidian-OFFICIAL-phosh-phone-rootfs-api33-arm64-next_20260906.zip`
(1397 MiB, release tag `nightly`, in `downloads/`). Contents: `data/rootfs.img`
(4354736128 bytes), `setup.sh`, `tools/busybox`, `META-INF/...`. Its
`setup.sh` is **byte-identical** to the api28 zip's (`diff` empty): the
`resize2fs -f /data/rootfs.img 8G` and
`ln -s /halium-system/var/lib/lxc/android/android-rootfs.img` lines that
`build-rootfs.sh` reimplements offline are the same lines. The nightly
release also carries per-device zips whose names contain `api33`
(`volla_mimir-api33`, ...), so a name filter that only says `api33` is not
enough; `build-rootfs.sh` today matches the substring `rootfs-api33`, which
happens to be unique but is not asserted.

**What is inside `rootfs.img` (api33)**, read with `debugfs` from
`/var/lib/dpkg/status`:

| Package | Version |
|---|---|
| `android-system-gsi-33` | `13.0.0+r47.20250407.ubports.517+git20250407200008.4367ed2.next.production` |
| `adaptation-hybris-api33-phone` / `-api33` / `-common` / `-phone` / `-phosh` | `31+git20260630130539.fcbdd0d.next.production` |
| `droidian-quirks-api33` | `100+git20260630124647.bb620f8.next.production` |
| `pulseaudio-modules-droid-modern` | `14.2.103-1+droidian0+git20240829212213.935726a.next.production` |
| `pulseaudio-modules-droid-hidl` | `1.4.0-1+git20220228002517.8fd0da4.bookworm.production` |
| `ofono-binder-plugin` | `1.1.25-1~git20260513163533.9b9e8bd.next.upgrade.gbinder` |
| `bluebinder` / `timekeeper` / `audiosystem-passthrough` | present |
| `droidian-camera` | `16+z1.1+git20240608103441.a0b51cd.next.production` |
| `lxc-android` | `1:40+git20260817002444.2c7912c.next.production` |

`droidian-camera` is at **`a0b51cd`**, which is exactly `CAMERA_COMMIT` in
`droidian/build-camera.sh:36`. The roadmap's "re-pin the camera" item is a
verification, not a change. `/var/lib/lxc/android/config` in the api33 image
is identical to the one on the device today minus the two
`lxc.mount.entry` lines `adaptation-oneplus-fajita` appends. The GSI
(`android-rootfs.img`, 425861120 bytes, ext4) reports
`ro.build.version.sdk=33`, `ro.build.version.release=13`,
`ro.system.build.fingerprint=halium/lineage_halium_arm64/halium_arm64:13/TQ3A.230901.001/515:userdebug/test-keys`,
`ro.build.type=userdebug`, ships `/system/etc/selinux/plat_sepolicy.cil`
and friends, and ships `/system/etc/init/bpfloader.rc` with
`reboot_on_failure reboot,bpfloader-failed` **intact**.

**What the device runs today** (slot b, Phase 3 kernel, old rootfs):
`android-system-gsi-28 9.0.0+r47.20240114...` owns
`/var/lib/lxc/android/android-rootfs.img`; `lxc-android` owns `config` and
`pre-start.sh`; `adaptation-hybris-api28-phone -> adaptation-hybris-api28 ->
droidian-quirks-api28 + pulseaudio-modules-droid-jb2q`. Container props:
`ro.build.version.sdk=28`, `ro.vndk.version=27`, 59 services in
`[restarting]`. The api28 GSI's init loads **no** SELinux policy on this
kernel (no `type=1404` audit line; LineageOS prints one at 2.59 s), so
every `restorecon` fails with `EOPNOTSUPP` and floods dmesg with 4444
`SELinux: Could not set context` lines. Host: `/sys/fs/selinux/enforce` =
0, nothing about selinux on the cmdline.

**The stale-override bug (Tier 2, found while gathering these facts).**
`adaptation-oneplus-fajita/usr/lib/adaptation-oneplus-fajita/apply:77`
and `:109` regenerate `/var/lib/lxc/android/vendor-build.prop` and
`init.qcom.rc` only when the vendor source is `-nt` the override. Android
builds stamp vendor files with a fixed mtime (`2008-12-31 17:00:00` on
LineageOS 20's `vendor/build.prop` and `init.qcom.rc`), so once an
override exists it is never refreshed. Measured: the container's
`ro.vendor.build.fingerprint` reads OxygenOS 9.0.17's
(`...:9/PKQ1.180716.001/1909112330...`), and OxygenOS 9's 1033-line
`init.qcom.rc` is bound over LineageOS's 760-line one. LineageOS 20's
`vendor/build.prop` has **no** `ro.build.shutdown_timeout` line at all (the
sed is a no-op there; keep/delete is Phase 6's call), and its
`init.qcom.rc` still has `service chre ... shutdown critical` (that override
still matters).

**LineageOS 20's vendor identity.** `ro.vendor.build.fingerprint` is
`OnePlus/OnePlus6T/OnePlus6T:9/PKQ1.180716.001/1812260627:user/release-keys`
(LineageOS keeps the stock fingerprint; only the build date differs from
OxygenOS 9.0.17's `1909112330`). Not usable as an invariant. What is:
`ro.vendor.build.version.sdk=33` and `ro.vndk.version=33`
(`logs/lineage20/getprop.txt`).

**The pipeline cannot see a GSI swap.** `build.sh` records `"version": ""`
for the rootfs images (`build.sh:229-231`); `lib/phases.sh:99-141`
`skip_data` compares only the `.deb` artifacts' versions against the
probe's `pkg_<name>=` lines; `lib/probe.sh:29` lists exactly four
packages. An api33 image with the same adaptation and camera versions
would be SKIPPED by `provision.sh` today. `FORCE=1` exists but is a
workaround, not a design.

**`verify-device.sh` has no container check.** The roadmap's exit criterion
names "container active"; `droidian/verify-device.sh:106-133` has no such
check. The suite exercises it against `tests/fixtures/verify-healthy.txt`
through the fake `device-ssh`, so every new `echo key=` line needs a fixture
line.

**bpfloader.** Under LineageOS's own init on our kernel (the Phase 3
`skip_initramfs` loop) `bpfloader` exited 2 after 20 s and the
`reboot_on_failure` took the phone down. Inside an lxc pid namespace a
`reboot()` from the container's init kills the container, not the phone.
The api33 GSI keeps that line. Whether bpfloader fails under the GSI is
unknown until it boots; the mitigation (a bind-mounted `bpfloader.rc`
without the line, same technique as `init.qcom.rc`) is ready in Task 6.

**Kernel-side inputs, unchanged from Phase 3:** 4.9.337 has no binderfs;
`/dev/binder`, `/dev/hwbinder`, `/dev/vndbinder` exist from
`CONFIG_ANDROID_BINDER_DEVICES`; `pre-start.sh`'s Halium-9 branch only
mounts binderfs `if [ ! -e /dev/binder ]`. SELinux is compiled in,
permissive at boot (`SELINUX_DEVELOP=y`), no `androidboot.selinux=` token
on the cmdline (`droidian/packaging/debian/kernel-info.mk`).

---

### Task 1: Vendor overrides follow the vendor that is actually there

**Files:**
- Modify: `droidian/adaptation/adaptation-oneplus-fajita/usr/lib/adaptation-oneplus-fajita/apply:65-118`
- Modify: `droidian/adaptation/adaptation-oneplus-fajita/DEBIAN/control` (Version `1.11.0` -> `1.12.0`)
- Test: `droidian/adaptation/tests/run-tests.sh` (append after the last block)

**Interfaces:**
- Produces: `apply` honours `AOF_LXC_DIR` (default `/var/lib/lxc/android`) and
  `AOF_LXC_NET_DEFAULTS` (default `/etc/default/lxc-net`), the same
  env-override convention as `HHP_UEVENTD_FILES` and `HOKC_UNAME` in the
  sibling packages, so the suite can run it unprivileged.
- Consumes: nothing new.

Why first: every later task measures the container against the LineageOS
vendor. With this bug in place the measurement is of OxygenOS 9's
`init.qcom.rc` running on a LineageOS vendor, and 59 restarting services
tell you nothing.

- [ ] **Step 1: Write the failing test**

Append to `droidian/adaptation/tests/run-tests.sh`, before the final
summary line (the file ends with the `passed=... failed=...` echo; put this
above it):

```bash
# ---------------------------------------------------------------- Task 1 (los20-userland)
# The vendor overrides must track the vendor's CONTENT. Android builds stamp
# vendor files with a fixed mtime (2008-12-31 on LineageOS 20), so an mtime
# guard never refreshes an override once one exists: measured as OxygenOS 9's
# init.qcom.rc bound over LineageOS 20's inside the container.
AOF_APPLY="$ADAPT/adaptation-oneplus-fajita/usr/lib/adaptation-oneplus-fajita/apply"
aof=$(mktemp -d)
mkdir -p "$aof/rootfs/vendor/etc/init/hw"
printf 'ro.build.shutdown_timeout=0\nro.vendor.build.fingerprint=old\n' > "$aof/rootfs/vendor/build.prop"
printf 'service chre /vendor/bin/chre\n    class late_start\n    shutdown critical\n\nservice other /vendor/bin/other\n    shutdown critical\n' > "$aof/rootfs/vendor/etc/init/hw/init.qcom.rc"
: > "$aof/config"
printf 'USE_LXC_BRIDGE="false"\n' > "$aof/lxc-net"
touch -d 2008-12-31 "$aof/rootfs/vendor/build.prop" "$aof/rootfs/vendor/etc/init/hw/init.qcom.rc"

AOF_LXC_DIR="$aof" AOF_LXC_NET_DEFAULTS="$aof/lxc-net" "$AOF_APPLY" > /tmp/aof-1.$$ 2>&1
expect_contains "shutdown_timeout is patched"        "$aof/vendor-build.prop" 'ro.build.shutdown_timeout=6'
expect_contains "chre is disabled"                   "$aof/init.qcom.rc" '    disabled'
expect_contains "other services keep shutdown critical" "$aof/init.qcom.rc" 'other/bin/other'
expect_contains "build.prop bind is registered"      "$aof/config" 'vendor-build.prop vendor/build.prop'
expect_contains "init.qcom.rc bind is registered"    "$aof/config" 'init.qcom.rc vendor/etc/init/hw/init.qcom.rc'

# The vendor changes underneath (a new slot, a new Android), with the SAME
# fixed mtime. The override must follow.
printf 'ro.vendor.build.fingerprint=new\n' > "$aof/rootfs/vendor/build.prop"
printf 'service chre /vendor/bin/chre\n    shutdown critical\n\n' > "$aof/rootfs/vendor/etc/init/hw/init.qcom.rc"
touch -d 2008-12-31 "$aof/rootfs/vendor/build.prop" "$aof/rootfs/vendor/etc/init/hw/init.qcom.rc"
AOF_LXC_DIR="$aof" AOF_LXC_NET_DEFAULTS="$aof/lxc-net" "$AOF_APPLY" > /tmp/aof-2.$$ 2>&1
expect_contains "override follows a changed vendor build.prop" "$aof/vendor-build.prop" 'fingerprint=new'
expect_absent   "old vendor content is gone"                    "$aof/vendor-build.prop" 'fingerprint=old'
expect_absent   "override follows a changed init.qcom.rc"       "$aof/init.qcom.rc" 'other/bin/other'
expect_rc "config bind lines are not duplicated" 1 "$(grep -c vendor-build.prop "$aof/config")"
rm -rf "$aof" /tmp/aof-1.$$ /tmp/aof-2.$$
```

Check how `ADAPT` is defined at the top of that file (it is the adaptation
directory, used by the `HHP`/`HOKC` blocks) and reuse it.

- [ ] **Step 2: Run the suite, watch the new cases fail**

Run: `droidian/adaptation/tests/run-tests.sh 2>&1 | tail -15`
Expected: the first run aborts or fails inside the new block, because
`apply` ignores `AOF_LXC_DIR` (it will try `/var/lib/lxc/android`, which
does not exist on the workstation, so the override blocks are skipped and
`shutdown_timeout is patched` FAILs) and, if `/etc/default/lxc-net` exists
with the bridge on, `sed -i` on it fails under `set -e`.

- [ ] **Step 3: Make `apply` content-driven and testable**

Replace lines 65-118 of `apply` with:

```bash
LXC_NET_DEFAULTS="${AOF_LXC_NET_DEFAULTS:-/etc/default/lxc-net}"
if [ -f "$LXC_NET_DEFAULTS" ] && grep -q '^USE_LXC_BRIDGE="true"' "$LXC_NET_DEFAULTS"; then
    sed -i 's/^USE_LXC_BRIDGE="true"/USE_LXC_BRIDGE="false"/' "$LXC_NET_DEFAULTS"
    echo "adaptation-oneplus-fajita: disabled the unused lxc bridge wait"
fi

# Both overrides below are derived from the vendor files the container will
# see, every boot, unconditionally. An earlier version regenerated only when
# the vendor file was newer than the override (-nt). Android builds stamp
# vendor files with a fixed mtime (2008-12-31 on LineageOS 20), so after the
# vendor partition changed underneath -- a different slot, a different
# Android -- the container kept getting OxygenOS 9's init.qcom.rc bound over
# LineageOS 20's. Two seds on two small files cost nothing; a stale copy
# cost a day. The bind entries are appended once; the FILES are rewritten.
LXC_DIR="${AOF_LXC_DIR:-/var/lib/lxc/android}"
VENDOR_PROP="$LXC_DIR/rootfs/vendor/build.prop"
OVERRIDE="$LXC_DIR/vendor-build.prop"
ENTRY="lxc.mount.entry = $OVERRIDE vendor/build.prop none bind,ro 0 0"

if [ -f "$VENDOR_PROP" ] && [ -f "$LXC_DIR/config" ]; then
    sed 's/^ro\.build\.shutdown_timeout=0$/ro.build.shutdown_timeout=6/' \
        "$VENDOR_PROP" > "$OVERRIDE.tmp" && mv "$OVERRIDE.tmp" "$OVERRIDE"
    echo "adaptation-oneplus-fajita: wrote $OVERRIDE"
    if ! grep -qF "vendor-build.prop" "$LXC_DIR/config"; then
        printf '%s\n' "$ENTRY" >> "$LXC_DIR/config"
        echo "adaptation-oneplus-fajita: bound patched build.prop into the container"
    fi
fi

# Do not run chre. (comment block unchanged -- keep lines 88-103 verbatim)
QCOM_RC="$LXC_DIR/rootfs/vendor/etc/init/hw/init.qcom.rc"
RC_OVERRIDE="$LXC_DIR/init.qcom.rc"
RC_ENTRY="lxc.mount.entry = $RC_OVERRIDE vendor/etc/init/hw/init.qcom.rc none bind,ro 0 0"

if [ -f "$QCOM_RC" ] && [ -f "$LXC_DIR/config" ] && grep -q '^service chre ' "$QCOM_RC"; then
    # Within the chre block only.
    sed '/^service chre /,/^$/ s/^    shutdown critical$/    disabled/' \
        "$QCOM_RC" > "$RC_OVERRIDE.tmp" && mv "$RC_OVERRIDE.tmp" "$RC_OVERRIDE"
    echo "adaptation-oneplus-fajita: wrote $RC_OVERRIDE (chre disabled)"
    if ! grep -qF "init.qcom.rc" "$LXC_DIR/config"; then
        printf '%s\n' "$RC_ENTRY" >> "$LXC_DIR/config"
        echo "adaptation-oneplus-fajita: bound patched init.qcom.rc into the container"
    fi
fi
```

Keep the existing comment blocks (shutdown window, bridge wait, chre)
above their sections; only the code changes. The `.tmp` + `mv` matters:
the override is a live bind source, and a `sed >` that truncates it while
the container is reading would hand the container an empty `init.qcom.rc`.

In `DEBIAN/control`, `Version: 1.11.0` -> `Version: 1.12.0`. The probe
compares this version against the manifest; a bumped version is what makes
`provision.sh` reinstall it.

- [ ] **Step 4: Run both suites**

Run: `droidian/adaptation/tests/run-tests.sh 2>&1 | tail -3 && tests/run-tests.sh 2>&1 | tail -2`
Expected: `passed=52 failed=0` (43 + 9 new) and `passed=162 failed=0`.

- [ ] **Step 5: Commit**

```bash
git add droidian/adaptation/adaptation-oneplus-fajita droidian/adaptation/tests/run-tests.sh
git commit -m "fix(adaptation): regenerate vendor overrides from content, not mtime

Android builds stamp vendor files with a fixed mtime (2008-12-31 on
LineageOS 20), so the -nt guard in apply never refreshed
vendor-build.prop and init.qcom.rc once they existed. Measured on the
first Halium-kernel boot against the LineageOS 20 vendor: the container
saw OxygenOS 9.0.17's fingerprint and OxygenOS 9's 1033-line init.qcom.rc
bound over LineageOS's 760-line one. Regenerate unconditionally through a
temp file (the override is a live bind source), and take AOF_LXC_DIR /
AOF_LXC_NET_DEFAULTS so the suite can run it. Version 1.12.0."
```

---

### Task 2: `build-rootfs.sh` builds api33 and says which GSI it packed

**Files:**
- Modify: `droidian/build-rootfs.sh:33-36` (API), `:58-81` (asset resolution), `:82-88` (extract + setup.sh assertion), `:196-203` (GSI sidecar, after the adaptation block, before pack)
- Modify: `.gitignore` if `droidian/linuxroot.*` is not already a pattern there (check with `git check-ignore -v droidian/linuxroot.simg`)

**Interfaces:**
- Produces: `droidian/linuxroot.gsi`, one line, `<package> <version>` of the
  `android-system-gsi-*` package inside the image, e.g.
  `android-system-gsi-33 13.0.0+r47.20250407.ubports.517+git20250407200008.4367ed2.next.production`.
  Task 3 lists it as a rootfs output and `skip_data` compares it.
- Consumes: `downloads/droidian-OFFICIAL-phosh-phone-rootfs-api33-arm64-next_20260906.zip` (already there).

- [ ] **Step 1: API default and an asset filter that cannot pick a device zip**

`droidian/build-rootfs.sh:33-36` becomes:

```bash
# Droidian ships a generic rootfs per Android API level. api33 = Android 13,
# the LineageOS 20 base on slot b (docs/plans/2026-09-06-los20-port-roadmap.md,
# Phase 4). api28 was the OxygenOS 9.0.17 era and is history on main.
API="${API:-33}"
RELEASE_REPO="droidian-images/droidian"
# The nightly release also carries per-device zips (volla_mimir-api33, ...).
# Match the generic rootfs by its full stem, never by the api substring.
ROOTFS_STEM="droidian-OFFICIAL-phosh-phone-rootfs-api${API}-arm64"
```

In the resolver (`:69`), replace
`if 'rootfs-api${API}' in a['name'] and a['name'].endswith('.zip'):`
with
`if a['name'].startswith('${ROOTFS_STEM}') and a['name'].endswith('.zip'):`
and the `raise SystemExit('no api${API} rootfs asset found')` message with
`'no ${ROOTFS_STEM}*.zip asset found'`.

- [ ] **Step 2: Assert the zip's `setup.sh` still says what we reimplement**

After `unzip -tq` (`:82`) and before the extract section add:

```bash
# build-rootfs.sh reimplements the zip's setup.sh offline (resize to 8G,
# symlink android-rootfs.img into /data). If upstream changes that script,
# the reimplementation is silently wrong. Assert the two lines it mirrors.
setup=$(unzip -p "$zip" setup.sh)
grep -q 'resize2fs -f /data/rootfs.img 8G' <<<"$setup" ||
    { echo "ABORT: setup.sh no longer resizes rootfs.img to 8G; re-read it" >&2; exit 1; }
grep -q 'ln -s /halium-system/var/lib/lxc/android/android-rootfs.img /data/android-rootfs.img' <<<"$setup" ||
    { echo "ABORT: setup.sh no longer symlinks android-rootfs.img; re-read it" >&2; exit 1; }
```

- [ ] **Step 3: Record the GSI the image carries**

After the adaptation block's closing `fi` (`:203`) and before `# ---- pack`:

```bash
# ---------------------------------------------------------------- identity
# Which Android container this image carries. The pipeline compares this
# against the device (lib/phases.sh skip_data via lib/probe.sh): the .debs
# alone cannot tell an api28 image from an api33 one.
GSI="$HERE/linuxroot.gsi"
debugfs -R 'cat /var/lib/dpkg/status' "$STAGE/rootfs.img" 2>/dev/null |
    awk '/^Package: android-system-gsi-/{p=$2} /^Version: /{v=$2} /^$/{if(p){print p, v; exit}}' > "$GSI"
[ -s "$GSI" ] || { echo "ABORT: no android-system-gsi-* package in rootfs.img" >&2; exit 1; }
say "container: $(cat "$GSI")"
case "$(cat "$GSI")" in
    "android-system-gsi-$API "*) ;;
    *) echo "ABORT: image carries $(cut -d' ' -f1 "$GSI") but API=$API was requested" >&2; exit 1 ;;
esac
```

- [ ] **Step 4: Build it**

`build-rootfs.sh` needs `out-adaptation/` (Task 1 bumped
`adaptation-oneplus-fajita`, so rebuild it) and `out-camera/`. Use
`build.sh`, which orders them and writes the manifest:

```bash
setsid nohup ./build.sh rootfs > ~/rootfs-build.log 2>&1 < /dev/null &
bin/watch-log ~/rootfs-build.log --done 'manifest' --fail 'ABORT|error:|E: ' --max 40 --stall 300
```

(`build.sh` runs `camera` and `adaptation` first because of the
`rootfs|camera adaptation|` row. If `BUILD_HOST=taichi` is how rootfs
builds usually run here, do the same; the zip must then be in taichi's
`downloads/`, or let the script fetch it.)

Expected in the log: `resolving latest api33 rootfs` (or the cached zip),
`container: android-system-gsi-33 13.0.0+r47...`, `adaptation packages
verified present`, `has_journal` asserted, `linuxroot.simg` written.

- [ ] **Step 5: Verify the artifact says api33**

```bash
cat droidian/linuxroot.gsi
debugfs -R 'cat /var/lib/dpkg/status' droidian/stage/rootfs.img 2>/dev/null | grep -cE '^Package: .*(api28|gsi-28|jb2q)'
```
Expected: `android-system-gsi-33 13.0.0+r47.20250407.ubports.517+...` and `0`.
(`droidian/stage/` is left behind by the build; if it is not, run the
same `debugfs` against `droidian/linuxroot.img` with the inner path
`/rootfs.img` dumped first, or trust the sidecar the build asserted.)

- [ ] **Step 6: Commit**

```bash
git add droidian/build-rootfs.sh .gitignore
git commit -m "feat(rootfs): build the api33 rootfs and record which GSI it carries

API defaults to 33 (LineageOS 20 base). The asset is matched by its full
stem so the nightly's per-device api33 zips can never be picked. The zip's
setup.sh is asserted to still contain the two lines this script mirrors
offline (verified byte-identical between api28 and api33 today). The build
writes droidian/linuxroot.gsi, the android-system-gsi package and version
inside the image, so provisioning can tell an api33 image from an api28
one; the .debs alone cannot."
```

---

### Task 3: The pipeline can tell an api33 image from an api28 one

**Files:**
- Modify: `build.sh:32` (rootfs outputs), `build.sh:229-231` (version for `.gsi`)
- Modify: `lib/probe.sh:29` (dpkg list), `lib/phases.sh:108-123` (skip_data wants)
- Modify: `tests/fixtures/manifest.json`, `tests/fixtures/probe-droidian.txt`
- Test: `tests/run-tests.sh` (near the `data phase runs when version differs` block, ~line 369)

**Interfaces:**
- Consumes: `droidian/linuxroot.gsi` from Task 2 (`<package> <version>`, one line).
- Produces: manifest entry `"droidian/linuxroot.gsi": {"target": "rootfs",
  "version": "<package> <version>", ...}`; probe line
  `pkg_android-system-gsi-33=<version>`; `skip_data` returns 1 (run) when
  they disagree.

Design: the `.gsi` sidecar's whole content becomes its manifest `version`,
and `skip_data`'s existing loop compares it exactly like a `.deb`. No new
loop, no new predicate; the container image is just one more package the
device must already have.

- [ ] **Step 1: Failing tests**

In `tests/run-tests.sh`, right after the `data phase runs when version
differs` block (the one that writes `/tmp/pr-data-diff.$$`), add:

```bash
# Skip detection: the container GSI is a package the device must already
# have. An api33 image with the same adaptation and camera versions as the
# api28 install on the phone must NOT be skipped; the .debs cannot tell them
# apart, the android-system-gsi package can.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=linuxroot\npkg_droidian-camera=1.0.0\npkg_adaptation-oneplus-fajita=1.0.0\npkg_halium-hostdev-perms=1.0.0\npkg_android-system-gsi-28=9.0.0\n' > /tmp/pr-data-gsi28.$$
expect_pred "data runs when the device carries a different GSI package" run \
    skip_data /tmp/pr-data-gsi28.$$ "$ROOT/tests/fixtures/manifest.json"
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=linuxroot\npkg_droidian-camera=1.0.0\npkg_adaptation-oneplus-fajita=1.0.0\npkg_halium-hostdev-perms=1.0.0\npkg_android-system-gsi-33=13.0.0\n' > /tmp/pr-data-gsi33.$$
expect_pred "data skips when the GSI package and version match" skip \
    skip_data /tmp/pr-data-gsi33.$$ "$ROOT/tests/fixtures/manifest.json"
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=linuxroot\npkg_droidian-camera=1.0.0\npkg_adaptation-oneplus-fajita=1.0.0\npkg_halium-hostdev-perms=1.0.0\npkg_android-system-gsi-33=13.0.1\n' > /tmp/pr-data-gsi33v.$$
expect_pred "data runs when the GSI version differs" run \
    skip_data /tmp/pr-data-gsi33v.$$ "$ROOT/tests/fixtures/manifest.json"
rm -f /tmp/pr-data-gsi28.$$ /tmp/pr-data-gsi33.$$ /tmp/pr-data-gsi33v.$$
```

Note `expect_pred` is defined at `tests/run-tests.sh:304`, above these
blocks; the existing `data phase skips when versions match` case will
start needing the GSI line too once the fixture manifest has one, so
update that `printf` to include `pkg_android-system-gsi-33=13.0.0`.

Add the artifact to `tests/fixtures/manifest.json` after the `.simg` entry:

```json
    "droidian/linuxroot.gsi": {
      "target": "rootfs", "version": "android-system-gsi-33 13.0.0",
      "sha256": "ffff", "bytes": 30, "repo_commit": "cafe123", "source_commit": "cafe123"
    },
```

In `tests/fixtures/probe-droidian.txt`, line 1 becomes the api33 GSI
fingerprint and the dpkg block gains the GSI line:

```
/system/build.prop:ro.build.fingerprint=halium/lineage_halium_arm64/halium_arm64:13/TQ3A.230901.001/515:userdebug/test-keys
---
ii  adaptation-oneplus-fajita 1.0.0                                  all          Device adaptation for the OnePlus 6T (fajita)
ii  android-system-gsi-33     13.0.0+r47.20250407.ubports.517+git20250407200008.4367ed2.next.production arm64 Android 13 GSI
ii  droidian-camera           16+z1.1+git20260904141054.bbe4a34.head arm64        This package contains Droidian's default camera app.
ii  halium-hostdev-perms      1.0.0                                  all          Restore Android /dev permissions on the host for Halium devices
ii  halium-oldkernel-compat   1.0.0                                  all          Make polkit authenticate on kernels without pidfd
```

(`tests/run-tests.sh:760` asserts `vendor_fp=halium/lineage_halium_arm64`,
a prefix; it still holds.)

- [ ] **Step 2: Run, see the three new cases fail**

Run: `tests/run-tests.sh 2>&1 | grep -E 'GSI|passed='`
Expected: `data runs when the device carries a different GSI package`
FAILs (skip_data ignores `.gsi`), `data skips when ...` PASSes for the
wrong reason, `data runs when the GSI version differs` FAILs.

- [ ] **Step 3: Implement**

`build.sh:32`:
```bash
  "rootfs|camera adaptation|droidian/linuxroot.img droidian/linuxroot.simg droidian/linuxroot.gsi|droidian|droidian/build-rootfs.sh"
```

`build.sh:229-231`:
```bash
            # name_VERSION_arch.deb -> VERSION; a .gsi sidecar IS its version
            # ("<package> <version>" of the container image); empty for images.
            ver=""
            case "$f" in
                *_*_*.deb) ver="$(basename "$f" | cut -d_ -f2)" ;;
                *.gsi)     ver="$(tr -d '\n' < "$OUT/$f")" ;;
            esac
```

`lib/phases.sh:114-122` (inside the python):
```python
for path, art in doc.get("artifacts", {}).items():
    base = os.path.basename(path)
    version = art.get("version") or ""
    if base.endswith(".gsi"):
        # "<package> <version>": the container image, compared like a .deb.
        if len(version.split()) == 2:
            print(version)
        continue
    if not base.endswith(".deb"):
        continue
    # name_VERSION_arch.deb
    name = base.split("_")[0]
    if name and version:
        print("%s %s" % (name, version))
```

`lib/probe.sh:29`: in the `dpkg -l ... droidian-camera` list add
`'android-system-gsi-*'` (quoted, dpkg expands the glob itself). Keep it
inside the single-quoted remote command by writing it as
`"android-system-gsi-*"` (double quotes are fine inside the single-quoted
string).

- [ ] **Step 4: Run the suite**

Run: `tests/run-tests.sh 2>&1 | tail -2`
Expected: `passed=165 failed=0`.

Also the real thing, read-only, against the phone as it is now (api28 on
the device, api33 in the manifest from Task 2):

```bash
./provision.sh --plan-only 2>&1 | tail -5
```
Expected: the plan names the `data` phase (not skipped), because the probe
reports `pkg_android-system-gsi-28=...` and the manifest wants `-33`.

- [ ] **Step 5: Commit**

```bash
git add build.sh lib/probe.sh lib/phases.sh tests/run-tests.sh tests/fixtures/manifest.json tests/fixtures/probe-droidian.txt
git commit -m "feat(provision): the container GSI is a package the device must already have

build-rootfs.sh now records the android-system-gsi package inside the
image (droidian/linuxroot.gsi); build.sh puts that line in the manifest as
the sidecar's version; the probe lists android-system-gsi-* alongside the
four .debs; skip_data compares it like any other package. Before this an
api33 image with unchanged adaptation and camera versions was invisible to
the pipeline and the data phase would have been skipped."
```

---

### Task 4: `androidboot.selinux=permissive` on the cmdline, bootloader-tested first

**Files:**
- Modify: `droidian/packaging/debian/kernel-info.mk` (`KERNEL_BOOTIMAGE_CMDLINE`)
- Uses: `/tmp/opencode/bisect/` (`los.kernel`, `los.ramdisk`, `try.sh` from Phase 3), `taichi:~/lineage20/out/host/linux-x86/bin/mkbootimg`

**Interfaces:**
- Produces: a `boot.img` whose cmdline carries `androidboot.selinux=permissive`.
  Task 5's `enforce` check and Task 6's first boot rely on it.

Why: Android 13's init loads the vendor's precompiled policy (the GSI is
`userdebug`, `plat_sepolicy_vers` 33.0 matches the vendor) and then calls
`security_setenforce(IsEnforcing())`. `IsEnforcing()` is true unless the
kernel cmdline says `androidboot.selinux=permissive`. Our kernel is
permissive at boot but `SELINUX_DEVELOP=y` allows the switch, and nothing
on the host is labelled: an enforcing container init would enforce
Android's policy on Droidian. The api28 GSI got away with it only because
its Android 9 init could not load a policy against this vendor at all.
The token is the standard Halium/Droidian one. The risk is the LineageOS
20 dtbo's bootloader, which refused `security=apparmor` (Phase 3); test
with the same 40 s method before trusting it.

- [ ] **Step 1: Bisect the token against the bootloader**

On taichi, from LineageOS's own kernel and ramdisk with LineageOS's own
cmdline plus the one token (`C-los-hcmdline.img` in the bisect dir was
built the same way; `unpack_bootimg --format=mkbootimg` on
`lineage/out/boot.img` prints the argument list):

```bash
scp lineage/out/boot.img taichi:/tmp/los-boot.img
ssh taichi 'set -e; B=~/lineage20/out/host/linux-x86/bin; rm -rf /tmp/sx && mkdir /tmp/sx && cd /tmp/sx
args=$($B/unpack_bootimg --boot_img /tmp/los-boot.img --out u --format=mkbootimg)
cmd=$(python3 -c "import sys,shlex;a=shlex.split(sys.stdin.read());print(a[a.index(\"--cmdline\")+1])" <<<"$args")
eval $B/mkbootimg $args --cmdline "\"$cmd androidboot.selinux=permissive\"" --output /tmp/sx/S1-selinux-permissive.img'
scp taichi:/tmp/sx/S1-selinux-permissive.img /tmp/opencode/bisect/
/tmp/opencode/bisect/try.sh /tmp/opencode/bisect/S1-selinux-permissive.img
```

Expected: `S1-selinux-permissive: BOOTED (Android MTP/adb 18d1:4ee7) at ~60s`.
If instead `DIED -> fastboot at 12s`: the bootloader rejects the token.
STOP, record it in this plan, and take the fallback: a kernel patch that
makes `/sys/fs/selinux/enforce` writes a no-op (`security/selinux/selinuxfs.c`,
`sel_write_enforce`) as `0008-selinux-never-enforce.patch`, with the reason
above in its header. Do not proceed to Task 6 with neither.

- [ ] **Step 2: Add the token**

`droidian/packaging/debian/kernel-info.mk`: append
` androidboot.selinux=permissive` to `KERNEL_BOOTIMAGE_CMDLINE`, and add
above the variable, after the existing `NO apparmor` paragraph:

```
# androidboot.selinux=permissive: Android 13's init loads the vendor policy
# and calls setenforce(1) unless the cmdline says otherwise; the kernel is
# SELINUX_DEVELOP=y so that switch would land, on a host where nothing is
# labelled. Verified against the LineageOS 20 dtbo's bootloader with the
# Phase 3 bisect method before it went in (docs/plans/2026-09-06-los20-userland.md, Task 4).
```

- [ ] **Step 3: Rebuild and flash boot_b**

```bash
git add droidian/packaging/debian/kernel-info.mk
git commit -m "feat(kernel): androidboot.selinux=permissive on the cmdline

Android 13's init enforces unless told not to; the GSI is userdebug and
its policy now loads against the LineageOS 20 vendor. The kernel is
permissive at boot with SELINUX_DEVELOP=y, so without this token the
container's init would switch the whole host to enforcing under Android's
policy. Bootloader-tested with LineageOS's own kernel and ramdisk first."
git push origin los20-port
ssh taichi 'cd ~/oneplus6t && git fetch -q && git reset -q --hard origin/los20-port && setsid nohup ./droidian/build-kernel.sh > ~/kernel-build.log 2>&1 < /dev/null &'
ssh taichi '~/oneplus6t/bin/watch-log ~/kernel-build.log --done "^>>> done\." --fail "Exception:|^E: |dpkg-buildpackage: error|\*\*\* \[|FAILED TO APPLY|kernel tree is not at|^FAIL " --max 12 --stall 180'
scp taichi:oneplus6t/droidian/out/images/boot.img droidian/out/images/boot.img
scp taichi:oneplus6t/droidian/out/images/vbmeta.img droidian/out/images/vbmeta.img
```

Flashing happens in Task 6 together with the rootfs (`provision.sh` does
both); do not flash here.

---

### Task 5: `verify-device.sh` learns the container invariants

**Files:**
- Modify: `droidian/verify-device.sh:85-92` (facts), `:126-133` (checks)
- Modify: `tests/fixtures/verify-healthy.txt`

**Interfaces:**
- Produces: seven new labelled facts and checks, listed below. Task 6
  reads their PASS/FAIL as the phase's exit evidence.

- [ ] **Step 1: Fixture first**

Append to `tests/fixtures/verify-healthy.txt`:

```
container=active
sdk=33
vsdk=33
vndk=33
oldapi=0
hwsm=running
enforce=0
looping=0
```

Run: `tests/run-tests.sh 2>&1 | grep -E 'verify|passed='`
Expected: still `passed=165` (the fixture has extra lines nobody reads yet;
this step only proves the fixture is well-formed and the tests do not
care about unknown keys).

- [ ] **Step 2: Facts, inside the remote block**

After the `timewarp=` line (`:92`) and before the `# NOT asserted` comment:

```bash
# Phase 4 (api33 userland): the container must be the api33 GSI, running,
# against the LineageOS 20 vendor, with SELinux left permissive by Android
# init and no vendor service crash-looping. getprop on the host reads the
# container property area (/dev/__properties__ is shared).
echo "container=$(systemctl is-active lxc@android.service 2>/dev/null)"
echo "sdk=$(getprop ro.build.version.sdk 2>/dev/null)"
echo "vsdk=$(getprop ro.vendor.build.version.sdk 2>/dev/null)"
echo "vndk=$(getprop ro.vndk.version 2>/dev/null)"
echo "oldapi=$(dpkg -l 2>/dev/null | grep -cE "^ii  (android-system-gsi-28|droidian-quirks-api28|adaptation-hybris-api28|pulseaudio-modules-droid-jb2q)")"
echo "hwsm=$(getprop init.svc.hwservicemanager 2>/dev/null)"
echo "enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
# A service that failed once shows as stopped and is fine (LineageOS-only
# vendor services without a LineageOS system). One in a restart loop is
# not; the roadmap says list them and mask any that loop.
echo "looping=$(getprop 2>/dev/null | grep -c "^\[init\.svc\..*\]: \[restarting\]")"
```

No apostrophes in the block (the whole remote script is single-quoted).

- [ ] **Step 3: Checks**

After the `rootfs is grown past 8G` line (`:133`):

```bash
ck "container is running"          '[ "$(val container)" = active ]'
ck "container is the api33 GSI"    '[ "$(val sdk)" = 33 ]'
ck "vendor is Android 13 (api33)"  '[ "$(val vsdk)" = 33 ]'
ck "VNDK 33 on both sides"         '[ "$(val vndk)" = 33 ]'
ck "no api28 package remains"      '[ "$(val oldapi)" = 0 ]'
ck "hwservicemanager is running"   '[ "$(val hwsm)" = running ]'
ck "selinux stays permissive"      '[ "$(val enforce)" = 0 ]'
ck "no vendor service crash-loops" '[ "$(val looping)" = 0 ]'
```

- [ ] **Step 4: Suite, then the real device (expected to FAIL, that is the point)**

Run: `tests/run-tests.sh 2>&1 | tail -2`
Expected: `passed=165 failed=0` (the healthy fixture satisfies every new check).

Run: `./droidian/verify-device.sh 2>&1 | grep -E 'container|api33|Android 13|VNDK|api28|hwservice|selinux|crash-loop|ALL|FAILURES'`
Expected, on the phone as it is now (api28 rootfs): `container is running`
PASS, `container is the api33 GSI` FAIL (28), `vendor is Android 13` PASS,
`VNDK 33` FAIL (27), `no api28 package remains` FAIL, `no vendor service
crash-loops` FAIL (59). The checks measure what the facts said. Record
that line in the commit message: it is the baseline Task 6 flips.

- [ ] **Step 5: Commit**

```bash
git add droidian/verify-device.sh tests/fixtures/verify-healthy.txt
git commit -m "feat(verify): container invariants for the api33 userland

lxc@android active, container sdk 33, vendor sdk 33, VNDK 33 on both
sides, no api28 package, hwservicemanager running, SELinux still
permissive after Android init, no vendor service in a restart loop.
Baseline on the api28 install today: sdk 28, VNDK 27, 59 services
restarting."
```

---

### Task 6: Flash, bring the container up, and make the invariants hold

**Files:**
- Uses: `provision.sh`, `droidian/verify-device.sh`, `droidian/ssh.py -r`, `bin/device-ssh`
- Creates: `logs/halium-userland/` (gitignored, like `logs/lineage20/`)
- Possibly modify: `droidian/adaptation/adaptation-oneplus-fajita/usr/lib/adaptation-oneplus-fajita/apply` (Steps 4 and 5, only if the evidence says so)

**Interfaces:**
- Consumes: `droidian/linuxroot.simg` + `linuxroot.gsi` (Task 2),
  `droidian/out/images/boot.img` (Task 4), the eight checks (Task 5).

- [ ] **Step 1: Provision**

The phone is on slot b in the old Droidian (api28) with SSH up, or in
fastboot; `provision.sh` handles either. The probe will report
`pkg_android-system-gsi-28=...`, the manifest wants `-33`, so `data` runs;
the boot image changed, so `boot` runs; `activate` reboots.

If the artifacts were built on taichi (Task 2 note), prefix both commands
with `BUILD_HOST=taichi`; that is the existing seam and it fetches the
manifest and images from there.

```bash
./provision.sh --plan-only 2>&1 | tail -8      # expect: boot, data, activate
setsid nohup ./provision.sh > ~/provision.log 2>&1 < /dev/null &
bin/watch-log ~/provision.log --done 'verify:|ALL PASS|FAILURES' --fail 'died|failed to flash|TIMEOUT' --max 30 --stall 240
```

`provision.sh` ends with the `verify` phase, which runs
`droidian/verify-device.sh`. It WILL report `FAILURES` (phosh, GL) and
exit non-zero; that is expected at this phase. Read the check lines, not
the summary.

- [ ] **Step 2: Capture the first boot before touching anything**

```bash
mkdir -p logs/halium-userland
./droidian/verify-device.sh > logs/halium-userland/verify-first.txt 2>&1
./.venv/bin/python droidian/ssh.py -r 'journalctl -k -b -o short-monotonic --no-pager' > logs/halium-userland/dmesg-first.txt
./.venv/bin/python droidian/ssh.py -r 'journalctl -b -u lxc@android -o short-monotonic --no-pager' > logs/halium-userland/lxc-android-first.txt
bin/device-ssh 'getprop' > logs/halium-userland/getprop-first.txt
grep -E '\[restarting\]' logs/halium-userland/getprop-first.txt | sed 's/^\[init\.svc\.\([^]]*\)\].*/\1/' | sort > logs/halium-userland/restarting-first.txt
grep -cE 'Could not set context' logs/halium-userland/dmesg-first.txt
grep -E 'type=1404|SELinux:.*(policy|enforcing)' logs/halium-userland/dmesg-first.txt | head
grep -iE 'bpfloader' logs/halium-userland/dmesg-first.txt | tail -5
```

What the numbers mean:
- `Could not set context` count should be near 0 now (policy loaded, so
  labels apply). Thousands again means the policy did not load; read the
  `init:` lines around `SELinux` in dmesg for why.
- A `type=1404 ... enforcing=1` line with `enforce=1` from verify means
  the token did not reach init: check `bin/device-ssh 'cat /proc/cmdline'`
  contains `androidboot.selinux=permissive` (the host and the container see
  the same `/proc/cmdline`).
- `bpfloader` lines ending in `exited with status` followed by the
  container restarting: Step 4.

- [ ] **Step 3: Read the verify result against the exit criteria**

Expected PASS after this step, with no further change: every check that
passed on the api28 install (hostdev perms, polkit, clock floor, lxc mask,
chre, fastrpc, linuxroot invariants) plus `container is running`,
`container is the api33 GSI`, `vendor is Android 13`, `VNDK 33`,
`no api28 package remains`, `hwservicemanager is running`,
`selinux stays permissive`. Expected FAIL: `phosh active`,
`hardware GL (not pixman)` (Phase 5). Possibly FAIL:
`no vendor service crash-loops` (Step 5).

Anything else failing is a defect of this phase; stop and diagnose before
masking anything.

- [ ] **Step 4: Only if the container dies on bpfloader**

Symptom: `container=` not `active`, or `lxc@android` restarting, and
`init: Service bpfloader ... reboot_on_failure` in the container's log
(`logs/halium-userland/lxc-android-first.txt` or dmesg). Diagnose first:

```bash
bin/device-ssh 'sudo -n lxc-attach -n android -- /system/bin/logcat -d -s bpfloader:* LibBpfLoader:* 2>/dev/null | tail -30' || \
./.venv/bin/python droidian/ssh.py -r 'lxc-attach -n android -- /system/bin/logcat -d -s bpfloader:* LibBpfLoader:* | tail -30'
```

If the failure is the kernel (a verifier rejection, `unsupported helper`,
`too old`), the fix is NOT a config change in this phase: netd's bpf is
an Android feature Droidian does not use. Mask the reboot with the same
technique as `init.qcom.rc`, in `apply`, after the chre block:

```bash
# bpfloader: Android 13's bpfloader.rc reboots the system when the loader
# fails; inside the container that kills the container's init on every
# start. Droidian never uses netd's bpf programs. Drop the reboot_on_failure
# line and let the service fail like any other.
BPF_RC="$LXC_DIR/rootfs/system/etc/init/bpfloader.rc"
BPF_OVERRIDE="$LXC_DIR/bpfloader.rc"
BPF_ENTRY="lxc.mount.entry = $BPF_OVERRIDE system/etc/init/bpfloader.rc none bind,ro 0 0"
if [ -f "$BPF_RC" ] && [ -f "$LXC_DIR/config" ] && grep -q '^    reboot_on_failure' "$BPF_RC"; then
    sed '/^    reboot_on_failure/d' "$BPF_RC" > "$BPF_OVERRIDE.tmp" && mv "$BPF_OVERRIDE.tmp" "$BPF_OVERRIDE"
    echo "adaptation-oneplus-fajita: wrote $BPF_OVERRIDE (no reboot on bpfloader failure)"
    if ! grep -qF "bpfloader.rc" "$LXC_DIR/config"; then
        printf '%s\n' "$BPF_ENTRY" >> "$LXC_DIR/config"
        echo "adaptation-oneplus-fajita: bound patched bpfloader.rc into the container"
    fi
fi
```

Add a case to the Task 1 test block (fixture `rootfs/system/etc/init/bpfloader.rc`
with a `    reboot_on_failure reboot,bpfloader-failed` line; assert the
override lacks it and `config` has the bind), bump the package to
`1.13.0`, rebuild (`./build.sh adaptation rootfs`), re-provision (the
adaptation version changed, so `data` runs again), re-capture as Step 2
with `-second` suffixes. Commit:

```bash
git commit -am "fix(adaptation): do not let bpfloader take the container down

Android 13's bpfloader.rc carries reboot_on_failure; on this kernel the
loader exits 2 and the container's init reboots itself on every start.
Bind a copy without that line, same technique as init.qcom.rc."
```

- [ ] **Step 5: Vendor services in a restart loop**

`logs/halium-userland/restarting-first.txt` is the list. For each name,
find its rc file in the vendor:

```bash
for s in $(cat logs/halium-userland/restarting-first.txt); do
    printf '%-32s %s\n' "$s" "$(bin/device-ssh "grep -lE '^service $s ' /var/lib/lxc/android/rootfs/vendor/etc/init/*.rc /var/lib/lxc/android/rootfs/vendor/etc/init/hw/*.rc 2>/dev/null | head -1")"
done | tee logs/halium-userland/restarting-rc.txt
```

Classify from the roadmap's list and from what the service is: expected
harmless failures are LineageOS-only services that need a LineageOS
`system` (`vendor.oneplus.*`, `livedisplay`, `pocketmode`, the udfps
extension, `vendor.lineage.*`). A LineageOS-only service that merely
FAILS (state `stopped`) needs nothing. One that LOOPS gets masked by
binding an empty file over its rc, generalising the `apply` pattern:

```bash
# LineageOS-only vendor services that expect a LineageOS system and
# restart forever inside the GSI. One rc file each, bound empty. The list
# is evidence from logs/halium-userland/restarting-rc.txt; every entry
# names why in the commit that added it.
MASK_RCS="${AOF_MASK_RCS:-}"   # space-separated paths under rootfs/vendor/etc/init, set below
MASK_RCS="init/vendor.oneplus.example.rc"
for rc in $MASK_RCS; do
    src="$LXC_DIR/rootfs/vendor/etc/$rc"
    [ -f "$src" ] || continue
    entry="lxc.mount.entry = /dev/null vendor/etc/$rc none bind,ro 0 0"
    if ! grep -qF " vendor/etc/$rc " "$LXC_DIR/config"; then
        printf '%s\n' "$entry" >> "$LXC_DIR/config"
        echo "adaptation-oneplus-fajita: masked $rc"
    fi
done
```

Replace the example path with the real list from the evidence, one
`MASK_RCS` line, no env override (delete the `AOF_MASK_RCS` line; it is
shown only so the Task 1 test harness can exercise the loop with a
fixture path if you want a test: `AOF_MASK_RCS="init/fake.rc"` with the
fixture file present, assert the bind line). Bind-mounting `/dev/null`
over a regular file is a file-on-file bind; Android's init parses an empty
rc without complaint. Do NOT mask anything Droidian needs
(`hwservicemanager`, `vndservicemanager`, `vendor.qcrild*`, audio, camera,
sensors, wifi, gnss, bluetooth HALs). If one of those loops, that is a
defect to diagnose, not to mask.

Version bump, rebuild adaptation + rootfs, re-provision, re-capture,
verify until `no vendor service crash-loops` PASSes. Commit with the list
and one reason per entry.

- [ ] **Step 6: Final evidence**

```bash
./droidian/verify-device.sh | tee logs/halium-userland/verify-final.txt
bin/device-ssh 'dpkg -l | grep -cE "api28|gsi-28|jb2q"'                      # expect 0
bin/device-ssh 'getprop ro.build.version.sdk ro.vndk.version'                # 33 / 33
for s in ipa_fws adsp cdsp slpi modem venus; do printf '%-8s %s\n' $s "$(grep -c "$s.*loading from 0x" logs/halium-userland/dmesg-first.txt)"; done
```

The PIL line is informational: with the api33 GSI's vendor userspace
running, `modem` should now load (it is triggered by `rmt_storage`/RIL).
If it does not, note it for Phase 5's modem row; it is not an exit
criterion here.

Exit criteria for this task (from the roadmap): `verify-device.sh` passes
every check except `phosh active` and `hardware GL (not pixman)`, and
`dpkg -l` shows no api28 package.

---

### Task 7: Record the result

**Files:**
- Modify: `docs/plans/2026-09-06-los20-port-roadmap.md` (Phase 4 status), this file (ticks)

- [ ] **Step 1: Roadmap**

Phase 4 `**Status:**` -> `done (<date>). Detailed plan: docs/plans/2026-09-06-los20-userland.md.`
followed by an `**Exit evidence**` list in the style of Phases 1-3: the
verify line counts (`N PASS, 2 expected FAIL`), the container props, the
masked services with reasons, the SELinux outcome, and whether `modem`
loaded. Under `**Learned the hard way**`: the mtime override bug, the
bpfloader outcome, anything else that cost more than an hour.

- [ ] **Step 2: Commit**

```bash
git add docs/plans/2026-09-06-los20-port-roadmap.md docs/plans/2026-09-06-los20-userland.md
git commit -m "docs: Phase 4 done; api33 container up on the LineageOS 20 vendor"
git push origin los20-port
```

---

## Deliberately not in this plan

- Display, phosh, or any peripheral (Phase 5). `phosh active` and
  `hardware GL` are expected failures at the end of this phase.
- Reconciling or deleting the `ro.build.shutdown_timeout` override
  (LineageOS 20 has no such line, so it is a no-op copy). Phase 6 decides.
- The `lineage` target in `build.sh`, one place for kernel version / rootfs
  API / camera pin (Phase 7). This plan adds the GSI sidecar, which is the
  fact Phase 7 will read.
- README's "requires Android 9" section (Phase 7).
- The camera re-pin: verified unnecessary (`a0b51cd` on both sides).
- Making the api28 rootfs still buildable: `API=28 ./droidian/build-rootfs.sh`
  still works by construction; nothing asserts it.

## Self-review against the roadmap's Phase 4

| Roadmap item | Task |
|---|---|
| 1. `build-rootfs.sh` default `API=33`; confirm `setup.sh`, journal, symlink unchanged | Task 2 (Steps 1-3; setup.sh verified identical, asserted in-build) |
| 2. Re-pin `CAMERA_COMMIT` to the api33 rootfs's droidian-camera | Verified equal (`a0b51cd`); no change. Facts section. |
| 3. Adaptation `Depends` name no API | Verified: none do (Task 1 touches `apply`, not `Depends`) |
| 4. `lxc@android` active, binder nodes, vendor props, hwservicemanager lists HALs | Task 5 checks + Task 6 Steps 1-3 |
| 5. LineageOS-only services fail harmlessly; list them; mask crash-loopers | Task 6 Step 5 |
| Exit: verify passes every non-display, non-peripheral check | Task 6 Step 6 |
| Exit: `dpkg -l` shows no api28 package | Task 5 `oldapi` check + Task 6 Step 6 |
| Risk: SELinux / cmdline carries what the initramfs expects | Task 4 (bootloader-tested), Task 5 `enforce` check |
| Not in roadmap, found while planning: stale overrides by mtime | Task 1 |
| Not in roadmap, found while planning: pipeline blind to a GSI swap | Task 3 |
| Not in roadmap, found while planning: bpfloader `reboot_on_failure` in the GSI | Task 6 Step 4 |
