# Provisioning pipeline: any device state to dual-boot OOS9 + Droidian

**Status:** design approved, not yet implemented
**Date:** 2026-09-04
**Related:** `2026-09-04-droidian-adaptation-packaging-design.md`

## Goal

Take a OnePlus 6T in **any** state and bring it to dual-boot OxygenOS 9 +
Droidian, skipping whatever is already correct. Reaching that state must
require no manual step on the device, ever.

## The invariant

> Every fix — those already found and any discovered later — must be
> expressed as a build artifact. No fix may live only as a manual `ssh` plus
> `chmod` / `systemctl` / `dpkg-divert` on the running device.

If a fix cannot be expressed as a `.deb`, a file baked into `rootfs.img`, or a
flashing step, that is a design defect to solve, not an exception to document.

This is not theoretical. Four fixes exist today and only one satisfies the
invariant:

| Fix | Form today | Survives reinstall |
|---|---|---|
| udev rules: `hwbinder`, `vndbinder`, `kgsl-3d0`, `ion` | runtime | **no** |
| polkit socket mask + `dpkg-statoverride 4755` | runtime | **no** |
| `dpkg-divert` of `libgstcamerabin.so` | runtime | **no** |
| patched `droidian-camera` | `.deb` | yes |

The first three would be destroyed by the very reinstall this pipeline
performs. They must be packaged **before** the first full run.

## Three scripts

The work splits across two machines: a worker with cores and a container
runtime, and the machine the phone is plugged into. The decision of *what to
build* belongs to the machine that can see the phone; the building belongs to
the worker.

| Script | Runs on | Responsibility |
|---|---|---|
| `check-env.sh [build\|flash\|all]` | either | verify host prerequisites for a role |
| `build.sh [--plan F \| targets…]` | worker | produce artifacts; never touches a phone |
| `provision.sh` | phone host | probe, decide, flash, verify |

`check-env.sh` already exists but its profiles (`restore`, `droidian`) cut
along the wrong axis. Re-split by role:

- **build** — podman, binfmt `qemu-aarch64` **with the F flag**, `/dev/fuse`,
  `ar`, `tar`, `git`, `curl`, `python3`
- **flash** — `fastboot`, e2fsprogs (`debugfs` reads `/data`'s filesystem type
  out of the release's own `vendor.img`), `unrar` for the MSM `.ops`, the
  python venv for `edl` + `paramiko`, USB access
- **remote** — only when `BUILD_HOST` is set: ssh reachability and a repo
  checkout on the worker. Neither `build` nor `flash` covers this, and it is
  exactly the kind of thing that fails at the worst moment.

## The composable seam

```
workstation                                worker (taichi)
-----------                                ---------------
provision.sh --plan-only > plan.json
        |  probes the device, decides
        |  what is missing
        +-------- plan.json ------------>  build.sh --plan plan.json
                                                   |
        <-------- artifacts + manifest.json -------+
provision.sh --artifacts ./out
```

`plan.json` describes **what needs building**, not what to flash. It is a
small file, so it can be moved by any means. `BUILD_HOST=taichi provision.sh`
collapses this into a single invocation by driving the transfer itself, but
the two-step split stays the primitive — it works with no ssh trust between
the machines, and it keeps `build.sh` runnable standalone.

`build.sh` emits `manifest.json` alongside the artifacts: name, version and
sha256 of everything it produced. `provision.sh` consumes that to decide
whether a flash phase can be skipped.

## Skip detection

**Probe actual content by default; full hash on demand.**

Normal runs read cheap evidence from the device itself — `vendor`/`system`
build fingerprints, GPT layout and partition sizes, `dpkg` versions inside
`rootfs.img`, the active slot. No state file is written or trusted.

A state marker recording "what the pipeline last did" was considered and
rejected: it silently lies the moment anything changes outside the pipeline,
and this repo has already been bricked once by trusting a claim over reality
— the MSM `gpt_main0.bin` template *claimed* to be a valid GPT and was not.

`VERIFY=1` upgrades every probe to a full sha256 comparison, reusing the
chunked read-back verification `restore-android.py` already implements. It is
opt-in because hashing ~9.7 GB of userdata on every run defeats the point of
skipping. This matches the existing flag style: `FAST=1`, `DRY=1`,
`FORCE_GPT=1`, `START=n`.

## Phases

Each phase is independently skippable and decides for itself by probing.

| Phase | Skip when | Destructive |
|---|---|---|
| `edl` | vendor fingerprint is OOS9 `9.0.17` **and** the GPT already has `linuxroot` | **yes** — rewrites the GPT |
| `boot` | `boot_b` matches the artifact's sha256 | no |
| `data` | `linuxroot` holds our rootfs with the expected package versions | **yes** |
| `activate` | `current-slot` is already `b` | no |
| `verify` | never skipped | no |

Probing adapts to however the phone arrives — partitions read through
firehose in EDL, `getvar` in fastboot, ssh on a booted system.

### Device states the entry point must handle

| State | USB ID | Access |
|---|---|---|
| EDL | `05c6:9008` | firehose via `edl` |
| fastboot | `18d1:d00d` | `fastboot` |
| halium initramfs debug | `18d1:d001` | telnet `192.168.2.15:23` |
| kernel panic / ramdump | `05c6:900e` | `droidian/dump-ramoops.py` |
| booted Droidian | `0fce:7169` | ssh `10.15.19.82` |
| booted Android | varies | adb |
| powered off | none | prompt for the key combo |

### `verify` enforces the invariant

`verify` is the phase that makes the invariant real. It asserts the
*user-visible* outcome, not that a file exists:

- `phosh` is `active` with a low restart count
- `phoc` reports `GL renderer: Adreno (TM) 630` — the hardware path, not the
  pixman software fallback
- `/dev/hwbinder` is `0666`, `/dev/kgsl-3d0` is `0666 system:system`
- `/dev/diag` is **still** `0600` — the deny default held
- `/dev/input/event0` is **still** `root:android_input` — the safety
  invariant held and we did not revert a working convention
- polkit authenticates without manual intervention
- the camera log shows the aal path and **no** `CameraBin error`

If a future fix regresses because someone applied it by hand instead of
packaging it, `verify` fails and says so. That is the point.

## Risks

- **`LAYOUT=dualboot` has never touched hardware.** It is code-complete with a
  passing selftest, but the `edl` phase rewrites the partition table. This is
  the highest-risk step in the project. That phase must refuse to run without
  an explicit acknowledgement on first use — not to protect data (there is
  none worth keeping) but because a half-written GPT costs a full EDL recovery
  cycle.
- **`fastboot -w` bootloops this device** and `edl qfil` destroys the LUN0 GPT.
  Both are already guarded; the pipeline must not reintroduce either.
- **A/B OTA on the Android side overwrites `boot_b`** — the Droidian kernel,
  though not `linuxroot`. Expect to re-run the `boot` phase after an Android
  update.

## Dual-boot mechanism

Verified on hardware, not assumed:

- `scripts/halium` line 716 honours a **`datapart=`** kernel cmdline override
  for the data partition, so Droidian can be pointed at `linuxroot` instead of
  `userdata`.
- It is set via `KERNEL_BOOTIMAGE_CMDLINE` in
  `droidian/packaging/debian/kernel-info.mk`.
- `vendor_b`'s fingerprint is **identical** to `vendor_a`
  (`OnePlus/OnePlus6T/OnePlus6T:9/PKQ1.180716.001/1909112330`), so slot b is
  safe for Droidian with no vendor reflash.

```
fastboot set_active a  ->  boot_a + system_a + vendor_a + userdata  ->  OxygenOS 9
fastboot set_active b  ->  boot_b + vendor_b + linuxroot            ->  Droidian
```

Neither side can damage the other: Android mounts `/data` by name and nothing
in any fstab references `linuxroot`, while Droidian is pointed away from
`userdata` entirely by `datapart=`.
