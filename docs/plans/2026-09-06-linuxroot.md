# Move Droidian onto `linuxroot` (Phase 1 of the LineageOS 20 roadmap)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Droidian boots from and stores its data on the `linuxroot`
partition, leaving `userdata` entirely to Android, so that flashing and
booting LineageOS 20 on the other slot cannot touch the Droidian install.

**Architecture:** the Halium initramfs already honours a `datapart=<path>`
kernel cmdline override (`scripts/halium` line 717 in our own `boot.img`),
and its `resize_userdata_if_needed` grows the filesystem to the partition
when the path is of the form `/dev/disk/*`. So the whole mechanism is one
cmdline token plus flashing the rootfs image to `linuxroot` instead of
`userdata`. Everything else in this plan is the pipeline (probe, skip
logic, tests, verify) learning the new fact so it cannot silently flash the
old way.

**Tech Stack:** bash, `fastboot`, the existing `tests/run-tests.sh` harness
(fake `fastboot`/`device-ssh` in `tests/fixtures/bin`), Droidian kernel
packaging (`kernel-info.mk`), `BUILD_HOST=taichi ./provision.sh`.

## Global Constraints

- Nothing in this plan touches the GPT. `linuxroot` = sda18 already exists
  (114.6 GiB, 123027304448 bytes), created by `LAYOUT=dualboot`.
- Droidian runs on slot `a`; `boot_b` holds the stock OOS 9 kernel
  (sha256 of its first 33136640 bytes = `4b0433089f59fabc...`, matching
  `releases/oos9/images/boot.img`). Do not flash slot `b`.
- `fastboot -w` bootloops this device. Never use it.
- The baseline suite is `passed=143 failed=0`. Every task ends with the
  suite green and the count going up, never down.
- Conventional commits, one task per commit, no AI attribution.

## Facts this plan relies on (verified 2026-09-06)

- On the device: `/userdata` is `/dev/sda17` (partlabel `userdata`),
  8.8 GB filesystem on a 114.6 GiB partition, containing `rootfs.img`
  (8 GiB), `android-data/`, and the `android-rootfs.img` symlink.
  `/dev/sda18` (`linuxroot`) is empty. `/proc/cmdline` has no `datapart=`.
- `resize_userdata_if_needed` in the initramfs skipped on every boot so far
  because the auto-found path is `/dev/sda17`, which matches neither of its
  `case` arms (`/dev/mmcblk*`, `/dev/disk*`). `datapart=/dev/disk/by-partlabel/linuxroot`
  matches the second arm, so the outer filesystem will be grown on first
  boot without any code of ours.
- `droidian.lvm.prefer` on the cmdline is harmless: `vgscan` finds no VG,
  `use_lvm` is unset, and the script falls through to `$path`.
- `provision.sh` runs phases in the order edl, boot, data, activate. A
  single run therefore flashes the new kernel (with `datapart=`) and the
  rootfs to `linuxroot` before rebooting, so there is no state where the
  new kernel boots against an empty `linuxroot`, PROVIDED the data phase is
  not skipped. Today `skip_data` skips when every package version matches,
  which would be exactly the case here. Task 2 closes that hole.

---
### Task 1: The probe reports which partition Droidian's data is on

**Files:**
- Modify: `lib/probe.sh` (`ssh_blob`, `probe_all`)
- Modify: `tests/fixtures/probe-droidian.txt`
- Test: `tests/run-tests.sh` (the `lib/probe.sh tests` block)

**Interfaces:**
- Produces: a new probe fact `data_part=<partlabel|unknown>`, read by
  Task 2's `skip_data` and by nothing else.

- [ ] **Step 1: Write the failing tests**

In `tests/run-tests.sh`, after the line
`expect_contains "linuxroot is detected"     /tmp/p-dro.$$ 'has_linuxroot=yes'`,
add:

```bash
expect_contains "the data partition is named" /tmp/p-dro.$$ 'data_part=userdata'

# A probe whose datapart section is missing must say unknown, not guess.
sed '/^--- datapart$/,/^--- /{/^--- datapart$/d;/^--- /!d}' \
    "$ROOT/tests/fixtures/probe-droidian.txt" > /tmp/f-nodp.$$
PROBE_STATE=droidian PROBE_SSH_FIXTURE=/tmp/f-nodp.$$ \
    bash "$PROBE" probe_all > /tmp/p-nodp.$$ 2>&1
expect_contains "an unreadable data partition is unknown" /tmp/p-nodp.$$ 'data_part=unknown'
rm -f /tmp/f-nodp.$$ /tmp/p-nodp.$$
```

- [ ] **Step 2: Run the suite to see them fail**

Run: `./tests/run-tests.sh 2>&1 | grep -E 'FAIL|passed='`
Expected: the two new checks FAIL; `passed=143 failed=2`.

- [ ] **Step 3: Add the section to the fixture**

`tests/fixtures/probe-droidian.txt`: insert before `--- partlabels`:

```
--- datapart
userdata
```

- [ ] **Step 4: Emit the fact**

`lib/probe.sh`, in `ssh_blob`, extend the remote command. After
`echo "--- slot"; sed -n ...;` and before `echo "--- partlabels"`, add:

```
echo "--- datapart"; lsblk -no PARTLABEL "$(findmnt -no SOURCE /userdata 2>/dev/null)" 2>/dev/null;
```

In `probe_all`, declare `dp=unknown` alongside `slot=unknown ...`, and in the
`droidian)` arm after the `labels=` block:

```bash
            # Which partition Droidian booted its data from. "userdata" means
            # the install is not yet on linuxroot and the data phase must run
            # regardless of package versions (lib/phases.sh skip_data).
            dp=$(section datapart <<<"$blob" | head -1)
```

and among the final `emit` lines:

```bash
    emit data_part      "${dp:-unknown}"
```

- [ ] **Step 5: Run the suite**

Run: `./tests/run-tests.sh 2>&1 | tail -1`
Expected: `passed=145 failed=0`.

- [ ] **Step 6: Commit**

```bash
git add lib/probe.sh tests/fixtures/probe-droidian.txt tests/run-tests.sh
git commit -m "feat(probe): report which partition holds the Droidian data"
```

---

### Task 2: The data phase never skips while Droidian is still on `userdata`

**Files:**
- Modify: `lib/phases.sh` (`skip_data`)
- Test: `tests/run-tests.sh` (the flash-phase and quiet-run blocks)

**Interfaces:**
- Consumes: `data_part=` from Task 1.

- [ ] **Step 1: Write the failing test**

In `tests/run-tests.sh`, directly after the "Flash phases: data phase
flashes userdata" block (the one that writes `/tmp/pr-flash-data.$$`), add:

```bash
# Matching package versions are not a reason to skip while the install is
# still on userdata: the whole point of the data phase is to move it.
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=userdata\npkg_droidian-camera=2.0.0\npkg_adaptation-oneplus-fajita=1.0.0\n' > /tmp/pr-move.$$
mkdir -p /tmp/artifacts-test/droidian
touch /tmp/artifacts-test/droidian/linuxroot.simg
timeout 10 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-move.$$ --manifest "$ROOT/tests/fixtures/manifest.json" --phase data > /tmp/p-move.$$ 2>&1; rc=$?
expect_contains "data runs when the install is still on userdata" /tmp/p-move.$$ 'data: installing rootfs'
printf 'state=droidian\nprobe_complete=yes\nvendor_fp=x\ndata_part=linuxroot\npkg_droidian-camera=1.0.0\npkg_adaptation-oneplus-fajita=1.0.0\npkg_halium-hostdev-perms=1.0.0\n' > /tmp/pr-stay.$$
timeout 10 "$PROV" --yes --artifacts /tmp/artifacts-test --probe-file /tmp/pr-stay.$$ --manifest "$ROOT/tests/fixtures/manifest.json" --phase data > /tmp/p-stay.$$ 2>&1; rc=$?
expect_contains "data skips once the install is on linuxroot" /tmp/p-stay.$$ 'data: skipped'
rm -rf /tmp/artifacts-test /tmp/pr-move.$$ /tmp/p-move.$$ /tmp/pr-stay.$$ /tmp/p-stay.$$
```

Note the artifact is already named `linuxroot.simg`; Task 3 renames it.
Until then this block will fail on the missing file, which is fine: the
suite must be green again only at the end of Task 3.

- [ ] **Step 2: Gate `skip_data`**

`lib/phases.sh`, first lines of `skip_data` after `local ...`:

```bash
    # The install has to be on linuxroot before package versions mean
    # anything. "unknown" is not evidence either way, and the safe direction
    # here is to run: a needless rootfs flash costs minutes, a skipped move
    # leaves Droidian sitting in the partition Android is about to format.
    [ "$(grep '^data_part=' "$probe" | cut -d= -f2)" = linuxroot ] || return 1
```

- [ ] **Step 3: Fix existing fixtures that now need the fact**

Every probe file in `tests/run-tests.sh` that expects the data phase to be
skipped must now carry `data_part=linuxroot`. Find them with
`grep -n "pkg_adaptation-oneplus-fajita=1.0.0" tests/run-tests.sh` and add
`data_part=linuxroot\n` to the ones whose assertion is a skip or "does not
ask" (the `pr-quiet` block is one). Probe files whose assertion is that data
runs need no change.

- [ ] **Step 4: Run the suite**

Run: `./tests/run-tests.sh 2>&1 | grep -E 'FAIL|passed='`
Expected: only the two new Task 2 checks may still fail (missing
`linuxroot.simg`); every pre-existing check passes.

- [ ] **Step 5: Commit**

```bash
git add lib/phases.sh tests/run-tests.sh
git commit -m "fix(phases): never skip the data phase while Droidian is on userdata"
```

---
### Task 3: Flash `linuxroot`, never `userdata`

**Files:**
- Modify: `provision.sh:150` (`ROOTFS_IMG`), `provision.sh:387-399` (data phase)
- Modify: `droidian/flash.sh:26-48`
- Modify: `droidian/build-rootfs.sh:40-41` (`OUT`, `SPARSE`), header comment
- Modify: `build.sh:32` (rootfs target artifact paths)
- Modify: `tests/run-tests.sh` (every `userdata.simg` / `userdata.img` /
  `fastboot flash userdata` mention), `tests/fixtures/manifest.json`
- Modify: `.gitignore` if it names `droidian/userdata.*`

**Interfaces:**
- Produces: artifacts `droidian/linuxroot.img` and `droidian/linuxroot.simg`;
  `manifest.json` keys of the same names under target `rootfs`.

- [ ] **Step 1: Rename the artifact everywhere**

`sed -n` first to see every site, then edit by hand (not a blind `sed -i`,
the word `userdata` also appears in comments that describe Android's
partition and must stay):

```bash
grep -n 'userdata' provision.sh build.sh droidian/build-rootfs.sh droidian/flash.sh tests/run-tests.sh tests/fixtures/manifest.json .gitignore
```

- `provision.sh:150`: `ROOTFS_IMG="droidian/linuxroot.simg"`.
- `provision.sh` data phase: variable `userdata_img` -> `rootfs_img`; the two
  `echo`s say `linuxroot`; the flash line becomes
  `fastboot flash linuxroot "$rootfs_img" || die "failed to flash linuxroot"`.
- `droidian/flash.sh`: `USERDATA=` -> `ROOTFS="$HERE/linuxroot.img"`, the
  flash line `fastboot flash linuxroot "$ROOTFS"`, the header comment
  explains that Android owns `userdata`.
- `droidian/build-rootfs.sh`: `OUT="$HERE/linuxroot.img"`,
  `SPARSE="$HERE/linuxroot.simg"`; header comment: "ready for
  `fastboot flash linuxroot`". Add, in the pack section, a comment that the
  image is 9 GiB and the initramfs grows it to the partition on first boot
  because the cmdline names the partition by `/dev/disk/by-partlabel/`
  (see `resize_userdata_if_needed` in `scripts/halium`).
- `build.sh:32`: `droidian/linuxroot.img droidian/linuxroot.simg`.
- `tests/fixtures/manifest.json`: rename the two artifact keys.
- `tests/run-tests.sh`: rename every fixture touch and assertion string;
  the `'fastboot flash userdata'` assertion becomes
  `'fastboot flash linuxroot'`, and directly under it add
  `expect_absent "userdata is never flashed" "$HW_LOG" 'fastboot flash userdata'`.
- `.gitignore`: same rename if present.

- [ ] **Step 2: Run the suite**

Run: `./tests/run-tests.sh 2>&1 | grep -E 'FAIL|passed='`
Expected: `passed=148 failed=0` (143 + 2 from Task 1 + 2 from Task 2 + 1
`expect_absent`).

- [ ] **Step 3: Commit**

```bash
git add provision.sh build.sh droidian/build-rootfs.sh droidian/flash.sh tests/ .gitignore
git commit -m "feat(provision): flash the Droidian rootfs to linuxroot"
```

---

### Task 4: The kernel tells the initramfs where the data lives

**Files:**
- Modify: `droidian/packaging/debian/kernel-info.mk:14` (`KERNEL_BOOTIMAGE_CMDLINE`)

**Interfaces:**
- Produces: `boot.img` whose cmdline ends with
  `datapart=/dev/disk/by-partlabel/linuxroot`.

- [ ] **Step 1: Append the token**

Append ` datapart=/dev/disk/by-partlabel/linuxroot` to the end of the
`KERNEL_BOOTIMAGE_CMDLINE` value. Above the line add:

```
# datapart= is honoured by the halium initramfs (scripts/halium) after its own
# userdata search. The /dev/disk/ form matters: resize_userdata_if_needed only
# grows the filesystem to the partition for /dev/mmcblk* and /dev/disk* paths,
# and the auto-found /dev/sdaN matched neither, which is why /userdata stayed
# at 8.8 GB on a 114 GiB partition. Android keeps userdata; Droidian owns
# linuxroot; see docs/plans/2026-09-06-linuxroot.md.
```

- [ ] **Step 2: Assert it from the built image, not the source**

Add to `tests/run-tests.sh`, in the build-side block (near the manifest
tests), a check that reads the cmdline from `kernel-info.mk` the way the
packaging does and asserts the token is present, so a future edit cannot
drop it silently:

```bash
expect_pred "the kernel cmdline points the initramfs at linuxroot" \
    "grep -q '^KERNEL_BOOTIMAGE_CMDLINE = .* datapart=/dev/disk/by-partlabel/linuxroot' '$ROOT/droidian/packaging/debian/kernel-info.mk'"
```

- [ ] **Step 3: Run the suite**

Run: `./tests/run-tests.sh 2>&1 | tail -1`
Expected: `passed=149 failed=0`.

- [ ] **Step 4: Commit**

```bash
git add droidian/packaging/debian/kernel-info.mk tests/run-tests.sh
git commit -m "feat(kernel): boot Droidian from linuxroot via datapart="
```

---

### Task 5: `verify-device.sh` proves it

**Files:**
- Modify: `droidian/verify-device.sh` (remote block and `ck` list)
- Modify: `tests/fixtures/verify-healthy.txt`

- [ ] **Step 1: Add the measurements to the remote block**

After the `echo "epoch=..."` line (no apostrophes; the block is
single-quoted end to end):

```bash
DP=$(findmnt -no SOURCE /userdata 2>/dev/null)
echo "datapart=$(lsblk -no PARTLABEL "$DP" 2>/dev/null)"
# Difference between partition and filesystem, in 4k blocks. The initramfs
# grows the fs when the gap exceeds 10000 1k-blocks, so anything under 2500
# here means it did its job.
echo "datafill=$(( $(blockdev --getsize64 "$DP" 2>/dev/null || echo 0) / 4096 - $(dumpe2fs -h "$DP" 2>/dev/null | awk "/^Block count/{print \$3}") ))"
echo "udmounts=$(findmnt -no TARGET /dev/disk/by-partlabel/userdata 2>/dev/null | wc -l)"
```

- [ ] **Step 2: Add the checks**

```bash
ck "droidian data is on linuxroot"   '[ "$(val datapart)" = linuxroot ]'
ck "data fs fills linuxroot"         '[ "$(val datafill)" -lt 2500 ] 2>/dev/null'
ck "userdata is left to Android"     '[ "$(val udmounts)" = 0 ]'
```

- [ ] **Step 3: Fixture**

Append to `tests/fixtures/verify-healthy.txt`:

```
datapart=linuxroot
datafill=0
udmounts=0
```

- [ ] **Step 4: Run the suite**

Run: `./tests/run-tests.sh 2>&1 | tail -1`
Expected: `passed=149 failed=0` (the verify fixture feeds existing tests;
no new count, but a missing key would have failed them).

- [ ] **Step 5: Commit**

```bash
git add droidian/verify-device.sh tests/fixtures/verify-healthy.txt
git commit -m "feat(verify): assert Droidian lives on linuxroot"
```

---

### Task 6: Flash it and round-trip both slots

No code. This is the acceptance test on hardware.

- [ ] **Step 1: Build on taichi and flash**

```bash
BUILD_HOST=taichi ./provision.sh
```

Expected in the output: the boot phase flashes `boot_a` and `vbmeta_a`
(the cmdline changed, so the hash differs); the data phase says
`data: flashing linuxroot`; the activate phase reports the phone left the
bootloader. The `data` phase must NOT be skipped; if it is, Task 2 is wrong.

- [ ] **Step 2: Verify**

```bash
./droidian/verify-device.sh
./droidian/ssh.py -r 'grep -o "datapart=[^ ]*" /proc/cmdline; findmnt -no SOURCE,SIZE /userdata; dmesg | grep -i "resized userdata"'
```

Expected: `ALL PASS`; `datapart=/dev/disk/by-partlabel/linuxroot`;
`/dev/sda18` with a size in the 114 GiB range; the initramfs's
"resized userdata filesystem" line.

- [ ] **Step 3: Round trip**

```bash
./bin/device-goto fastboot && fastboot set_active b && fastboot reboot
```

Before rebooting into slot b, give Android a partition it accepts. It does
NOT format a foreign `userdata` on its own: with the Droidian-built ext4
still there, OxygenOS spun on the boot animation indefinitely and wrote
nothing to the partition (verified by mounting it read-only afterwards).

```bash
fastboot format:ext4 userdata     # the type OOS 9's fstab.qcom declares; never -w
fastboot set_active b && fastboot reboot
```

Wait for OxygenOS 9 to reach its setup wizard (about a minute). Then:

```bash
./bin/device-goto fastboot && fastboot set_active a && fastboot reboot
./droidian/verify-device.sh
```

Expected: Droidian boots unchanged, `ALL PASS` again, and
`ls /userdata` still shows `rootfs.img` and `android-data`. That round
trip is the definition of "the dual boot is real".

- [ ] **Step 4: Record**

Append the verify output and the `findmnt` line to the roadmap under
Phase 1 as the exit evidence, mark the phase `done`, and commit:

```bash
git add docs/plans/2026-09-06-los20-port-roadmap.md
git commit -m "docs(roadmap): phase 1 done, Droidian on linuxroot"
```

---

## Deliberately not in this plan

- Growing `rootfs.img` beyond 8 GiB to use the 114 GiB partition. The
  outer filesystem now fills the partition; the inner image can be grown
  online later (`truncate` + `losetup -c` + `resize2fs` on the loop device)
  from a first-boot unit in `adaptation-oneplus-fajita`. Not needed to
  unblock the LineageOS build; add when someone actually runs out of the
  8 GiB.
- Any change to the GPT, the OOS 9 slot, or `restore-android.py`.
