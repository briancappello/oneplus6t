# LineageOS 20 + Droidian Port Roadmap (plan of plans)

**Branch:** `los20-port`

**Goal:** Move the working Droidian build for the OnePlus 6T (fajita) off the
OxygenOS 9.0.17 vendor (Android 9, api28, kernel 4.9.113) onto a LineageOS 20
base (Android 13, api33, kernel 4.9.337), reaching at least feature parity
with the OOS 9 build: boot, phosh, SSH, modem, WiFi, audio, sensors, camera,
and a clean shutdown. The other A/B slot boots LineageOS 20 itself, replacing
OxygenOS as the Android fallback.

**Target layout:** a true dual boot. LineageOS 20 owns `userdata`; Droidian
owns `linuxroot`; the two are a ~50/50 split of the user-data region (114.6
GiB each on this 256 GB unit). Neither OS can touch the other's data. The GPT
for this already exists (`LAYOUT=dualboot` in `restore-android.py`, verified
on hardware); what is missing is Droidian actually living on `linuxroot`.

**Shape of the work:** Droidian never runs LineageOS's `system`. The device
contributes a kernel and a `vendor` partition; the Android container runs
Droidian's Halium GSI (`android-system-gsi-33`, which is UBports' halium-13.0
image and is itself derived from LineageOS 20). So the stack is:

```
 kernel   LineageOS lineage-20 sdm845 kernel (4.9.337) + Halium config delta
 vendor   vendor.img as built by LineageOS 20 (OOS 11.1.2.2 blobs, VNDK 33)
 system   android-system-gsi-33 inside the lxc container (VNDK 33)
 rootfs   droidian rootfs-api33 + adaptation-hybris-api33-phone
```

Kernel, vendor, and GSI form one matched set and move together. The rest of
this repo (provisioning, adaptation packages, tracing tools) is either
release-agnostic already or needs re-validation rather than rewriting.

**Machines:** the workstation (`p1`) drives the phone; builds run on
`taichi` (32 threads, 91 GB RAM, `/home` on NVMe with ~190 GB free, an 8 TB
SMR spinning disk at `/opt/models`). `BUILD_HOST=taichi ./provision.sh` is the
existing seam and stays the seam.

**Status vocabulary:** each phase is `not started`, `in progress`, `done`, or
`blocked`. Each phase gets its own detailed plan in `docs/plans/` when it is
about to start, written with the same task/step structure as
`2026-09-04-adaptation-packages.md`. This file only fixes the phases, their
order, their exit criteria, and what is known going in.

**Research baseline:** every fact below was verified on 2026-09-06 against the
payloads in `releases/oos{9,11}/images/`, the running device, the LineageOS
and Droidian repositories, and taichi. Engram observations #714 (OOS 11
findings) and #716 (LineageOS 20 findings) hold the raw notes.

---

## What does NOT change

Settled facts; no phase should re-open them.

| Item | Finding |
|---|---|
| Partition layout | LineageOS 20 sdm845-common: `AB_OTA_PARTITIONS = boot dtbo system vbmeta vendor`. No `super`, no dynamic partitions. `BOARD_SYSTEMIMAGE_PARTITION_SIZE 2998927360`, `BOARD_VENDORIMAGE_PARTITION_SIZE 1073741824`: byte-identical to stock. `restore-android.py` and the dual-boot GPT are unaffected. |
| Dual-boot GPT | Already on the phone: `userdata` = sda17 (114.6 GiB), `linuxroot` = sda18 (114.6 GiB), split 50/50 by `LAYOUT=dualboot`, nothing else moved, asserted by `restore-android.py`. Nothing in any Android fstab names `linuxroot`. |
| Data-partition override | The Halium initramfs (`scripts/halium`, `linux-initramfs-halium-generic`) honours `datapart=<path>` on the kernel cmdline after its own `userdata` search, and runs udev, so `datapart=/dev/disk/by-partlabel/linuxroot` is sufficient. Verified by reading the ramdisk out of our current `boot.img`. |
| boot.img format | `BOARD_BOOT_HEADER_VERSION 1`, page 4096, `Image.gz-dtb`, `BOARD_KERNEL_SEPARATED_DTBO`, system-as-root, recovery-as-boot. Same kernel cmdline as stock. The empty-vbmeta approach stays. |
| dtbo | Droidian reuses the on-device `dtbo`. With LineageOS 20 flashed that is LineageOS's, built from the same kernel tree we build Droidian's kernel from. Do not erase it. |
| Firmware | LineageOS wiki: fajita needs stock Android 11 firmware (`needs_specific_android_fw`, version 11). `RELEASE=oos11 restore-android.py` already provides it. |
| Blobs | TheMuppets `lineage-20` blobs are extracted from `OnePlus6Oxygen_22.J.62`, the OnePlus 6 twin of the `34.J.62` (OOS 11.1.2.2) payload already in `releases/oos11`. |
| Camera HAL | `android.hardware.camera.provider` 2.4, unchanged since OOS 9. LineageOS 20 camera is officially working on fajita with these blobs. |
| Toolchain | LineageOS 20 builds the kernel with AOSP clang r450784; Droidian's build-essential ships `clang-android-14.0-r450784d`. |
| Upstream Droidian | `android-system-gsi-33` (13.0.0+r47.20250407.ubports.517), `adaptation-hybris-api33-phone`, `adaptation-hybris-api33`, `droidian-quirks-api33`, `pulseaudio-modules-droid-modern`, and the `rootfs-api33` release zip all exist in the `rolling` suite. |
| Ceiling | api33 is the practical ceiling: `android-system-gsi-34` and `adaptation-hybris-api34-phone` exist, but no `rootfs-api34` release asset does. LineageOS 22.2 (VNDK 35) cannot pair with gsi-33. LineageOS 21 + gsi-34 is a future option, not a today option. |
| Prior art | None above Halium 9. `ubports-oneplus6` is frozen at `halium-9.0` / `lineage-16.0` (2022). Nothing for Halium 10-13 on enchilada, fajita, or sdm845 anywhere on GitHub. This port is first-of-kind at this API level. |

---
## Phase 0: Baseline and safety net

**Status:** not started

**Why first:** the OOS 9 build is stable and must stay reachable at every
point of this work. Every later phase compares against numbers recorded here.

**Deliverables**
- A tag on `main` (`oos9-stable`) that reproduces the current working image
  from `./build.sh` alone. taichi's checkout is currently on `main` at
  `35d4d17`, behind origin; bring it to the tag first.
- A recorded OOS 9 baseline in `logs/baseline-oos9/`: `verify-device.sh`
  output (19/19 PASS), boot time, screen-on and screen-off shutdown times
  from `droidian/shutdown-trace.sh`, and `dpkg -l` of every `hybris` /
  `halium` / `adaptation` package.
- Slot discipline written down: OOS 9 + Droidian stays on its current slot
  until Phase 5 exits; LineageOS 20 and the new Droidian go on the other slot,
  so `fastboot set_active` is the rollback.
- The old OOS 11 route, kept as an appendix at the bottom of this file, in
  case the LineageOS route stalls at Phase 2 or 3.

**Exit criteria**
- `git checkout oos9-stable && BUILD_HOST=taichi ./provision.sh --plan-only`
  reports nothing to build against the running phone.
- The baseline numbers exist (gitignored logs are fine; the summary table is
  committed under this phase).

**Detailed plan:** none needed; this is a checklist.

---

## Phase 1: Move Droidian onto `linuxroot`

**Status:** done (2026-09-06). Detailed plan: `docs/plans/2026-09-06-linuxroot.md`.

**Exit evidence**
- `/proc/cmdline` carries `datapart=/dev/disk/by-partlabel/linuxroot`;
  `/userdata` is `/dev/disk/by-partlabel/linuxroot`, 115G, grown by the
  initramfs on first boot (`initrd: resized userdata filesystem to fill
  /dev/disk/by-partlabel/linuxroot`, and `e2fsck` now actually runs:
  `data: clean, 13/589824 files`).
- `verify-device.sh` ALL PASS, 25 checks, including the three new ones:
  `droidian data is on linuxroot`, `data fs fills linuxroot` (99%),
  `userdata is left to Android`.
- Round trip: `set_active b` boots OxygenOS 9.0.17 to its setup wizard with
  `/data` = sda17 (`userdata`), 112G, file-encrypted; `set_active a` boots
  Droidian in 30 s, ALL PASS again, `linuxroot` contents unchanged.

**Learned the hard way, now in the plan**
- Android does NOT format a foreign `userdata` on first boot; it hangs on the
  boot animation forever, writing nothing. `fastboot format:ext4 userdata`
  (never `-w`) before the first Android boot after the move. Phase 2 must do
  the same before LineageOS's first boot.
- The halium initramfs ships e2fsprogs 1.43.4 (2017). Images made by a 2025
  `mke2fs` carry `orphan_file`, which it refuses, so the outer filesystem was
  never fsck'd and never grown on any boot before today. `build-rootfs.sh`
  now builds with `-O ^orphan_file` and asserts it.
- `provision.sh` gained `FORCE=1` (rebuild and reflash boot+data, never edl),
  sha-checks an on-disk rootfs against the manifest before reusing it, and
  tolerates an empty plan with `BUILD_HOST`. `device.sh` bounds
  `fastboot reboot`. Suite 143 -> 162.
- Do not edit a script while it is running; bash reads it incrementally.

**Why before anything else:** today Droidian is flashed to `userdata`
(sda17, mounted at `/userdata`, rootfs.img inside it) and `linuxroot`
(sda18) is empty. The kernel cmdline carries no `datapart=`. That is not a
dual boot: the moment LineageOS boots it formats `userdata` as its `/data`
and the Droidian install is gone. This phase is independent of the
LineageOS work and lands on the OOS 9 build first, where it can be verified
against a system that already works.

**Deliverables**
- `droidian/packaging/debian/kernel-info.mk`: `KERNEL_BOOTIMAGE_CMDLINE`
  gains `datapart=/dev/disk/by-partlabel/linuxroot`. One token; the
  initramfs does the rest.
- `provision.sh` `data` phase and `droidian/flash.sh`: `fastboot flash
  linuxroot`, never `userdata`. `ROOTFS_IMG` and its `manifest.json` entry
  are renamed to say what they are now (`linuxroot.img` / `.simg`).
- `droidian/build-rootfs.sh`: the outer ext4 is 9 GiB inside a 114.6 GiB
  partition. Either size the image to the partition or grow it on first
  boot; decide in the detailed plan, and make `verify-device.sh` assert the
  filesystem fills the partition either way.
- `lib/probe.sh` / `lib/phases.sh`: `skip_data` compares against
  `linuxroot`, and the probe reports which partition Droidian booted from
  (`findmnt -no SOURCE /userdata` today; the mount point will change).
- `tests/` fixtures: a probe that says Droidian is on `userdata` must make
  the `data` phase run, not skip.
- `verify-device.sh`: new invariant, Droidian's data partition is
  `linuxroot`, and `userdata` is not mounted by Droidian at all.

**Exit criteria**
- After `BUILD_HOST=taichi ./provision.sh`, `/proc/cmdline` contains
  `datapart=/dev/disk/by-partlabel/linuxroot`, `findmnt` shows the Droidian
  data mount on sda18, `verify-device.sh` ALL PASS.
- `fastboot set_active a` boots OxygenOS 9, which formats and uses
  `userdata` as it likes; `set_active b` boots Droidian unchanged
  afterwards. That round trip is the test that the dual boot is real.

**Known risks**
- `droidian.lvm.prefer` is also on the cmdline; the initramfs tries the LVM
  path before the plain data-partition path. Confirm on hardware that
  `datapart=` is respected with it, or drop it (we do not use LVM).
- The `linuxroot` partition type GUID is userdata's (reused by
  `restore-android.py`); Android does not mount by type, but check that
  LineageOS's recovery does not either before Phase 2 boots it.

**Detailed plan:** `docs/plans/<date>-linuxroot.md`.

---

## Phase 2: Build LineageOS 20 and boot it on the other slot

**Status:** done (2026-09-06). Build and flash scripts in `lineage/`.

**Exit evidence**
- `./lineage/build-lineage.sh all` on taichi produces the five images from
  the pinned manifest in a pinned `debian:bookworm` container
  (`lineage/Containerfile`); MindTheGapps built in via LineageOS's
  `vendor/extra/product.mk` hook, zero upstream edits.
- Flashed to slot b over `fastboot format:ext4 userdata`. LineageOS
  `20.0-20260906-UNOFFICIAL-fajita` boots (MTP at 60 s plain, 90 s with
  GApps). SIM detected and a call placed, WiFi, both cameras, audio: all
  confirmed. Mobile data not testable yet (no provisioned line).
- Built `vendor.img`'s `fstab.qcom` mounts `userdata` as `/data` (ext4,
  `fileencryption=ice`) and names `linuxroot` zero times. Verified against
  the image, not the source.
- Round trip: `set_active a` boots the Droidian kernel in 25 s, slot `_a`,
  `datapart=linuxroot`, container reports Android 9; every dual-boot
  invariant in `verify-device.sh` passes. phosh did not start (24/26; the
  old api28 display stack, not investigated: Phase 3+ replaces this
  install). Phone left on slot b.
- Phase 3 ground truth captured in `logs/lineage20/`: `getprop`, vintf
  manifest + 20 fragments, kernel `.config` (5604 lines), `dmesg` (5885
  lines), `/proc/cmdline`, mounts, partitions, `/vendor/lib/modules`.

**Learned the hard way, now in the scripts**
- The manifest branch is `lineage-20.0`; `lineage-20` does not exist on
  `LineageOS/android`. Device/kernel/blob repos do use `lineage-20`.
- LineageOS 20 needs `git-lfs` (chromium-webview prebuilts) and
  `openssh-client` (manifest declares an ssh remote nobody uses) in the
  build container, and `ALLOW_MISSING_DEPENDENCIES=true` because it ships
  `cts` without `tools/tradefederation/core`. Do NOT exclude the `cts` repo
  group: it also removes `tools/trebuchet`, which defines `jsonlib`.
- podman defaults `pids.max=2048`; at `-j32` each r8/d8 JVM sizes itself
  for the whole box (~44 threads) and the build dies at 96% with
  `pthread_create EAGAIN`, which reads like OOM and is not. `--pids-limit`.
- `bacon` produces an A/B OTA; `system`/`vendor`/`vbmeta` exist only in
  `payload.bin` and `obj/PACKAGING/target_files_intermediates/*/IMAGES/`.
- The `error -13` firmware lines in LineageOS's `dmesg` are the PIL
  loader's first attempt failing under SELinux before the direct load
  succeeds; every subsystem shows `loading from 0x...` right after. That
  pattern IS the healthy baseline Phase 3 must reproduce.

**Status before this run:** not started

**Goal:** a reproducible LineageOS 20 build for fajita, made on taichi from
pinned sources, flashed to the spare slot, booting to the LineageOS home
screen with modem, WiFi, and camera working. This is both the Android
fallback and the source of `vendor.img`, `boot.img`, and `dtbo.img` for
every later phase.

**Why build at all:** download.lineageos.org only serves 22.2 nightlies;
LineageOS 20 builds are gone. The `lineage-20` branches are frozen (device
tree 2023-08, kernel 2024-02, blobs 2022-09 / 2023-08), which pins the build
for free.

**Inputs (verified)**
- Manifest: LineageOS `android` @ `lineage-20.0` (`569c0d5ee`). Note the
  `.0`: the device, kernel and blob branches are `lineage-20`, but the
  manifest repo has no such branch and `repo init -b lineage-20` fails.
- `LineageOS/android_device_oneplus_fajita` @ `lineage-20`,
  `LineageOS/android_device_oneplus_sdm845-common` @ `lineage-20`
  (`520b6e4a8`), `LineageOS/android_hardware_oneplus` (from
  `lineage.dependencies`), `LineageOS/android_kernel_oneplus_sdm845` @
  `lineage-20` (`7fbf93e22`, 4.9.337, `techpack/audio` in-tree).
- Blobs: `TheMuppets/proprietary_vendor_oneplus_fajita` @ `lineage-20`
  (`937dd991a`) and `TheMuppets/proprietary_vendor_oneplus_sdm845-common` @
  `lineage-20` (`a3fc5ad31`). No blob extraction from a phone needed.
- Build target: `lineage_fajita-userdebug`. Output partitions: `boot`,
  `dtbo`, `system`, `vbmeta`, `vendor` (exactly the A/B set).

**Pre-flight on taichi (do before `repo sync`)**
- Disk: a LineageOS 20 tree plus `out/` and ccache is ~300 GB. `/home` has
  190 GB free; `/opt/models` has 6.9 TB but is an SMR spinning disk
  (`ST8000DM004`, `rotational=1`), unusable for `out/`. Decision: free space
  on `/home` (owner's call, in progress) and keep source, `out/`, and ccache
  all on NVMe. `build-lineage.sh` refuses to start with less than 300 GB
  free at its work directory, so the check is in the script, not in a
  shell history.
- Toolchain: taichi has no `repo` and no Java. Build inside a container
  (podman is already there and is how the kernel builds), with a pinned
  image tag, the same way `droidian/build-kernel.sh` pins
  `build-essential`.

**Work**
1. `lineage/` directory in this repo with a `manifest.xml` local manifest
   pinning every repository above to its commit, a `build-lineage.sh` that
   runs `repo init` / `repo sync` / `brunch fajita` in the container, and a
   `README` line per environment variable it reads. Follow the
   `setsid nohup ... &> log < /dev/null & disown` rule for the multi-hour
   build; poll the log in separate commands.
2. Flash procedure: `fastboot` the five images to the spare slot, keep the
   Droidian kernel on the current one, then `fastboot format:ext4 userdata`
   (or whatever LineageOS's built `fstab.qcom` names; never `-w`). Android
   does not format a foreign `userdata` itself, it hangs on the boot
   animation (Phase 1 measured this with OxygenOS). Confirm on a dry run that LineageOS's fstab and recovery do
   not touch `linuxroot` (nothing in the `lineage-20` device tree names it;
   verify against the built `vendor.img` fstab, not the source).
3. Record what LineageOS itself does with the hardware: `getprop` dump,
   `/vendor/etc/vintf` manifest and fragments, `lsmod`, `dmesg` from a
   healthy boot, and the list of `/vendor/lib/modules`. These are the ground
   truth Phase 3 and Phase 5 diff against.
4. Extract from the build: `vendor.img`, `boot.img`, `dtbo.img`, the kernel
   `.config` actually used, and the kernel build command line (compiler,
   flags). Store the SHA256s in `manifest.json` under a `lineage` target.

**Exit criteria**
- `./lineage/build-lineage.sh` on taichi produces the five images from the
  pinned manifest, twice, with matching SHA256s for `vendor.img` and
  `dtbo.img` (boot may differ by timestamp).
- LineageOS 20 boots on the spare slot: SIM detected, WiFi connects, both
  cameras take a photo, audio plays. Screenshots or a checklist committed.
- `fastboot set_active` back to the OOS 9 slot boots Droidian unchanged.

**Known risks**
- Disk pressure on taichi is the only thing likely to block this phase.
- Do not start this phase until Phase 1's round-trip test has passed. A
  LineageOS first boot against a `userdata` that still holds Droidian
  destroys the working install.

**Detailed plan:** none written; the scripts in `lineage/` carry their
reasoning in comments and the commit log on `los20-port` is the record.

---
## Phase 3: Halium kernel from the LineageOS tree (the critical path)

**Status:** in progress (2026-09-06). Detailed plan:
`docs/plans/2026-09-06-los20-kernel.md`.

**Goal:** a Halium-capable 4.9.337 kernel built from the same LineageOS
`lineage-20` kernel tree Phase 2 used, packaged the way the current kernel
is (`linux-image-*`, `linux-bootimage-*` .debs from
`droidian/build-kernel.sh`), that boots to the Halium initramfs against the
LineageOS 20 `vendor` and answers SSH.

**Inputs (verified)**
- `LineageOS/android_kernel_oneplus_sdm845` @ `lineage-20` `7fbf93e22`.
  `enchilada_defconfig` (664 lines) serves both enchilada and fajita; the
  bootloader picks the fajita overlays from `dtbo`.
- What the stock LineageOS defconfig already has that Halium needs:
  `CONFIG_NAMESPACES=y`, `CONFIG_IKCONFIG_PROC=y`, `CONFIG_USB_CONFIGFS_NCM=y`,
  `CONFIG_QCA_CLD_WLAN=y` (built-in WLAN), `CONFIG_MODULES=y`.
- What it lacks or has wrong for Halium: `CONFIG_PID_NS` not set,
  `CONFIG_FHANDLE` not set, `CONFIG_MODULE_SIG=y`, SELinux on with no
  AppArmor, and the rest of the container/cgroup/VT/devtmpfs set. The sorted
  diff between our `fajita_defconfig` and LineageOS's `enchilada_defconfig`
  is 439 lines; that diff, reviewed line by line, is the Halium delta.
- Compiler: AOSP clang r450784 (`clang-android-14.0-r450784d` in
  `build-essential:current-amd64`). Phase 2 records the exact command line
  LineageOS used; match it.

**Work**
1. Retire the junocomp tree. New source pin in `droidian/build-kernel.sh`:
   LineageOS repo, `lineage-20`, `7fbf93e22`. No techpack checkout needed.
2. `droidian/packaging/debian/kernel-info.mk`:
   `KERNEL_BASE_VERSION = 4.9-337`, `BUILD_CC = clang`,
   `BUILD_PATH = /usr/lib/llvm-android-14.0-r450784d`, `DEB_TOOLCHAIN`
   updated, `KERNEL_BOOTIMAGE_PATCH_LEVEL` to LineageOS 20's. `debian/control`
   package names follow (`linux-*-4.9-337-oneplus-fajita`).
3. `fajita_defconfig` regenerated from LineageOS `enchilada_defconfig` plus a
   reviewed Halium delta. Every line in the delta gets a reason in the commit
   message; anything we cannot justify is dropped. Run Halium's kernel config
   checker before the first build.
4. Re-port the local patches onto 4.9.337, each re-justified:
   `0001-u_ether` (NCM null skb), `0002-loop` (discard),
   `0003-msm-poweroff` (ramoops knobs), `0004-adsprpc` (bounded kernel
   invoke), and the uncommitted `pm8998.dtsi rtc-write=1`, which becomes a
   committed patch this time. Check first whether LineageOS's 224 extra
   stable releases already fixed any of them.
5. The inherited Juno/Cyjan hacks from the old tree (v4l2loopback, schedtune
   nested groups, kgsl worker priority, OVERLAY_FS for getcutout, wakelock
   blocker, anbox binder config) do not come along. Anything that turns out
   to be needed is re-added as a patch with a one-line reason.
6. Ripple the version rename: `droidian/build-kernel.sh` (deb glob, image
   suffix), `droidian/adaptation/tests/run-tests.sh` (kernel version cases),
   `README.md`, `docs/`.

**Exit criteria**
- `./droidian/build-kernel.sh` produces `boot.img` / `vbmeta.img` from the
  LineageOS tree with zero out-of-tree edits (everything is a committed
  patch or the defconfig).
- Flashed to the LineageOS slot over LineageOS's `vendor` and `dtbo`, the
  device reaches the Halium initramfs and SSH over USB NCM answers. Display
  is NOT required yet.
- `dmesg` shows built-in WLAN and the audio machine driver probing, same as
  Phase 2's LineageOS `dmesg`.

**Known risks**
- First-of-kind at this API level; budget for the unknown.
- Mitigation that the OOS 11 route did not have: Phase 2's LineageOS
  `dmesg`, `.config`, and module list are a known-good reference from the
  same tree, so every divergence is attributable to our delta.

**Go/no-go:** if the kernel does not reach SSH within a week of focused
work, stop, write down what was learned, and decide between continuing and
the OOS 11 appendix.

**Detailed plan:** `docs/plans/<date>-los20-kernel.md`.

---

## Phase 4: Userland swap to api33

**Status:** not started

**Goal:** the Droidian rootfs and the Android container are the api33 set,
and the container (`lxc@android`) starts against the LineageOS 20 `vendor`.

**Inputs (verified)**
- Rootfs: `droidian-OFFICIAL-phosh-phone-rootfs-api33-arm64-<date>.zip` from
  `droidian-images/droidian` releases (`build-rootfs.sh` already selects by
  `API=`).
- `adaptation-hybris-api33-phone` depends on `ofono-binder-plugin`,
  `pulseaudio-modules-droid-hidl`, `audiosystem-passthrough`;
  `adaptation-hybris-api33` depends on `droidian-quirks-api33`,
  `pulseaudio-modules-droid-modern`, `bluebinder`, `timekeeper`.
- Container system: `android-system-gsi-33`, owning
  `/var/lib/lxc/android/android-rootfs.img`. Today's is
  `android-system-gsi-28` (`halium/lineage_halium_arm64:9`).
- Vendor facts the container will see, from LineageOS 20 sdm845-common:
  `BOARD_VNDK_VERSION := current` (33), vendor manifest `target-level="4"`,
  `TARGET_USES_GRALLOC1`, `TARGET_USES_HWC2`, `TARGET_USES_ION`, custom
  audio policy, sound trigger enabled. The exact HAL versions come from
  Phase 2's vintf dump, not from this file.

**Work**
1. `droidian/build-rootfs.sh`: default `API=33`. Confirm `setup.sh`, the
   journal requirement, and the `android-rootfs.img` symlink under
   `/halium-system/...` are unchanged in the api33 zip before trusting the
   existing resize/pack path.
2. `droidian/build-camera.sh`: re-pin `CAMERA_COMMIT` to the droidian-camera
   version shipped in the api33 rootfs; droidmedia lives inside the GSI.
   Re-check that the focus-mode patch still applies.
3. Adaptation package `Depends`: nothing today names api28; keep it that way.
4. Container bring-up: `lxc@android` active, binder nodes present (4.9 has
   no binderfs; the lxc config already marks it `optional`), vendor props
   visible, `hwservicemanager` listing the HALs from Phase 2's vintf dump.
5. LineageOS-only vendor services that expect a LineageOS `system`
   (`vendor.oneplus.*`, livedisplay, pocketmode, the udfps extension) are
   expected to fail harmlessly inside the GSI. List them; mask any that
   crash-loop.

**Exit criteria**
- `verify-device.sh` passes every non-display, non-peripheral check
  (container active, hostdev perms, clock floor, polkit helper).
- `dpkg -l` shows no api28 package.

**Known risks**
- Vendor sepolicy is compiled against LineageOS 20's platform policy; the
  GSI is LineageOS 20 based, so this should match. Droidian runs the kernel
  without SELinux enforcement regardless; confirm the cmdline carries what
  the halium initramfs expects.

**Detailed plan:** `docs/plans/<date>-los20-userland.md`.

---
## Phase 5: Peripheral bring-up

**Status:** not started

**Goal:** every peripheral that works on OOS 9 works on the LineageOS base.
Ordered by how much everything else depends on it. Phase 2's LineageOS
boot is the reference for "the hardware works with these blobs"; a failure
here is ours, not the vendor's.

| Order | Subsystem | What changed | How it is verified |
|---|---|---|---|
| 1 | Display | LineageOS `hwcomposer.sdm845` + gralloc1 through libhybris hwcomposer2; phosh must come up | `phosh.service` active, no SIGABRT loop, `verify-device.sh` display checks |
| 2 | Input, brightness, cutout | dtbo is now LineageOS's; touch driver in the LineageOS tree; `TARGET_TAP_TO_WAKE_NODE /proc/touchpanel/double_tap_enable` | tap, swipe, backlight sysfs path unchanged or re-pointed |
| 3 | USB networking | `u_ether` patch re-port from Phase 3 | SSH over NCM survives 10 reconnects |
| 4 | Modem | radio HAL as LineageOS 20 exposes it, via `ofono-binder-plugin` | SIM detected, call in/out, SMS, data |
| 5 | WiFi | built-in `qca_cld3`; `BOARD_WLAN_DEVICE qcwcn` | connect WPA2, survive suspend/resume |
| 6 | Audio | LineageOS custom audio policy, `pulseaudio-modules-droid-modern` | speaker, earpiece, mic, call audio, USB-C headset |
| 7 | Sensors | sensors HAL as LineageOS exposes it, through sensorfw | rotation, proximity during call, ambient light |
| 8 | Camera | provider 2.4; droidmedia from gsi-33; `droidian-camera` re-pinned | photo, video, front/back switch, flashlight |
| 9 | Bluetooth | `bluebinder` | pair, A2DP |
| 10 | GPS | gnss HAL as LineageOS exposes it | fix outdoors within 2 minutes |

**Exit criteria**
- `verify-device.sh` ALL PASS with a new invariant per subsystem.
- A parity table (OOS 9 Droidian vs LineageOS 20 Droidian vs LineageOS 20
  itself) committed here, one row per subsystem, with `works` /
  `regressed` / `not on OOS 9 either`.

**Detailed plan:** one plan per subsystem that needs more than config
(`docs/plans/<date>-los20-<subsystem>.md`). Subsystems that come up on
their own get a parity-table row and nothing else.

---

## Phase 6: Shutdown and power re-baseline

**Status:** not started

**Goal:** shutdown and boot times at or better than the OOS 9 baseline from
Phase 0 (boot 40.2 s; shutdown 12 s screen-on, 20-26 s screen-off), with
the same first-principles evidence.

**What is known to differ**
- The `vendor-build.prop` bind override (`ro.build.shutdown_timeout`) and
  the `init.qcom.rc` bind override (`chre` `shutdown critical`) were written
  against OxygenOS's vendor files. LineageOS 20's vendor `build.prop` and
  init scripts are different files with different contents; both overrides
  must be re-derived from what LineageOS actually ships, or deleted.
- `0004-adsprpc` bounded invoke and the ramoops knobs are re-ported in
  Phase 3; their effect is re-measured here.
- Host-side fixes carry over unchanged: `adaptation-rcu-unthrottle`
  (mobile-power-saver RCU fqs), `lxc.service` mask,
  `adaptation-clock-floor`, `halium-hostdev-perms`,
  `halium-oldkernel-compat` (4.9 < 5.1, still needed).

**Work**
1. Run `droidian/shutdown-trace.sh` on the first booting LineageOS-based
   image before touching anything; that is the new baseline.
2. Reconcile each adaptation override against what LineageOS 20 ships:
   delete the ones that no longer match a real file or line, keep the ones
   that do, and add a `verify-device.sh` check for every override that
   stays.
3. Re-answer the open questions from the OOS 9 sessions on the new kernel:
   adsprpc timeout below 5 s, UFS gear-scaling crash, one-off GMU BUG at
   shutdown, whether `adaptation-wan-down` and the
   `20-stop-without-lxc-wait` drop-in still earn their place.

**Exit criteria**
- Trace captures in `logs/shutdown-trace/` for screen-on and screen-off,
  numbers in the parity table, every kept override has a check.

**Detailed plan:** `docs/plans/<date>-los20-shutdown.md`.

---

## Phase 7: Pipeline, docs, and promotion

**Status:** not started

**Goal:** `BUILD_HOST=taichi ./provision.sh` on a clean checkout of
`los20-port` yields the LineageOS-based Droidian build with no manual steps,
and the repo says so.

**Work**
1. `build.sh` / `manifest.json`: a `lineage` target alongside `kernel`,
   `rootfs`, `adaptation`, `camera`. Kernel version string, rootfs API, and
   camera pin flow from one place (today `API` lives in `build-rootfs.sh`,
   the kernel version in `kernel-info.mk`, the camera pin in
   `build-camera.sh`; a release needs all of them to agree).
2. `provision.sh`: the `boot` phase learns to flash LineageOS's five images
   to the Android slot when the probe says that slot is not LineageOS 20 at
   the built fingerprint. `lib/probe.sh` already reads
   `ro.build.fingerprint`; add the LineageOS one to the skip logic.
3. `README.md`: the "requires stock Android 9, specifically 9.0.17" section
   becomes the LineageOS 20 statement; the `RELEASE=oos9` path stays
   documented as the legacy build on the `oos9-stable` tag.
4. `docs/plans/2026-09-04-*.md` and `docs/specs/2026-09-04-*.md` keep their
   `9.0.17` expectations as history; add a one-line pointer to this roadmap
   at the top of each rather than rewriting them.
5. `tests/run-tests.sh` and `droidian/adaptation/tests/run-tests.sh`:
   fixtures for the LineageOS probe (`ro.build.fingerprint` of the pinned
   build, new kernel version string).
6. Merge `los20-port` into `main` only after Phase 5's parity table has no
   `regressed` row and Phase 6's numbers are at or better than baseline.
   Until then `main` is the OOS 9 build.

**Exit criteria**
- Fresh clone on taichi, `./check-env.sh`, `BUILD_HOST=taichi ./provision.sh`
  from the workstation, and `verify-device.sh` ALL PASS on a phone that
  started from EDL.

---

## Order and dependencies

```
Phase 0 (baseline, tag oos9-stable)
   |
Phase 1 (Droidian moved to linuxroot, on the OOS 9 build)  -- real dual boot
   |
Phase 2 (LineageOS 20 built on taichi, booting on the spare slot)
   |         produces vendor.img, dtbo.img, reference dmesg/.config/vintf
Phase 3 (Halium kernel from the LineageOS tree)  -- SSH from initramfs
   |                                                GO / NO-GO
Phase 4 (userland api33)  -- container up on gsi-33
   |
Phase 5 (peripherals, display first)  -- parity table
   |
Phase 6 (shutdown/power)  -- re-baseline
   |
Phase 7 (pipeline/docs)  -- merge to main
```

Phase 2 stands alone and is useful even if the port stalls: it replaces the
2021 OxygenOS fallback with Android 13. Phases 3 and 4 cannot be tested
independently (the kernel needs LineageOS's vendor; the api33 container
needs a kernel that boots); build both before the first Droidian flash and
debug from the initramfs upward. Phase 5's subsystems are independent once
display works and can run in parallel.

## Effort and decision points

- Phase 0: hours.
- Phase 1: a day. Small diff, but it is flashed and round-tripped through
  both slots on real hardware before anything else moves.
- Phase 2: half a day of setup, a multi-hour build, half a day of flashing
  and validation. Disk on taichi is the only likely blocker.
- Phase 3: 1-2 days of packaging, then an open-ended bring-up. This is where
  the port succeeds or stalls. Go/no-go after one focused week.
- Phase 4: a day if Phase 3 is clean.
- Phase 5: 2-5 days; display and modem are the likely sinks.
- Phase 6: 1-2 days; the tracer already exists.
- Phase 7: a day.

## What the port buys

- A maintained kernel: 4.9.337, the same branch LineageOS 22.2 ships in
  2026, versus a 2020 Halium-9 fork of 4.9.113.
- Vendor and container at the same VNDK (33/33), with the container image
  derived from the same LineageOS release the vendor was built for. The OOS
  11 route would have paired a VNDK 30 retrofit vendor with a launch-on-11
  GSI.
- Android 13 with 2021-11 blobs on the fallback slot instead of OxygenOS 11.
- An API level Droidian still ships every release (api33), rather than the
  oldest one it supports.

What it does not buy: camera (same HAL and blobs), partitioning, or
provisioning changes. If Phase 3 stalls, the OOS 9 build loses nothing and
Phase 2's LineageOS still stands.

---
## Appendix: the OxygenOS 11 route (not chosen, kept as fallback)

Researched 2026-09-06 before the pivot to LineageOS 20. Everything here was
verified; it is the plan to fall back to if Phase 2 or 3 above stalls for a
reason specific to the LineageOS vendor.

**Stack:** OnePlus `oneplus/SDM845_R_11.0` kernel (`1f584f0fe`,
"Synchronize codes for Oneplus 6/6T OxygenOS 11.1.2.2", 4.9.227, clang 10 =
`clang-android-10.0-r370808`) plus
`android_kernel_oneplus_sdm845_techpack_audio` @ `oneplus/SDM845_R_11.0`
(`2c2c0f109`) checked out into the stub `techpack/audio`; stock OOS 11
`vendor.img` from `releases/oos11` (VNDK 30, `first_api_level=28`, FCM
`target-level="3"`); `android-system-gsi-30` (11.0.0+r47) in the container;
`rootfs-api30` + `adaptation-hybris-api30-phone`.

**Facts that carry over from that research**
- OOS 11 keeps the stock partition layout, header v1, and reuses `dtbo`.
- OOS 11 vendor HAL versions vs OOS 9: composer 2.1->2.3, mapper 2.0->2.1,
  audio 4.0->6.0, radio 1.2->1.4, sensors 1.0->2.0 multihal (legacy
  `sensors.ssc.so` still shipped), wifi 1.2->1.4, camera.provider 2.4
  unchanged.
- OOS 11's `/vendor/build.prop` has no `ro.build.shutdown_timeout=0` (has
  `sys.vendor.shutdown.waittime=500`); `chre` is still `shutdown critical`.
- Both OOS 9 and OOS 11 ship `qca_cld3_wlan.ko` and `snd-soc-sdm845.ko` as
  vendor modules; build them in.
- Stock R `sdm845_defconfig` moved 112 lines from P; the Halium delta from
  our `fajita_defconfig` to stock P is 557 lines.

**Why it lost to LineageOS 20:** retrofit vendor under a launch-on-11 GSI
(VNDK 30 vendor, FCM 3) versus a matched VNDK 33 pair; a 2021 frozen OnePlus
kernel drop versus a branch LineageOS still maintains; OxygenOS 11 versus
Android 13 on the fallback slot. The kernel bring-up effort is the same
order of magnitude either way.
