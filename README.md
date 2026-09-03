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
| `LAYOUT=dualboot` | split `userdata` 50/50 and add a `linuxroot` partition |

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
| Dual-boot Android + a self-built Linux | GPT layout done, boot side not started |

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

```
fastboot set_active a   → boot_a + system_a + vendor_a   → Android
fastboot set_active b   → boot_b + linuxroot             → Linux
```

`system_b` and `odm_b` (3 GiB) go unused, and are available for a second
Android later.

### Known hazards

- **Repartitioning wipes `/data`.** There is no in-place shrink here.
- **`LAYOUT=dualboot` is not the default.** Running the restore without it
  rebuilds the stock table and destroys `linuxroot`.
- **A/B OTAs write the inactive slot.** A stock OxygenOS update installed
  while on slot A will overwrite `boot_b` — the Linux kernel, though not the
  rootfs. Expect to re-flash the kernel after an Android update.
- **AVB.** A custom `boot_b` will not verify against stock `vbmeta`. It needs
  `fastboot --disable-verity --disable-verification flash vbmeta_b`.
- **No shared storage.** Android's `/data` is `fileencryption=ice`, so Linux
  cannot read it. A shared area would have to be a third partition.

## Device this was built against

OnePlus 6T (fajita), 256 GB, Samsung `KLUEG8U1EA-B0C1`.
LUN0 = 61,677,568 sectors × 4096 = 252.63 GB.
`bootstrap.py` measures the size at runtime, so the 128 GB variant should work,
but it has not been tested.

## Disclaimer

This writes partition tables and bootloader images. It has been run
successfully on exactly one device. Read the scripts before running them.
