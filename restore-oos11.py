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
    PHASE=edl    run only the EDL stage
    PHASE=fb     run only the fastboot stage
    DRY=1        resolve and size-check every partition, write nothing
    FAST=1       skip the read-back SHA256 verification
    FORCE_GPT=1  rewrite the GPT even if the device already has a valid one
    START=n      resume the flash at the nth partition after an interruption

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
import subprocess
import sys
import time
import zlib

# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------

ROOT = os.path.dirname(os.path.abspath(__file__))
EDL_DIR = f"{ROOT}/edl"
LOADER = f"{ROOT}/msm/extract/prog_firehose_ddr.elf"
GPT_TEMPLATE = f"{ROOT}/msm/extract/gpt_main0.bin"
IMG_DIR = f"{ROOT}/stock-oxygenos-11/extracted"
WORK = f"{ROOT}/.work"

SEC = 4096
FIRST_USABLE = 6          # entry array occupies LBA2..5
GROW = "userdata"         # settings.xml: GrowLastPartToFillDisk="true"
                          # provision_samsung.xml: LUNtoGrow="0"

# /data must be ext4. vendor.img's fstab.qcom says:
#   .../userdata /data ext4 ... wait,check,fileencryption=ice,quota
# There is no `formattable` flag, so a wrong filesystem type is an
# unrecoverable mount failure -> bootloop. `fastboot -w` gets this wrong: it
# asks the bootloader, which answers f2fs.
DATA_FS = "ext4"

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


def build_gpt(total, template=GPT_TEMPLATE, verbose=True):
    """Finish the MSM template for a LUN of `total` sectors.

    Returns (primary 6 sectors, backup 5 sectors). Aborts if the CRC routines
    cannot reproduce the template's own stored CRCs, which would mean the
    header layout assumption is wrong.
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

    if verbose:
        print(f"  {GROW}: grown to {last_usable}"
              f" ({(last_usable - start + 1) * SEC / 1e9:.1f} GB)")
    return primary, backup


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


def set_bcb_fastboot(fire, opts):
    """Ask the bootloader to stop in fastboot on the next boot.

    bootloader_message.command lives at offset 0 of misc. Also clears any
    stale command that would otherwise divert the boot.
    """
    res = fire.detect_partition(opts, "misc")
    if not res[0]:
        return False
    lun, p = res[1], res[2]
    bcb = bytearray(SEC)
    cmd = b"bootonce-bootloader"
    bcb[0:len(cmd)] = cmd
    path = f"{WORK}/bcb.bin"
    open(path, "wb").write(bytes(bcb))
    return fire.cmd_program(lun, p.sector, path, display=False)


# --------------------------------------------------------------------------
# phases
# --------------------------------------------------------------------------

def phase_edl():
    dry = os.environ.get("DRY") == "1"
    print("\n=== EDL phase ===")
    api = connect()
    fire = api.edl.fh.firehose
    opts = api.edl.args

    print("\n[1/5] sizing LUN0")
    total, existing = lun0_sectors(fire)
    print(f"  LUN0 = {total} sectors ({total * SEC / 1e9:.2f} GB)")

    print("\n[2/5] partition table")
    valid = existing is not None and existing["last"] == total - FIRST_USABLE
    if valid and os.environ.get("FORCE_GPT") != "1":
        print("  device already has a consistent GPT; keeping it "
              "(FORCE_GPT=1 to rewrite)")
    else:
        pri, bak = build_gpt(total)
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
            print(f"  {name:<14} {'ok' if ok else 'MISMATCH'}")
            if not ok:
                bad.append(name)
        if bad:
            raise SystemExit(f"ABORT: verification failed: {', '.join(bad)}")
        print("  every partition matches its image")

    print("\nrequesting fastboot on next boot, then resetting")
    if not set_bcb_fastboot(fire, opts):
        print("  (could not set the boot control block; if the phone does not"
              " stop in fastboot, enter it manually)")
    fire.cmd_reset()
    api.deinit()


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

    print(f"  formatting /data as {DATA_FS}"
          f" (fastboot -w would use the bootloader's f2fs answer and bootloop)")
    r = fb("format:" + DATA_FS, "userdata")
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
    for path in (LOADER, GPT_TEMPLATE, IMG_DIR):
        if not os.path.exists(path):
            raise SystemExit(f"ABORT: missing {path}")

    phase = os.environ.get("PHASE")
    if phase == "edl":
        phase_edl()
    elif phase == "fb":
        phase_fastboot()
    else:
        if not in_edl():
            raise SystemExit(
                "No device at 05c6:9008.\n"
                "Enter EDL: power off fully, then hold Volume Up + Volume Down\n"
                "together and plug in USB. The screen stays black.\n"
                "(Already past the EDL stage? Use PHASE=fb.)")
        phase_edl()
        if os.environ.get("DRY") != "1":
            time.sleep(10)
            phase_fastboot()


if __name__ == "__main__":
    main()
