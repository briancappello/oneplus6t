# oneplus6t — flashing and recovery scripts for the OnePlus 6T (fajita)

Working toward a set of scripts that can put any of several operating systems
on a OnePlus 6T, with a known-good Android always recoverable underneath.

**Today this repo does two things.** It restores a device from a destroyed
partition table back to stock OxygenOS (11.1.2.2 or 9.0.17), entirely from
Linux, entirely from EDL — the floor everything else stands on. And it takes
that device to a **dual boot of OxygenOS 9 (slot b) and Droidian (slot a)**
with separate data partitions, built and flashed by scripts, verified on the
phone. The whole path is the [Runbook](#runbook-any-state-to-oxygenos-9--droidian)
below. That state is tagged `oos9-stable`; it is the known-working baseline
every later experiment (LineageOS 20, see `docs/plans/`) falls back to.

```bash
git clone https://github.com/briancappello/oneplus6t
cd oneplus6t
./check-env.sh                                           # verify host tools
python3 bootstrap.py                                     # fetch + extract
RELEASE=oos11 .venv/bin/python restore-android.py        # phone in EDL
```

`check-env.sh` verifies every external tool the scripts need and prints the
exact install command for anything missing, per distro. It installs nothing
itself — all the remediations need root, and this repo does not take root.
Each entry in it was previously discovered as a mid-build failure.

## Runbook: any state to OxygenOS 9 + Droidian

The end state, verified 2026-09-06 (`oos9-stable`):

```
fastboot set_active a  ->  boot_a (Droidian kernel) + vendor_a + linuxroot  ->  Droidian
fastboot set_active b  ->  boot_b + system_b + vendor_b + userdata           ->  OxygenOS 9.0.17
```

`userdata` and `linuxroot` are each 114.6 GiB. Android mounts `/data` by name
and nothing in its fstab names `linuxroot`; Droidian's kernel cmdline carries
`datapart=/dev/disk/by-partlabel/linuxroot`, so neither OS can see the other's
data. Inside `linuxroot`, `rootfs.img` is 100G (sparse) and the outer
filesystem is grown to the partition by the initramfs on first boot.

Start at the step that matches the phone. Every step is idempotent and safe to
repeat; every step ends in a state the next one recognises.

**Step 0 — the machines.** Once per host.

```bash
./check-env.sh flash                       # the machine with the phone
BUILD_HOST=taichi ./check-env.sh flash     # ... and that the worker answers
python3 bootstrap.py                       # MSM tool, EDL loader, OOS 11 zip
# OOS 9 has no download URL: place OnePlus6TOxygen_34_OTA_024_all_1909112343_d5b1905.zip
# in downloads/ by hand; bootstrap.py verifies its SHA256.
```

**Step 1 — Android is broken, or the GPT is.** Phone in EDL: power off fully,
hold Volume Up + Volume Down, plug in USB; the screen stays black.

```bash
RELEASE=oos9 LAYOUT=dualboot .venv/bin/python restore-android.py
```

Rebuilds the GPT with the 50/50 split (keeping it if already correct), flashes
OxygenOS 9 to **both** slots, verifies every partition by read-back, asks
recovery to format `/data`, and reboots. Several minutes later OxygenOS 9 is
at its setup wizard on the active slot. Do not finish the wizard; there is
nothing to set up. Skip this step if the GPT has `linuxroot` and slot b already boots
OxygenOS 9: `provision.sh` reports `edl: skipped` in that case, and would
refuse to repartition without positive evidence anyway.

**Step 2 — put Droidian on slot a.** Get the phone into the bootloader: from
a running OxygenOS with no USB debugging, hold Power + Volume Up + Volume Down
until it restarts there. From Droidian, `./bin/device-goto fastboot` does it.

```bash
FORCE=1 BUILD_HOST=taichi ./provision.sh
```

Builds kernel, adaptation packages, camera and rootfs on the worker, fetches
them, flashes `boot` + `vbmeta` of the **active** slot and `linuxroot`,
reboots, and runs
`verify-device.sh` until it reads `ALL PASS`. The first boot takes about five
minutes (the initramfs grows a 114 GiB filesystem); later boots take 30 s.
`FORCE=1` is what makes it rebuild and reflash when the manifest already
lists everything; without it the run only does what the probe proves is
missing, which is the right default for every run after this one. Droidian
lands on whichever slot was active; OxygenOS 9 keeps the other. On the
reference device that is a = Droidian, b = OxygenOS, as drawn above.

**Step 3 — prove the dual boot.** From Droidian:

```bash
./bin/device-goto fastboot && fastboot set_active b && timeout 60 fastboot reboot
```

OxygenOS 9 must reach its setup wizard in about a minute. If it sits on the
boot animation instead, `userdata` holds a filesystem Android will not accept
(Android formats nothing on its own): back to the bootloader,
`fastboot format:ext4 userdata` — **never `fastboot -w`**, which bootloops
this device — and try again. Then back:

```bash
fastboot set_active a && timeout 60 fastboot reboot     # from the bootloader
./droidian/verify-device.sh                              # ALL PASS
```

**Smaller repairs.** Only the kernel: `PHASE=boot ./provision.sh`. Only the
rootfs: `PHASE=data FORCE=1 ./provision.sh` (erases the Droidian install, not
Android's). Droidian boots but something is off: `./droidian/verify-device.sh`
names the failing invariant. Nothing answers on USB and the screen is black:
Step 1.

**What this runbook cannot do.** Wake a powered-off phone, or take an
OxygenOS OTA safely — an OTA writes the *inactive* slot, which is Droidian's
kernel and vendor. Do not accept updates in OxygenOS 9.

## The pipeline

One path from **any** state to the dual boot, skipping whatever is already
correct. Three scripts, split by role:

| Script | Runs on | Does | Status |
|---|---|---|---|
| `check-env.sh [build\|flash\|all]` | either | verifies host prerequisites | **works** |
| `build.sh [--plan F \| targets…]` | worker | builds artifacts; never touches a phone | **works** |
| `provision.sh` | the machine with the phone | probes, decides, flashes, verifies | **works** |

Building needs cores and a container runtime; flashing needs the phone. They
are rarely the same machine, so the decision of *what to build* stays with the
side that can see the device, and the building goes to the side with the CPU:

```bash
# on the machine with the phone
./check-env.sh flash
./provision.sh --plan-only > plan.json     # probes the device, decides

# on the worker
./check-env.sh build
./build.sh --plan plan.json                # builds only what is missing

# back on the machine with the phone
./provision.sh --artifacts .
```

`plan.json` says *what needs building*, not what to flash, and it is small
enough to move by any means. If the two machines can reach each other,
`BUILD_HOST=worker ./provision.sh` collapses this into one command — but the
split stays the primitive, so it works with no ssh trust between them.

| Flag | Effect |
|---|---|
| `--plan-only` | probe and emit `plan.json`; touch nothing |
| `--artifacts DIR` | flash using prebuilt artifacts from `DIR` |
| `--remote-build host` | build on a worker, fetch the results, and stop |
| `BUILD_HOST=host` | build remotely, fetch, then flash and verify |
| `PHASE=name` | run a single phase: `edl`, `boot`, `data`, `activate`, `verify` |
| `--yes` | proceed past the destructive confirmation without a terminal |

### Skipping is decided by probing, never by a marker

Each phase reads real evidence from the device — build fingerprints, the GPT
layout, `dpkg` versions inside the rootfs, the active slot — and skips itself
if the outcome is already present. Nothing records "what we did last time":
such a record silently lies the moment anything changes outside the pipeline,
and this repo has already been bricked once by trusting a claim over reality
(the MSM GPT template *said* it was valid; it was not). `VERIFY=1` upgrades
every probe to a full hash comparison when you want certainty over speed.

### Every fix is an artifact

**No fix may live only on the running device.** Anything applied by hand over
ssh is destroyed by the next reinstall, so every fix is packaged into an
artifact instead — a `.deb`, a file baked into `rootfs.img`, or a flashing
step. The `verify` phase asserts the user-visible outcome afterwards
(hardware GL renderer, working polkit, camera on the aal path), so a fix that
regresses because someone applied it manually is caught rather than
rediscovered.

| `RELEASE` | Build | Android |
|---|---|---|
| `oos11` (default) | OxygenOS 11.1.2.2 — `34.J.62` | 11, `RKQ1.201217.002` |
| `oos9` | OxygenOS 9 — `34.O.24` | 9, `PKQ1.180716.001` |

## Device states and transitions

`./device.sh state` reports where the phone is; `./device.sh goto <state>`
moves it there, prompting only when the transition genuinely needs hands.

| State | USB ID | Reached over USB from |
|---|---|---|
| `droidian` | `0fce:7169` | fastboot, EDL |
| `fastboot` | `18d1:d00d` | droidian, initramfs |
| `edl` | `05c6:9008` | **droidian** (see below) |
| `initramfs` | `18d1:d001` | — (a failed boot lands here) |
| `ramdump` | `05c6:900e` | — (a panic lands here) |
| `android` | varies | fastboot |
| `off` | none | — |

```
                 systemctl --reboot-argument=bootloader reboot
   droidian ─────────────────────────────────────────────────► fastboot
      ▲   │                                                    │    ▲
      │   │ systemctl --reboot-argument=edl reboot             │    │ reboot
      │   └──────────────────────────────────────► edl         │    │ bootloader
      │                                             │          │    │
      └───────── edl reset ─────────────────────────┘          │  initramfs
      ◄──────────────────── fastboot reboot ───────────────────┘
```

**EDL is reachable from a booted Droidian**, which is not obvious: this
bootloader rejects `fastboot oem edl`, `oem enter-dload` and
`reboot emergency`. But the *kernel's* restart handler accepts `edl` and calls
`enable_emergency_dload_mode()` — `drivers/power/reset/msm-poweroff.c`, guarded
by `CONFIG_QCOM_DLOAD_MODE=y`, which `fajita_defconfig` sets. Entirely
different code path from the bootloader's refusal. Verified on hardware.

### What still needs hands

Only two things, and `device.sh` prompts for both rather than failing:

- **Powered off → anything.** No software can wake it.
- **`fastboot` → `edl` directly.** The bootloader refuses. `device.sh` routes
  around it automatically by booting an OS first, which works whenever
  something bootable exists.

### Measured timings, and one trap

| Transition | Time |
|---|---|
| `droidian` → `fastboot` | ~285–295 s |
| `droidian` → `edl` | ~70 s |
| `fastboot` → `droidian` | ~30 s to USB, ~40 s to sshd |
| `edl reset` → `droidian` | ~20 s |

Droidian's **shutdown** is slow, not its boot. During shutdown the old USB ID
stays enumerated and the device keeps answering pings for up to two minutes.
Never conclude a transition failed because the old ID is still present — poll
for the *target* ID with a generous timeout. Getting this wrong makes a
working transition look broken.

## Entering EDL

1. Unplug USB.
2. Hold **Power + Volume Up** for ~15s until the screen is fully black.
3. Hold **Volume Up + Volume Down together** and, while holding both, plug in USB.

The screen stays black. `lsusb` shows `05c6:9008` (Qualcomm HS-USB QDLoader).

This bootloader rejects `fastboot oem edl`, `fastboot oem enter-dload` and
`fastboot reboot emergency`, so the hardware combo is the only way in.

## What bootstrap.py does

| Step | Output |
|---|---|
| Download the archives (resumable, SHA256-pinned) | `downloads/` |
| Clone `edl` + `oppo_decrypt` at pinned commits | `edl/`, `oppo_decrypt/` |
| Create venv, install deps, patch the `edl` qfil bug | `.venv/` |
| Decrypt the MSM `.ops` | `msm/extract/prog_firehose_ddr.elf`, `gpt_main0.bin` |
| Extract each release's `payload.bin` | `releases/<name>/images/*.img` |

The MSM package is not an OS to install — it is only where the firehose loader
and the LUN0 GPT template come from, and it is needed whichever release you
flash. `RELEASE=<name> python3 bootstrap.py` extracts just one.

Everything is idempotent and hash-verified, so re-running after an interrupted
download or extraction is safe.

The payload extractor is built in — no protobuf, no `payload_dumper`, no Go
toolchain. It handles `REPLACE`, `REPLACE_BZ`, `REPLACE_XZ` and `ZERO`, which
is all a full OTA uses, and verifies every image against the hash the payload
itself declares.

**Note:** the MSM archive is hosted on AndroidFileHost, which issues expiring
signed URLs. If that download fails, fetch the file by hand and drop it in
`downloads/` — the SHA256 is pinned, so bootstrap will verify and continue.

## What restore-oos11.py does

```
python restore-oos11.py
```

Auto-detects the phone, runs the EDL stage, sets the boot control block so it
stops in fastboot, then finishes there without you touching it.

| Flag | Effect |
|---|---|
| `SELFTEST=1` | offline: build and check the GPT, touch no hardware |
| `DRY=1` | resolve and size-check every partition, write nothing |
| `PHASE=edl` / `PHASE=fb` | run a single stage |
| `PHASE=wipe` | only request a recovery `/data` wipe and reboot |
| `WIPE=0` | keep `/data`; ask the bootloader for fastboot instead |
| `FAST=1` | skip read-back verification |
| `START=n` | resume the flash after an interruption |
| `FORCE_GPT=1` | rewrite the GPT even if it is already consistent |
| `LAYOUT=dualboot` | split `userdata` 50/50 and add a `linuxroot` partition |
| `RELEASE=oos9` | flash OxygenOS 9 instead of the default OxygenOS 11 |

The filesystem for `/data` is **read out of the release being flashed** —
`debugfs` pulls `/etc/fstab.qcom` from that release's `vendor.img` and takes
the type from the `/data` line. It is never assumed, because assuming it is
exactly what bootloops the device (see below). Both OOS9 and OOS11 say `ext4`.

Sequence: measure LUN0 → finish the GPT template → write and verify primary +
backup → flash 46 partitions across LUN0/1/2/4 → verify each by chunked
read-back SHA256 → write the boot control block → reset.

`/data` carries the previous OS's filesystem and encryption keys, so it has to
be reformatted. The script asks **recovery** to do it, by writing Android's
bootloader control block into `misc`:

```
command  @0   = "boot-recovery"
recovery @64  = "recovery\n--wipe_data\n"
```

That is the mechanism a normal factory reset uses. Recovery formats `/data`
with the freshly flashed OS's own idea of the filesystem and reboots — which
is both more correct than `fastboot format` and, unlike it, does not depend on
the phone ever stopping in fastboot.

The fastboot stage is now a fallback, not a requirement: it runs only if the
bootloader happens to stop there, which occurs when a slot is flagged
`unbootable`. On the OxygenOS 11 install that is exactly what happened, and it
was luck rather than design.

## Why this repo exists

`edl qfil` destroys the LUN0 partition table on this device.

The MSM `.ops` ships `gpt_main0.bin` as an **unfinished template**:
`last_usable_lba=0`, `backup_lba=0`, and `userdata` spanning `1601344..1601343`
— zero length. MSM's `patch0.xml` is what completes it, and `oppo_decrypt`
never extracts a `patch0.xml`; there isn't one in the package.

`edl` derives `NUM_DISK_SECTORS` from `gpt.py`'s
`totalsectors = first_usable_lba + last_usable_lba`. That is accidentally
correct for a valid GPT (`6 + (total-6)`), but against the template it is
`6 + 0 = 6`. So `start_sector="NUM_DISK_SECTORS-5."` evaluates to **1**, and
the backup GPT gets written straight over the primary GPT header at LBA1 and
its entry array at LBA2–5. `getlunsize()` also returns `-1` on error, which
evaluates to `-6`.

The symptom is `system_a`/`system_b` "Partition not found" in fastboot while
every LUN4 partition still works — because only LUN0's table was destroyed.

`bootstrap.py` patches `edl` to refuse the write instead. This repo's own
restore never calls `qfil`; it finishes the template properly — measures the
real LUN size, grows `userdata` to fill it, and recomputes both CRC32s.

## Hard-won details

- **`fastboot -w` bootloops this phone.** It asks the bootloader for the
  filesystem type, OnePlus answers `f2fs`, but `vendor.img`'s `fstab.qcom`
  requires **ext4** for `/data` with no `formattable` flag — so the mount fails
  with no fallback. Use `fastboot format:ext4 userdata`.
- **`slot-unbootable:a:yes` is not stored in `misc`.** It lives in the GPT
  attribute bits on LUN4, so wiping `misc` does not clear it. `set_active a`
  does. Failed boots set this flag and send you straight back to fastboot.
- **`reserve` and `india` are in the OTA payload but have no partition on
  fajita.** Confirmed by dumping the GPT of every LUN 0–5. Neither appears in
  any fstab and `care_map.pb` verity-covers only `system` and `vendor`, so
  they are skipped. `oem_stanvbk` is skipped too — it holds OEM NV data.
- **OOS11 uses the same LUN0 layout as MSM 9.0.13.** `system.img` is exactly
  `2,998,927,360` bytes = `system_a`'s 732,160 sectors; `vendor.img` is exactly
  `1,073,741,824` = 262,144 sectors.
- **The loader truncates sector numbers ≥ 2³².** Reads at 2³² and 2⁴⁰ return
  zeroed data with `resp=True`, so any binary search for the end of a LUN must
  be bounded below 2³² or it runs away to 2⁶⁴.
- **This loader has no `getsha256digest`.** It advertises `sha256init` and
  `sha256final` only, so verification is done by chunked read-back.

## Roadmap

| | Status |
|---|---|
| Restore stock OxygenOS 11 from EDL | done, verified on hardware |
| Flash OxygenOS 9 | done (`RELEASE=oos9`), verified on hardware |
| Flash postmarketOS | `flash-pmos.sh`, works, not yet integrated |
| Droidian kernel | builds and boots — `droidian/build-kernel.sh` |
| Droidian display | working, and now survives a reinstall |
| Droidian camera | working — `droidian/build-camera.sh` fixes the focus mode |
| Adaptation packages | **built and verified on hardware** — `droidian/adaptation/` |
| `build.sh` / `provision.sh` pipeline | works |
| Dual-boot OxygenOS 9 + Droidian | **done** — tagged `oos9-stable`, runbook above |
| LineageOS 20 as the Droidian base | planned — `docs/plans/2026-09-06-los20-port-roadmap.md` |

## Dual-boot layout

This device is A/B: `boot`, `system`, `vendor`, `odm`, `modem`, `xbl`, `abl`,
`tz`, `dtbo` and `vbmeta` all exist as `_a` and `_b`, and `fastboot set_active`
picks between them. Two operating systems, one command.

`userdata` is **not** slotted — one partition, shared by whatever boots. So
`LAYOUT=dualboot` splits it in half and adds a `linuxroot` partition:

```
 stock                                  dualboot
 ─────────────────────────────────      ─────────────────────────────────
  1601344 ─ 61677562                     1601344 ─ 31641599
    userdata          229.17 GiB           userdata        114.59 GiB
                                          31641600 ─ 61677562
                                            linuxroot      114.58 GiB
```

`userdata` keeps its **start** sector, so no other partition moves — the split
is one edited GPT entry, one added entry, and two recomputed CRC32s. The
boundary is aligned to 16 MiB, which leaves the two halves 16.8 MiB apart out
of 114 GiB.

**Android needs no changes.** It mounts `/data` by name, so it simply finds a
smaller partition. Nothing in any fstab mentions `linuxroot`, so Android never
mounts, checks or formats it — including on a factory reset, which wipes
`userdata` by name.

**postmarketOS needs no changes either.** Its initramfs finds the rootfs by
filesystem UUID, not by partition name — the boot image's cmdline carries
`pmos_root_uuid=...`, and `find_root_partition()` in `init_functions.sh`
resolves it with `blkid --uuid`, falling back to the label `pmOS_root`. It
scans every block device, so writing a stock pmOS rootfs to `linuxroot`
instead of `userdata` just works.

**Droidian needs one token.** The halium initramfs honours `datapart=<path>`
on the kernel cmdline after its own search for `userdata`, so
`droidian/packaging/debian/kernel-info.mk` appends
`datapart=/dev/disk/by-partlabel/linuxroot`. The `/dev/disk/` form is not
cosmetic: the initramfs's `resize_userdata_if_needed` only grows the
filesystem to the partition for `/dev/mmcblk*` and `/dev/disk*` paths, and
the auto-found `/dev/sdaN` matched neither, which is why `/userdata` sat at
8.8 GB on a 114 GiB partition for the first week.

```
fastboot set_active a   → boot_a + vendor_a + linuxroot            → Droidian
fastboot set_active b   → boot_b + system_b + vendor_b + userdata  → OxygenOS 9
```

`system_a` and `odm_a` (3 GiB) go unused by Droidian (its Android container
runs Droidian's own GSI image from inside `linuxroot`), and are available for a
second Android later.

### Known hazards

- **Repartitioning wipes `/data`.** There is no in-place shrink here.
- **`LAYOUT=dualboot` is not the default.** Running the restore without it
  rebuilds the stock table and destroys `linuxroot`.
- **A/B OTAs write the inactive slot.** A stock OxygenOS update installed
  while on slot b will overwrite `boot_a` and `vendor_a` — the Droidian kernel
  and the vendor it depends on, though not `linuxroot`. Do not take OTAs;
  if one happens, `PHASE=boot ./provision.sh` restores the kernel and
  `RELEASE=oos9 restore-android.py` the vendor.
- **AVB.** A custom `boot_a` will not verify against stock `vbmeta`. The
  Droidian kernel package builds an empty `vbmeta.img` (verification
  disabled) and `provision.sh` flashes it alongside `boot_a`.
- **Android formats nothing on its own.** A `userdata` holding any filesystem
  Android did not make (a Droidian image, say) leaves OxygenOS on the boot
  animation forever, writing nothing. `fastboot format:ext4 userdata` first.
- **The halium initramfs carries e2fsprogs 1.43.4 (2017).** Images made by a
  2025 `mke2fs` have `orphan_file`, which it refuses, so its `e2fsck` and
  `resize2fs` fail silently while the script logs "resized". `build-rootfs.sh`
  builds with `-O ^orphan_file` and asserts it; `verify-device.sh` asserts the
  filesystem actually fills the partition.
- **No shared storage.** Android's `/data` is `fileencryption=ice`, so Linux
  cannot read it. A shared area would have to be a third partition.

## Droidian

Droidian runs the vendor Android kernel under libhybris/halium, so vendor blobs
— camera in particular — work where mainline struggles on sdm845. Its device
page requires stock **Android 9, specifically 9.0.17 on the 6T**, which is
exactly what `RELEASE=oos9` installs (`ro.oxygen.version=9.0.17`).

```bash
./droidian/build-kernel.sh      # -> droidian/out/images/{boot,recovery,vbmeta}.img
```

Only the packaging overlay and the build script are tracked; the 1.1 GB kernel
source is cloned at a pinned commit and the build runs in Droidian's own
container. podman works — their tooling locates the runtime with
`whereis -b docker`, so a shim on `PATH` is enough. No Docker, no root.

### Why this repo carries its own packaging

There is no prebuilt Droidian image for this device any more. The one the
device page links to (`FakeShell/droidian-oneplus6`) is a 404 — the repo was
deleted, Wayback holds only a capture of the 404 itself, Software Heritage
first visited after deletion, and archive.org has nothing. The **live** device
data still points at that dead URL.

The surviving source, `junocomp/linux-android-oneplus-oneplus6` (branch
`droidian`), **cannot build as published** — it ships no `debian/control`, so
the build dies at `Unable to find debian/control`. That is very likely why
nobody has regenerated the image. `droidian/packaging/debian/control` is a
reconstruction, modelled on the `droidian-devices/linux-android-fxtec-pro1`
reference port and the values in `kernel-info.mk`.

### Explicitly fajita

Upstream targets `DEVICE_MODEL=oneplus6` with `KERNEL_DEFCONFIG=enchilada_defconfig`
and calls itself "Oneplus 6/6T". We retarget to `fajita`, so artifacts are named
`linux-bootimage-4.9-337-oneplus-fajita` and there is no ambiguity about which
device an image is for.

`fajita_defconfig` is LineageOS's `enchilada_defconfig` plus the reviewed
`halium.delta` next to it (see `docs/plans/2026-09-06-los20-kernel.md`); the
enchilada file holds only SoC configuration and contains no device-name
strings, so the rename itself is not functional. The device tree genuinely covers the 6T already:
`CONFIG_BUILD_ARM64_DT_OVERLAY=y`, and `arch/arm64/boot/dts/qcom/Makefile` lists
10 `fajita-*.dtbo` overlays beside the enchilada ones, all on the shared
`sdm845-v2.1.dtb` base. The bootloader selects the right overlay by hardware ID.

### Do not erase dtbo

`kernel-info.mk` sets `KERNEL_IMAGE_WITH_DTB_OVERLAY=0`, and the generated
flash config says `DEVICE_HAS_DTBO_PARTITION=no`. Droidian relies on the dtbo
already on the device — for us OxygenOS 9's, which already contains the fajita
overlays. So unlike `flash-pmos.sh`, **do not** `fastboot erase dtbo_a` when
installing Droidian.

### Building arm64 packages: native, never cross

Anything that links arm64 libraries must be built **natively** in an arm64
container under `qemu-user-static`, not cross-compiled:

```bash
sudo pacman -S --needed qemu-user-static qemu-user-static-binfmt
sudo systemctl restart systemd-binfmt
```

This is not a preference. Droidian's repo ships **different systemd versions
per architecture** — `libudev1` is `257.1` for amd64 and `257.7` for arm64 —
and `libudev1` is `Multi-Arch: same`, which requires identical versions across
architectures. So `qtbase5-dev:arm64` → `libqt5gui5t64:arm64` →
`libudev1:arm64` can never be satisfied inside an amd64 container, and there is
no `257.7` amd64 to upgrade to. `releng-build-package` also calls
`mk-build-deps` with no `--host-arch`, so build dependencies always install for
the build architecture.

The kernel misleads on this point: it cross-builds fine only because it carries
its own Android toolchain and needs no arm64 library packages at all.

The binfmt registration must have the **`F` flag** (`flags: PF`). Without it the
kernel opens the interpreter from the calling process's mount namespace, so it
is invisible inside a container. `check-env.sh` asserts this specifically.

### Adaptation packages

Three `.deb`s, built by `droidian/adaptation/build-adaptation.sh` and installed
into `rootfs.img` by `build-rootfs.sh`, so every fix survives a reinstall:

| Package | Scope |
|---|---|
| `halium-hostdev-perms` | any Halium device — derives host udev rules from the device's own `ueventd.rc` |
| `halium-oldkernel-compat` | any kernel < 5.1 — makes polkit work without `pidfd` |
| `adaptation-oneplus-fajita` | fajita glue; depends on the other two |

`./droidian/verify-device.sh` asserts the user-visible outcome. It reports
`ALL PASS` after a fresh flash with **no manual step**, verified across three
boots.

**The rules must live in `/run`, never `/etc`.** `generate-rules` computes
"nodes the session user cannot reach". A ruleset persisted in `/etc` is applied
by udev *before* the unit runs, so the nodes it fixed read as already reachable
and get written out of the file — measured erosion from 52 rules to 42 across
one reboot, dropping `hwbinder` and `vndbinder`, the two the display depends on.
`/run/udev/rules.d` is tmpfs, so every boot measures a pristine `/dev`.

**Android group names need translating.** 13 of the 19 groups named in this
device's `ueventd.rc` do not exist under that name; `lxc-android` renames them
with an `android_` prefix, and 11 resolve that way (`graphics` →
`android_graphics`). udev *silently drops* a `GROUP=` it cannot resolve while
still applying the mode and owner, so an unresolved name half-applies and
reports nothing. Unresolvable names emit no rule at all and log the skip.

**`KERNEL=` is a sysname, not a path.** `/dev/dri/card0` must be
`KERNEL=="card0"`; `KERNEL=="dri/card0"` matches nothing and fails silently.

**Installing into `rootfs.img` needs `/dev` bind-mounted.** The image contains a
`/dev/null` character device, but FUSE mounts are `nodev`, so opening it returns
EPERM and `droidian-camera`'s `postinst` fails on a `>/dev/null` redirect inside
an `if` — where `set -e` does not trip, so dpkg still reports success and the
package installs half-configured. Our three packages carry no maintainer scripts
and need no emulation; `droidian-camera` is built with `dh`, ships
`postinst`/`postrm`, and `dpkg --root` chroots to run them under qemu binfmt.

### The clock, and why it broke the first boot

The fajita's `qpnp` RTC **free-runs from zero and is read-only** — `RTC_SET_TIME`
returns `EINVAL` because the device tree has no `qcom,qpnp-rtc-write` — and the
kernel applies it anyway via `CONFIG_RTC_HCTOSYS`:

```
qcom,qpnp-rtc ...: setting system clock to 1970-01-02 05:30:25 UTC
```

Droidian already compensates: `/usr/bin/timekeeper` stores
`wall_clock − /sys/class/rtc/rtc0/since_epoch` in `/data/time/timekeep` and adds
it back at boot. But `/data` is the Android userdata partition, **which a reflash
wipes** — so on a freshly flashed device timekeeper restores `since_epoch + 0`
and the clock lands in 1970.

That is not cosmetic. It breaks TLS and `apt`, trips the polkit password-age
check (`account droidian has password changed in future`), and makes journald log
`Time jumped backwards, rotating` and discard boots — which destroyed the
evidence for a separate bug.

**The RTC cannot be made to hold real time.** Setting
`qcom,qpnp-rtc-write = <1>` in `pm8998.dtsi` does make the driver register
`.set_time` — the error moves from `EINVAL` to `ENODEV` — but `set_time` starts
by disabling the RTC control register and the SPMI write is denied at the bus
level:

```
qcom,qpnp-rtc: SPMI write failed
qcom,qpnp-rtc: Disabling of RTC control reg failed with error:-19
```

Reads work, and other PMIC peripherals (the LEDs) are writable, so SPMI itself
is fine — this peripheral is owned by the secure world, which is why OnePlus
ships the property as `<0>`. SPMI ownership is set by the bootloader/TZ and no
device tree change can grant it. Tested on hardware; the patch was reverted.
Accurate time has to come from the network.

`adaptation-clock-floor.service` runs **after** timekeeper, raises the clock to
the package build time if timekeeper restored something implausible, and hands
the corrected value straight back to `timekeeper store`. Forward-only, so it
cannot fight NTP. From the second boot on, Droidian's own mechanism carries it.

**Ordering is the subtle part.** `timekeeper.service` keeps its default
dependencies and is therefore already `After=sysinit.target`. Adding
`Before=sysinit.target` to our unit made a cycle, which systemd resolved by
deleting our job:

```
sysinit.target: Found ordering cycle on adaptation-clock-floor.service/start
Job adaptation-clock-floor.service/start deleted to break ordering cycle
```

The unit then reads `loaded / inactive / success` — indistinguishable at a glance
from one that ran and did nothing. `verify-device.sh` asserts no ordering cycles
and no backward time jumps for exactly this reason.

### Camera

The camera app is black out of the box, for a reason unrelated to this device:
Qt5 ships two camera `mediaservice` plugins and picks the wrong one.
`libgstcamerabin.so` (generic GStreamer) cannot link a source against a vendor
HAL and fails with `negotiation problem`, while `libaalcamera.so`
(libhybris/droidmedia) works. Setting `backend=aal` in
`/etc/droidian-camera.conf` is **not** sufficient — Qt resolves the service
independently. The plugin has to be diverted out of the scanned directory:

```bash
dpkg-divert --add --rename \
  --divert /usr/lib/aarch64-linux-gnu/qt5/plugins-disabled/libgstcamerabin.so \
           /usr/lib/aarch64-linux-gnu/qt5/plugins/mediaservice/libgstcamerabin.so
```

Diverting it to `<plugin>.unused` in place does nothing: Qt's `QFactoryLoader`
scans the whole directory and loads every file regardless of name.

Focus is then stuck at macro — sharp a few inches out, blurry beyond — because
`droidian-camera`'s `src/qml/main.qml` hardcodes `focusMode: Camera.FocusMacro`.
Tapping appears to work only because the tap handler calls `searchAndLock()`.
The QML is compiled into the binary's qrc, so no config can override it;
`droidian/build-camera.sh` rebuilds the app with a patch that selects the best
mode the HAL actually advertises.

### Build environment gotcha

`quay.io/droidian/build-essential:bookworm-amd64` was last rebuilt in May 2024.
Every Droidian apt repo now fails inside it with
`NO_PUBKEY 5E775B2A27AB0C94`, plus an expired Mobian key, and the build stalls
at dependency resolution having compiled nothing. Use `current-amd64`, which is
rebuilt continuously.

## Device this was built against

OnePlus 6T (fajita), 256 GB, Samsung `KLUEG8U1EA-B0C1`.
LUN0 = 61,677,568 sectors × 4096 = 252.63 GB.
`bootstrap.py` measures the size at runtime, so the 128 GB variant should work,
but it has not been tested.

## Disclaimer

This writes partition tables and bootloader images. It has been run
successfully on exactly one device. Read the scripts before running them.
