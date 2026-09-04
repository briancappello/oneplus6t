#!/usr/bin/env python3
"""OnePlus 6T (fajita): full recovery to stock OxygenOS 11 from EDL.

Rebuilds the LUN0 partition table, flashes the OOS11 image set, verifies every
write by reading it back, then formats /data correctly and reboots.

    ENTER EDL: power off fully, then hold Volume Up + Volume Down together and
    plug in USB. The screen stays black. `lsusb` should show 05c6:9008.

    python restore-oos11.py

Flags (environment variables, because edl's module runs docopt over sys.argv
and would reject normal command-line options):

    SELFTEST=1   offline only: build the GPT and check it, touch no hardware
    PHASE=gpt    write only the partition table, flash nothing
    PHASE=edl    run only the EDL stage
    PHASE=fb     run only the fastboot stage
    DRY=1        resolve and size-check every partition, write nothing
    FAST=1       skip the read-back SHA256 verification
    FORCE_GPT=1  rewrite the GPT even if the device already has a valid one
    START=n      resume the flash at the nth partition after an interruption
    LAYOUT=dualboot
                 split userdata 50/50 and add a linuxroot partition for a
                 second OS. Nothing else moves, and Android needs no change
                 because it mounts /data by name.

Background: this exists because `edl qfil` destroys the LUN0 GPT on this
device. The MSM .ops ships gpt_main0.bin as an unfinished template
(last_usable_lba=0, backup_lba=0, userdata length 0) that MSM's own patch0.xml
is supposed to complete -- and oppo_decrypt never extracts a patch0.xml.
edl derives NUM_DISK_SECTORS from gpt.py's
`totalsectors = first_usable_lba + last_usable_lba`, which yields 6 for that
template, so `start_sector="NUM_DISK_SECTORS-5."` evaluates to 1 and the backup
GPT lands on top of the primary. This script finishes the template properly
instead: it measures the real LUN size, grows userdata to fill it, and
recomputes both CRC32s.
"""

import hashlib
import os
import struct
import shutil
import subprocess
import sys
import time
import uuid
import zlib

# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------

ROOT = os.path.dirname(os.path.abspath(__file__))
EDL_DIR = f"{ROOT}/edl"
LOADER = f"{ROOT}/msm/extract/prog_firehose_ddr.elf"
GPT_TEMPLATE = f"{ROOT}/msm/extract/gpt_main0.bin"
RELEASE = os.environ.get("RELEASE", "oos11")
IMG_DIR = f"{ROOT}/releases/{RELEASE}/images"
WORK = f"{ROOT}/.work"

SEC = 4096
FIRST_USABLE = 6          # entry array occupies LBA2..5
GROW = "userdata"         # settings.xml: GrowLastPartToFillDisk="true"
                          # provision_samsung.xml: LUNtoGrow="0"

# LAYOUT=dualboot splits the userdata region 50/50 and adds a partition for a
# second OS. Android mounts /data by name, so it just sees a smaller /data and
# needs no modification; nothing in any fstab references linuxroot, so Android
# never touches it. postmarketOS locates its rootfs with `blkid --uuid` (see
# init_functions.sh: find_root_partition -> find_partition), not by partition
# name, so a stock pmOS image works here unmodified.
LINUX_PART = "linuxroot"
SPLIT_ALIGN = 4096        # 16 MiB; the UFS erase block is 8 KiB
# Fixed so that rebuilding the same layout twice produces the same table.
LINUX_UUID = "5f8c6d21-3b47-4a19-9e02-7c1d4a6b8e33"

# The filesystem for /data is READ OUT OF THE RELEASE, never assumed. On OOS11
# vendor.img's fstab.qcom says:
#   .../userdata /data ext4 ... wait,check,fileencryption=ice,quota
# There is no `formattable` flag, so a wrong type is an unrecoverable mount
# failure -> bootloop. `fastboot -w` gets this wrong: it asks the bootloader,
# which answers f2fs. Different OxygenOS versions could legitimately differ,
# so derive it per release rather than hardcoding one answer.
DATA_FS_FALLBACK = "ext4"

# Images in IMG_DIR deliberately not flashed.
SKIP = {
    # No such partition exists on fajita. Verified by dumping the GPT of every
    # LUN 0..5; they are in the payload for other variants. Neither appears in
    # any fstab, and care_map.pb verity-covers only system and vendor.
    "reserve": "no such partition on this device",
    "india": "no such partition on this device",
    # Exists, but holds OEM NV backup data. Leave the device's own copy.
    "oem_stanvbk": "device-specific NV backup, left alone",
}

sys.path.insert(0, EDL_DIR)

# --------------------------------------------------------------------------
# GPT construction (pure, no hardware)
# --------------------------------------------------------------------------

HDR_FMT = "<8sIIIIQQQQ16sQIII"     # up to entries_crc; header_size is 92


def unpack_header(b):
    keys = ("sig", "rev", "hsz", "hcrc", "res", "cur", "bak", "first", "last",
            "dguid", "plba", "nent", "esz", "ecrc")
    return dict(zip(keys, struct.unpack_from(HDR_FMT, b, 0)))


def pack_header(h):
    return struct.pack(HDR_FMT, h["sig"], h["rev"], h["hsz"], h["hcrc"],
                       h["res"], h["cur"], h["bak"], h["first"], h["last"],
                       h["dguid"], h["plba"], h["nent"], h["esz"], h["ecrc"])


def header_crc(h):
    return zlib.crc32(pack_header(dict(h, hcrc=0))[:h["hsz"]]) & 0xFFFFFFFF


def entries_crc(ents, nent, esz):
    return zlib.crc32(ents[:nent * esz]) & 0xFFFFFFFF


def parse_entries(buf, nent, esz):
    out = []
    for i in range(nent):
        e = buf[i * esz:(i + 1) * esz]
        if len(e) < esz or e[:16] == b"\0" * 16:
            continue
        start, end = struct.unpack_from("<QQ", e, 32)
        out.append((e[56:128].decode("utf-16-le").rstrip("\0"), start, end))
    return out


def build_gpt(total, template=GPT_TEMPLATE, verbose=True, dualboot=False):
    """Finish the MSM template for a LUN of `total` sectors.

    Returns (primary 6 sectors, backup 5 sectors). Aborts if the CRC routines
    cannot reproduce the template's own stored CRCs, which would mean the
    header layout assumption is wrong.

    dualboot=True splits the userdata region in half and appends a linuxroot
    partition. userdata keeps its start sector, so no other partition moves.
    """
    src = open(template, "rb").read()
    if len(src) != 6 * SEC:
        raise SystemExit(f"ABORT: {template} is {len(src)} bytes, expected {6 * SEC}")
    mbr = bytearray(src[:SEC])
    hdr = unpack_header(src[SEC:SEC * 2])
    ents = bytearray(src[SEC * 2:SEC * 6])

    if hdr["sig"] != b"EFI PART":
        raise SystemExit("ABORT: template has no EFI PART signature")
    if entries_crc(ents, hdr["nent"], hdr["esz"]) != hdr["ecrc"]:
        raise SystemExit("ABORT: entries CRC self-check failed")
    if header_crc(hdr) != hdr["hcrc"]:
        raise SystemExit("ABORT: header CRC self-check failed")
    if verbose:
        print("  CRC self-check: reproduced the template's own stored CRCs")

    esz = hdr["esz"]
    idx = next((i for i in range(hdr["nent"])
                if ents[i * esz:i * esz + 16] != b"\0" * 16
                and ents[i * esz + 56:i * esz + 128]
                .decode("utf-16-le").rstrip("\0") == GROW), None)
    if idx is None:
        raise SystemExit(f"ABORT: {GROW} not present in template")

    last_usable = total - FIRST_USABLE
    start = struct.unpack_from("<Q", ents, idx * esz + 32)[0]
    if last_usable <= start:
        raise SystemExit(f"ABORT: computed last_usable {last_usable} <= "
                         f"{GROW} start {start}; LUN size looks wrong")

    if dualboot:
        region = last_usable - start + 1
        lr_start = -(-(start + region // 2) // SPLIT_ALIGN) * SPLIT_ALIGN
        if not start < lr_start <= last_usable:
            raise SystemExit("ABORT: cannot place linuxroot inside "
                             f"{start}..{last_usable}")
        struct.pack_into("<Q", ents, idx * esz + 40, lr_start - 1)

        free = next((i for i in range(hdr["nent"])
                     if ents[i * esz:i * esz + 16] == b"\0" * 16), None)
        if free is None:
            raise SystemExit("ABORT: no free GPT entry for linuxroot")
        e = free * esz
        # Reuse userdata's partition type GUID; only the unique GUID, the LBAs
        # and the name differ.
        ents[e:e + 16] = ents[idx * esz:idx * esz + 16]
        ents[e + 16:e + 32] = uuid.UUID(LINUX_UUID).bytes_le
        struct.pack_into("<QQQ", ents, e + 32, lr_start, last_usable, 0)
        name = LINUX_PART.encode("utf-16-le")
        ents[e + 56:e + 128] = name.ljust(72, b"\0")
        if verbose:
            print(f"  {GROW}:    {start}..{lr_start - 1}"
                  f"  ({(lr_start - start) * SEC / 1024 ** 3:.2f} GiB)")
            print(f"  {LINUX_PART}:   {lr_start}..{last_usable}"
                  f"  ({(last_usable - lr_start + 1) * SEC / 1024 ** 3:.2f} GiB)")
    else:
        struct.pack_into("<Q", ents, idx * esz + 40, last_usable)

    pri = dict(hdr, cur=1, bak=total - 1, first=FIRST_USABLE,
               last=last_usable, plba=2)
    pri["ecrc"] = entries_crc(ents, pri["nent"], esz)
    pri["hcrc"] = header_crc(pri)

    bak = dict(pri, cur=total - 1, bak=1, plba=total - 5)
    bak["hcrc"] = header_crc(bak)

    struct.pack_into("<I", mbr, 446 + 12, min(total - 1, 0xFFFFFFFF))
    primary = bytes(mbr) + pack_header(pri).ljust(SEC, b"\0") + bytes(ents)
    backup = bytes(ents) + pack_header(bak).ljust(SEC, b"\0")

    if verbose and not dualboot:
        print(f"  {GROW}: grown to {last_usable}"
              f" ({(last_usable - start + 1) * SEC / 1024 ** 3:.2f} GiB)")
    return primary, backup


def layout_of(primary):
    """Return {name: (start, end)} for a built or read-back primary GPT."""
    h = unpack_header(primary[SEC:SEC * 2])
    return {n: (s, e) for n, s, e in
            parse_entries(primary[SEC * 2:], h["nent"], h["esz"])}


def selftest():
    """Offline check. Fails loudly if the GPT builder ever breaks."""
    print("== selftest (no hardware) ==")
    total = 61_677_568                      # measured on a 256 GB fajita
    pri, bak = build_gpt(total)
    assert len(pri) == 6 * SEC and len(bak) == 5 * SEC

    h = unpack_header(pri[SEC:SEC * 2])
    assert h["cur"] == 1 and h["bak"] == total - 1, "primary LBAs wrong"
    assert h["last"] == total - 6, "last_usable wrong"
    assert header_crc(h) == h["hcrc"], "primary header CRC wrong"
    assert entries_crc(pri[SEC * 2:], h["nent"], h["esz"]) == h["ecrc"]

    b = unpack_header(bak[SEC * 4:])
    assert b["cur"] == total - 1 and b["bak"] == 1, "backup LBAs wrong"
    assert b["plba"] == total - 5, "backup entry LBA wrong"
    assert header_crc(b) == b["hcrc"], "backup header CRC wrong"

    parts = dict((n, (s, e)) for n, s, e in
                 parse_entries(pri[SEC * 2:], h["nent"], h["esz"]))
    assert parts["system_a"] == (85824, 817983), "system_a moved"
    assert parts[GROW][1] == total - 6, "userdata did not fill the disk"
    # every partition must fit inside the usable area and not overlap
    ordered = sorted(parts.values())
    for (s1, e1), (s2, _) in zip(ordered, ordered[1:]):
        assert e1 < s2, f"partitions overlap at {e1}/{s2}"
    assert ordered[0][0] >= FIRST_USABLE and ordered[-1][1] <= h["last"]

    # a wrong size must be rejected, not silently written
    try:
        build_gpt(1000, verbose=False)
    except SystemExit:
        pass
    else:
        raise AssertionError("build_gpt accepted an impossible LUN size")

    print(f"  {len(parts)} partitions, no overlaps, all CRCs verify")

    print("\n  -- dualboot layout --")
    dpri, dbak = build_gpt(total, dualboot=True)
    dh = unpack_header(dpri[SEC:SEC * 2])
    assert header_crc(dh) == dh["hcrc"], "dualboot header CRC wrong"
    assert entries_crc(dpri[SEC * 2:], dh["nent"], dh["esz"]) == dh["ecrc"]
    db = unpack_header(dbak[SEC * 4:])
    assert header_crc(db) == db["hcrc"] and db["ecrc"] == dh["ecrc"]

    d = layout_of(dpri)
    assert LINUX_PART in d, "linuxroot missing"
    ud_s, ud_e = d[GROW]
    lr_s, lr_e = d[LINUX_PART]
    assert ud_s == parts[GROW][0], "userdata start moved"
    assert lr_s == ud_e + 1, "gap or overlap between userdata and linuxroot"
    assert lr_e == dh["last"], "linuxroot does not reach last_usable"
    assert lr_s % SPLIT_ALIGN == 0, "linuxroot start not aligned"
    # every other partition must be byte-identical to the stock layout
    for name, ext in parts.items():
        if name != GROW:
            assert d[name] == ext, f"{name} moved in the dualboot layout"
    # the two halves must account for the whole region, within one alignment
    region = parts[GROW][1] - parts[GROW][0] + 1
    ud_n, lr_n = ud_e - ud_s + 1, lr_e - lr_s + 1
    assert ud_n + lr_n == region, "split does not account for the region"
    # Rounding the boundary up to SPLIT_ALIGN moves it by up to ALIGN-1, which
    # adds to one half and takes from the other, so the worst-case imbalance is
    # 2*ALIGN-1 sectors (~34 MB) plus 1 for an odd-sized region.
    assert abs(ud_n - lr_n) <= 2 * SPLIT_ALIGN, "split is not ~50/50"
    ordered = sorted(d.values())
    for (s1, e1), (s2, _) in zip(ordered, ordered[1:]):
        assert e1 < s2, f"partitions overlap at {e1}/{s2}"
    print(f"  {len(d)} partitions, 50/50 split, nothing else moved")
    print("selftest PASSED")


# --------------------------------------------------------------------------
# device helpers
# --------------------------------------------------------------------------

def connect():
    from edlclient.Library.api import edl_api, EDL_ARGS
    # EDL_ARGS is missing --pagesperblock, which firehose_client reads
    # unconditionally; supply it rather than patching the vendored tree.
    api = edl_api({**EDL_ARGS, "--pagesperblock": None,
                   "--loader": LOADER, "--memory": "ufs"})
    api.init()
    return api


def rd(fire, lun, sec, n):
    r = fire.cmd_read_buffer(lun, sec, n, display=False)
    return bytes(r.data) if r.resp and len(r.data) == n * SEC else None


def lun0_sectors(fire):
    """Size LUN0. Prefer an existing valid GPT; otherwise binary search.

    The search predicate is resp==True: in-range reads succeed, out-of-range
    reads return resp=False with an XML error body. It must stay under 2**32
    because the loader silently truncates larger sector numbers -- reads at
    2**32 and 2**40 both return zeroed data and would send the search to
    2**64.
    """
    head = rd(fire, 0, 1, 1)
    if head and head[:8] == b"EFI PART":
        h = unpack_header(head)
        if h["bak"] > 1 and h["last"] > 0:
            print(f"  existing GPT reports {h['bak'] + 1} sectors")
            return h["bak"] + 1, h
    print("  no usable GPT header; measuring by binary search...")
    lo, hi = 1, (1 << 32) - 1
    if rd(fire, 0, lo, 1) is None:
        raise SystemExit("ABORT: cannot read LUN0 sector 1")
    if rd(fire, 0, hi, 1) is not None:
        raise SystemExit("ABORT: loader is truncating sector numbers")
    while lo + 1 < hi:
        mid = (lo + hi) // 2
        if rd(fire, 0, mid, 1) is not None:
            lo = mid
        else:
            hi = mid
    return lo + 1, None


def resolve(fire, opts, base):
    """Map an image base name onto the device's partitions (A/B or single)."""
    found = []
    for cand in (f"{base}_a", f"{base}_b", base):
        res = fire.detect_partition(opts, cand)
        if res[0]:
            found.append((cand, res[1], res[2]))
    # prefer the A/B pair when both forms somehow resolve
    ab = [f for f in found if f[0] != base]
    return ab or found


def sha_readback(fire, lun, sector, sectors):
    h = hashlib.sha256()
    done = 0
    while done < sectors:
        n = min(4096, sectors - done)       # 16 MB per request, RAM-safe
        r = fire.cmd_read_buffer(lun, sector + done, n, display=False)
        if not r.resp or len(r.data) != n * SEC:
            return None
        h.update(bytes(r.data))
        done += n
    return h.hexdigest()


def sha_image(path, sectors):
    h, total = hashlib.sha256(), sectors * SEC
    with open(path, "rb") as f:
        while total:
            b = f.read(min(1 << 20, total))
            if not b:
                break
            h.update(b)
            total -= len(b)
    h.update(b"\0" * total)                 # device hashed the zero padding
    return h.hexdigest()


def set_bcb(fire, opts, command, recovery=()):
    """Write Android's bootloader control block into misc.

        struct bootloader_message {
            char command[32];    // offset 0
            char status[32];     // offset 32
            char recovery[768];  // offset 64
            ...
        };

    command="boot-recovery" with recovery=["--wipe_data"] is how a factory
    reset is normally requested: recovery boots, formats /data using the OS's
    own idea of the filesystem, and reboots. That is more reliable than our
    `fastboot format`, and unlike it, it does not depend on the phone stopping
    in fastboot at all.

    Writing the whole sector also clears any stale command left behind.
    """
    res = fire.detect_partition(opts, "misc")
    if not res[0]:
        return False
    lun, p = res[1], res[2]
    bcb = bytearray(SEC)
    bcb[0:len(command)] = command.encode()
    if recovery:
        blob = "\n".join(["recovery", *recovery]) + "\n"
        bcb[64:64 + len(blob)] = blob.encode()
    path = f"{WORK}/bcb.bin"
    open(path, "wb").write(bytes(bcb))
    return fire.cmd_program(lun, p.sector, path, display=False)


# --------------------------------------------------------------------------
# phases
# --------------------------------------------------------------------------

def phase_edl(gpt_only=False):
    """Write the partition table, then flash the release image set.

    gpt_only stops after the table is written and verified. Provisioning a
    second OS needs the linuxroot partition created and nothing else touched:
    reflashing the OOS image set over a working device would be both pointless
    and destructive. The GPT work itself is identical either way, so it is
    shared rather than reimplemented -- a hand-rolled second copy of this is
    what wrote a partition table into the sbl1 partition.
    """
    dry = os.environ.get("DRY") == "1"
    print("\n=== EDL phase ===")
    api = connect()
    fire = api.edl.fh.firehose
    opts = api.edl.args

    print("\n[1/5] sizing LUN0")
    total, existing = lun0_sectors(fire)
    print(f"  LUN0 = {total} sectors ({total * SEC / 1e9:.2f} GB)")

    print("\n[2/5] partition table")
    dualboot = os.environ.get("LAYOUT") == "dualboot"
    print(f"  layout: {'dualboot (userdata split 50/50)' if dualboot else 'stock'}")

    # "Consistent" means consistent with the layout being asked for, not just
    # any valid table -- otherwise switching layouts would silently no-op.
    valid = False
    if existing is not None and existing["last"] == total - FIRST_USABLE:
        head = rd(fire, 0, 0, 6)
        if head:
            on_disk = layout_of(head)
            valid = (LINUX_PART in on_disk) == dualboot
    if valid and os.environ.get("FORCE_GPT") != "1":
        print("  device already matches this layout; keeping it "
              "(FORCE_GPT=1 to rewrite)")
    else:
        if dualboot and not dry:
            print("  WARNING: repartitioning destroys everything in /data.")
        pri, bak = build_gpt(total, dualboot=dualboot)
        if dry:
            print("  DRY: would write primary @0 and backup "
                  f"@{total - 5}")
        else:
            for blob, sec in ((pri, 0), (bak, total - 5)):
                path = f"{WORK}/gpt_{sec}.bin"
                open(path, "wb").write(blob)
                if not fire.cmd_program(0, sec, path, display=False):
                    raise SystemExit(f"ABORT: GPT write at {sec} failed")
                if rd(fire, 0, sec, len(blob) // SEC) != blob:
                    raise SystemExit(f"ABORT: GPT read-back at {sec} differs")
                print(f"  wrote + verified {len(blob) // SEC} sectors @ {sec}")

    if gpt_only:
        print("\n  PHASE=gpt: partition table only, leaving every partition"
              " as it is")
        return

    print("\n[3/5] planning the flash")
    plan, missing = [], []
    for img in sorted(os.listdir(IMG_DIR)):
        if not img.endswith(".img"):
            continue
        base = img[:-4]
        path = os.path.join(IMG_DIR, img)
        if base in SKIP:
            print(f"  skip {base:<14} ({SKIP[base]})")
            continue
        targets = resolve(fire, opts, base)
        if not targets:
            missing.append(base)
            print(f"  skip {base:<14} (no matching partition)")
            continue
        need = -(-os.path.getsize(path) // SEC)
        for name, lun, p in targets:
            if need > p.sectors:
                raise SystemExit(
                    f"ABORT: {img} needs {need} sectors, {name} has {p.sectors}")
            plan.append((name, path, lun, p.sector, need))
    print(f"  {len(plan)} partitions to write")
    if dry:
        for name, _, lun, sec, need in plan:
            print(f"    {name:<14} lun{lun} @{sec} {need} sectors")
        api.deinit()
        return

    print("\n[4/5] flashing")
    start_at = int(os.environ.get("START", "1"))
    for n, (name, path, lun, sec, _) in enumerate(plan, 1):
        if n < start_at:
            continue
        print(f"  [{n}/{len(plan)}] {name}", flush=True)
        if not fire.cmd_program(lun, sec, path, display=False):
            raise SystemExit(f"ABORT: writing {name} failed (resume: START={n})")

    if os.environ.get("FAST") == "1":
        print("\n[5/5] verification skipped (FAST=1)")
    else:
        print("\n[5/5] verifying by read-back")
        bad = []
        for name, path, lun, sec, need in plan:
            got = sha_readback(fire, lun, sec, need)
            want = sha_image(path, need)
            ok = got == want
            print(f"  {name:<14} {'ok' if ok else 'MISMATCH'}", flush=True)
            if not ok:
                bad.append(name)
        if bad:
            raise SystemExit(f"ABORT: verification failed: {', '.join(bad)}")
        print("  every partition matches its image")

    # /data still holds the previous OS's filesystem and encryption keys, so
    # it must be reformatted. Ask recovery to do it: it is the only method
    # that works without the phone stopping in fastboot, and it uses the
    # freshly flashed OS's own notion of the filesystem.
    if os.environ.get("WIPE") == "0":
        print("\nWIPE=0: leaving /data alone, requesting fastboot")
        ok = set_bcb(fire, opts, "bootonce-bootloader")
    else:
        print("\nrequesting a recovery data wipe on next boot, then resetting")
        ok = set_bcb(fire, opts, "boot-recovery", ["--wipe_data"])
    if not ok:
        print("  WARNING: could not write the boot control block. If the phone"
              " lands in recovery, choose 'Erase everything' by hand.")
    fire.cmd_reset()
    api.deinit()


def data_fs():
    """Read the filesystem type for /data out of this release's vendor.img.

    Uses debugfs so nothing has to be mounted and no root is needed. Falls
    back with a warning rather than guessing silently, because getting this
    wrong bootloops the device with no recovery path.
    """
    vendor = os.path.join(IMG_DIR, "vendor.img")
    if not (os.path.exists(vendor) and shutil.which("debugfs")):
        print(f"  WARNING: cannot inspect {vendor}; assuming {DATA_FS_FALLBACK}")
        return DATA_FS_FALLBACK
    for fstab in ("fstab.qcom", "fstab_qcom", "fstab.default"):
        r = subprocess.run(["debugfs", "-R", f"cat /etc/{fstab}", vendor],
                           capture_output=True, text=True)
        for line in r.stdout.splitlines():
            line = line.strip()
            if line.startswith("#") or "userdata" not in line:
                continue
            parts = line.split()
            # <src> <mnt_point> <type> <mnt_flags> <fs_mgr_flags>
            if len(parts) >= 3 and parts[1] == "/data":
                print(f"  /data type from {fstab}: {parts[2]}")
                return parts[2]
    print(f"  WARNING: no /data line found in vendor.img; "
          f"assuming {DATA_FS_FALLBACK}")
    return DATA_FS_FALLBACK


def phase_wipe():
    """Request a recovery data wipe and reboot. Nothing else is touched.

    Useful on its own, and it is the cheap way to test the boot control block
    without repeating a full flash.
    """
    print("\n=== wipe phase ===")
    api = connect()
    fire = api.edl.fh.firehose
    ok = set_bcb(fire, api.edl.args, "boot-recovery", ["--wipe_data"])
    print("  boot control block:", "written" if ok else "FAILED")
    fire.cmd_reset()
    api.deinit()
    print("  reset issued; recovery should wipe /data and boot the OS")


def fb(*args, timeout=900):
    return subprocess.run(["fastboot", *args], capture_output=True,
                          text=True, timeout=timeout)


def phase_fastboot():
    print("\n=== fastboot phase ===")
    print("  waiting for the device in fastboot...")
    for _ in range(60):
        if fb("devices", timeout=15).stdout.strip():
            break
        time.sleep(5)
    else:
        raise SystemExit(
            "ABORT: no fastboot device. Boot the phone to fastboot "
            "(Volume Up + Volume Down + Power from off) and rerun with PHASE=fb")
    print(f"  {fb('devices').stdout.strip()}")

    # Slot A gets flagged unbootable after failed boots. That flag lives in the
    # GPT attribute bits on LUN4, not in misc, so wiping misc does not clear
    # it; set_active does.
    print("  clearing slot flags (set_active a)")
    fb("set_active", "a")

    fs = data_fs()
    print(f"  formatting /data as {fs}"
          f" (fastboot -w would use the bootloader's f2fs answer and bootloop)")
    r = fb("format:" + fs, "userdata")
    if r.returncode != 0:
        raise SystemExit(f"ABORT: format failed:\n{r.stdout}\n{r.stderr}")

    state = fb("getvar", "all").stderr
    for line in state.splitlines():
        if any(k in line for k in ("slot-unbootable", "current-slot",
                                   "partition-size:userdata")):
            print("  " + line.strip())

    print("  rebooting")
    fb("reboot")
    print("\nDone. First boot after a wipe takes several minutes.")


# --------------------------------------------------------------------------

def in_edl():
    return "05c6:9008" in subprocess.run(["lsusb"], capture_output=True,
                                         text=True).stdout


def main():
    os.makedirs(WORK, exist_ok=True)
    if os.environ.get("SELFTEST") == "1":
        selftest()
        return
    phase = os.environ.get("PHASE")
    # Writing a partition table needs the loader and the template. It does not
    # need the release image set, and demanding it would block repartitioning
    # on a download that is never read.
    required = [LOADER, GPT_TEMPLATE]
    if phase != "gpt":
        required.append(IMG_DIR)
    for path in required:
        if not os.path.exists(path):
            raise SystemExit(f"ABORT: missing {path}")

    if phase == "gpt":
        if not in_edl():
            raise SystemExit("PHASE=gpt needs the phone in EDL (05c6:9008)")
        phase_edl(gpt_only=True)
    elif phase == "edl":
        phase_edl()
    elif phase == "fb":
        phase_fastboot()
    elif phase == "wipe":
        if not in_edl():
            raise SystemExit("PHASE=wipe needs the phone in EDL (05c6:9008)")
        phase_wipe()
    else:
        if not in_edl():
            raise SystemExit(
                "No device at 05c6:9008.\n"
                "Enter EDL: power off fully, then hold Volume Up + Volume Down\n"
                "together and plug in USB. The screen stays black.\n"
                "(Already past the EDL stage? Use PHASE=fb.)")
        phase_edl()
        if os.environ.get("DRY") == "1":
            return
        # Two possible landings: recovery does the wipe and boots the OS (the
        # normal path), or the bootloader stops in fastboot because a slot is
        # flagged unbootable. Only the second needs anything more from us.
        print("\nwaiting to see where the phone lands...")
        for _ in range(24):
            time.sleep(5)
            if fb("devices", timeout=10).stdout.strip():
                print("  stopped in fastboot; finishing there")
                phase_fastboot()
                return
        print("  no fastboot device, so recovery is handling the wipe.")
        print("  First boot after a wipe takes several minutes; leave it alone.")


if __name__ == "__main__":
    main()
