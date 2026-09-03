# oneplus6t — flashing and recovery scripts for the OnePlus 6T (fajita)

Working toward a set of scripts that can put any of several operating systems
on a OnePlus 6T, with a known-good Android always recoverable underneath.

**Today this repo does one thing:** restore a device from a destroyed
partition table back to stock OxygenOS 11.1.2.2 (34.J.62), entirely from
Linux, entirely from EDL. That is the floor everything else stands on — if an
experiment bricks the phone, this brings it back.

Planned, not built: postmarketOS, LineageOS, and dual-booting a stock Android
against a self-built Linux. See [Roadmap](#roadmap).

```bash
git clone <this repo> oneplus6t-restore
cd oneplus6t-restore
python3 bootstrap.py                      # downloads + extracts everything
.venv/bin/python restore-oos11.py         # with the phone in EDL
```

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
| Download 2 archives (resumable, SHA256-pinned) | `downloads/` |
| Clone `edl` + `oppo_decrypt` at pinned commits | `edl/`, `oppo_decrypt/` |
| Create venv, install deps, patch the `edl` qfil bug | `.venv/` |
| Decrypt the MSM `.ops` | `msm/extract/prog_firehose_ddr.elf`, `gpt_main0.bin` |
| Extract the OTA `payload.bin` | `stock-oxygenos-11/extracted/*.img` |

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
| `FAST=1` | skip read-back verification |
| `START=n` | resume the flash after an interruption |
| `FORCE_GPT=1` | rewrite the GPT even if it is already consistent |

Sequence: measure LUN0 → finish the GPT template → write and verify primary +
backup → flash 23 partitions across LUN0/1/2/4 → verify each by chunked
read-back SHA256 → clear `misc` → `set_active a` → `format:ext4 userdata` →
reboot.

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
| Restore stock OxygenOS 11 from EDL | done |
| Flash postmarketOS | `flash-pmos.sh`, works, not yet integrated |
| Flash LineageOS | not started |
| Dual-boot Android + a self-built Linux | design open |

The dual-boot goal has one hard constraint worth stating up front, because it
shapes everything else.

This device is A/B. Almost everything is duplicated — `boot`, `system`,
`vendor`, `odm`, `modem`, `xbl`, `abl`, `tz` all exist as `_a` and `_b`, and
`fastboot set_active` picks between them. That part is free.

`userdata` is **not** duplicated. It is a single 246 GB partition shared by
whatever boots. And postmarketOS on fajita installs its rootfs *into*
`userdata` (see `flash-pmos.sh`), so as things stand a pmOS install and an
Android `/data` cannot coexist — each destroys the other.

So a real dual-boot needs one of:

1. **Linux in `system_b`** — 2.86 GB, no repartitioning, but that is a hard
   ceiling and the pmOS rootfs images are already 2.1–3.1 GB.
2. **Repartition `userdata`** into an Android `/data` plus a Linux root. This
   repo can already rebuild the LUN0 GPT from scratch and verify it, so the
   mechanism exists — but it means every OS switch is a wipe-level operation
   and stock OTAs would need care.
3. **File-backed rootfs on shared `/data`** — no repartitioning, but Android
   has to be the one that owns and mounts it.

None of these is obviously right yet.

## Device this was built against

OnePlus 6T (fajita), 256 GB, Samsung `KLUEG8U1EA-B0C1`.
LUN0 = 61,677,568 sectors × 4096 = 252.63 GB.
`bootstrap.py` measures the size at runtime, so the 128 GB variant should work,
but it has not been tested.

## Disclaimer

This writes partition tables and bootloader images. It has been run
successfully on exactly one device. Read the scripts before running them.
