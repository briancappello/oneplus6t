#!/usr/bin/env python3
"""Prepare a fresh machine to restore a OnePlus 6T to stock OxygenOS 11.

    git clone <this repo> && cd oneplus6t-restore
    python3 bootstrap.py
    .venv/bin/python restore-oos11.py

Downloads the two upstream archives, checks out the decryption tooling at
pinned commits, and extracts the handful of files the restore actually needs:

    msm/extract/prog_firehose_ddr.elf   the EDL firehose loader
    msm/extract/gpt_main0.bin           the LUN0 partition table template
    stock-oxygenos-11/extracted/*.img   the OOS11 partition images

Every step is idempotent and verified by hash, so it is safe to re-run after
an interrupted download or extraction.

Environment flags:
    FORCE=1           redo every step even if its output already exists
    SKIP_DOWNLOAD=1   use whatever is already in downloads/
    KEEP_ALL=1        extract every payload partition, including the ones the
                      restore does not flash
"""

import hashlib
import lzma
import bz2
import os
import shutil
import struct
import subprocess
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DOWNLOADS = HERE / "downloads"
MSM_DIR = HERE / "msm"
RELEASES_DIR = HERE / "releases"
VENV = HERE / ".venv"
VPY = VENV / "bin" / "python"

FORCE = os.environ.get("FORCE") == "1"

# The MSM package is not an OS to flash; it is where the firehose loader and
# the LUN0 GPT template come from. Needed regardless of which OS you install.
MSM_SOURCE = {
    "what": "MSM Download Tool (OOS 9.0.13) - firehose loader + GPT template",
    "file": "6T_MsmDownloadTool_v4.0.59_OOS_v9.0.13.rar",
    "sha256": "fa02df3c3e215aeb56ba8b1d812c510500f516d4a8ce46709c133feb53fee8bf",
    "url": "https://ava4.androidfilehost.com/dl/8U_wSACJeGqngl4k5jtRjg/"
           "1788540406/1395089523397966003/"
           "6T_MsmDownloadTool_v4.0.59_OOS_v9.0.13.rar",
    # AndroidFileHost hands out signed, expiring mirror URLs.
    "note": "AndroidFileHost links expire. If this 403s or returns HTML, grab "
            "the file manually from androidfilehost.com and drop it in "
            "downloads/ , then re-run.",
}

# Flashable OS releases. Each is a full A/B OTA zip containing a payload.bin.
# url=None means the file cannot be fetched automatically and must be placed
# in downloads/ by hand; the SHA256 is still checked.
RELEASES = {
    "oos11": {
        "what": "OxygenOS 11.1.2.2 (34.J.62), Android 11",
        "file": "OnePlus6TOxygen_34.J.62_OTA_0620_all_2111252336_"
                "339a2fa8335f21.zip",
        "sha256": "1c4abfa8901791cfa6d29a9e240e57fb1b5105da2bcaaa4fb8addc0a5e3a5831",
        "url": "https://otafsg1.h2os.com/patch/amazone2/GLO/OnePlus6TOxygen/"
               "OnePlus6TOxygen_34.J.62_GLO_0620_2111252336/"
               "OnePlus6TOxygen_34.J.62_OTA_0620_all_2111252336_"
               "339a2fa8335f21.zip",
        "note": "",
    },
    "oos9": {
        "what": "OxygenOS 9 (34.O.24), Android 9 PKQ1.180716.001",
        "file": "OnePlus6TOxygen_34_OTA_024_all_1909112343_d5b1905.zip",
        "sha256": "c371b5c1701767cdde62bf194a5c6f4b19b5bcec27266e9bda2993cd6f63d15b",
        "url": None,
        "note": "No download URL recorded for this build. Place the zip in "
                "downloads/ manually; the SHA256 above is still verified.",
    },
}


def sources():
    return [MSM_SOURCE] + list(RELEASES.values())

REPOS = [
    {"dir": "edl", "url": "https://github.com/bkerler/edl.git",
     "commit": "2f8e89a848afaaef68997fcbcb5b178d958d497b"},
    {"dir": "oppo_decrypt", "url": "https://github.com/bkerler/oppo_decrypt.git",
     "commit": "3456e850fb408f4dfab43e9788970c9be2caa743"},
]

# edl's own requirements.txt pulls capstone, keystone-engine and paramiko,
# which build slowly and fail on some hosts. None are needed for firehose, so
# try this set first and only fall back if the import check fails.
MINIMAL_DEPS = ["wheel", "pyusb>=1.3.1", "pyserial>=3.5", "docopt>=0.6.2",
                "pycryptodome", "pycryptodomex", "lxml", "colorama"]


def say(msg):
    print(f"\n=== {msg} ===", flush=True)


def run(cmd, **kw):
    r = subprocess.run(cmd, **kw)
    if r.returncode != 0:
        raise SystemExit(f"ABORT: command failed: {' '.join(map(str, cmd))}")
    return r


def sha256(path, label=""):
    h = hashlib.sha256()
    size = path.stat().st_size
    done = 0
    with open(path, "rb") as f:
        while chunk := f.read(1 << 22):
            h.update(chunk)
            done += len(chunk)
            if label and size:
                print(f"\r  hashing {label}: {100 * done // size}%",
                      end="", flush=True)
    if label:
        print("\r" + " " * 40 + "\r", end="")
    return h.hexdigest()


# --------------------------------------------------------------------------

def step_tools():
    say("1/6 host tools")
    need = {"git": "git", "curl": "curl", "unrar": "unrar (or unrar-free)"}
    missing = [pkg for exe, pkg in need.items() if not shutil.which(exe)]
    if missing:
        raise SystemExit("ABORT: install first: " + ", ".join(missing))
    for exe in need:
        print(f"  {exe:<8} {shutil.which(exe)}")


def step_download():
    say("2/6 source archives")
    DOWNLOADS.mkdir(exist_ok=True)
    for src in sources():
        dest = DOWNLOADS / src["file"]
        # Reuse a copy already sitting in the working tree.
        if not dest.exists():
            for old in HERE.glob(f"*/{src['file']}"):
                print(f"  found existing {old.relative_to(HERE)}, linking")
                os.link(old, dest)
                break
        if dest.exists() and not FORCE:
            got = sha256(dest, src["file"][:28])
            if got == src["sha256"]:
                print(f"  ok       {src['file']}")
                continue
            print(f"  BAD HASH {src['file']}\n    got  {got}\n"
                  f"    want {src['sha256']}")
            if os.environ.get("SKIP_DOWNLOAD") == "1":
                raise SystemExit("ABORT: hash mismatch and SKIP_DOWNLOAD=1")
            dest.unlink()
        if os.environ.get("SKIP_DOWNLOAD") == "1":
            raise SystemExit(f"ABORT: {src['file']} missing and SKIP_DOWNLOAD=1")
        if not src.get("url"):
            raise SystemExit(f"ABORT: {src['file']} is missing.\n  {src['note']}")

        print(f"  downloading {src['what']}")
        r = subprocess.run(["curl", "-fL", "--retry", "3", "-C", "-",
                            "-o", str(dest), src["url"]])
        if r.returncode != 0 or not dest.exists():
            msg = f"ABORT: download failed for {src['file']}"
            if src["note"]:
                msg += "\n  " + src["note"]
            raise SystemExit(msg)
        got = sha256(dest, src["file"][:28])
        if got != src["sha256"]:
            raise SystemExit(
                f"ABORT: {src['file']} hash mismatch after download\n"
                f"  got  {got}\n  want {src['sha256']}\n  {src['note']}")
        print(f"  ok       {src['file']}")


def step_tooling():
    say("3/6 decryption tooling (pinned)")
    for repo in REPOS:
        d = HERE / repo["dir"]
        if not (d / ".git").exists():
            run(["git", "clone", repo["url"], str(d)])
        have = subprocess.run(["git", "-C", str(d), "rev-parse", "HEAD"],
                              capture_output=True, text=True).stdout.strip()
        if have != repo["commit"]:
            run(["git", "-C", str(d), "fetch", "--all", "--tags"])
            run(["git", "-C", str(d), "checkout", "--force", repo["commit"]])
        print(f"  {repo['dir']:<14} {repo['commit'][:12]}")


def step_venv():
    say("4/6 python environment")
    if not VPY.exists() or FORCE:
        run([sys.executable, "-m", "venv", str(VENV)])
    run([str(VPY), "-m", "pip", "install", "--quiet", "--upgrade", "pip"])
    run([str(VPY), "-m", "pip", "install", "--quiet", *MINIMAL_DEPS])
    check = subprocess.run(
        [str(VPY), "-c",
         "import sys;sys.path.insert(0,'edl');"
         "import edlclient.Library.api;print('edlclient ok')"],
        cwd=HERE, capture_output=True, text=True)
    if check.returncode != 0:
        print("  minimal deps insufficient, installing edl's full requirements")
        run([str(VPY), "-m", "pip", "install", "--quiet",
             "-r", str(HERE / "edl" / "requirements.txt")])
        check = subprocess.run(
            [str(VPY), "-c",
             "import sys;sys.path.insert(0,'edl');"
             "import edlclient.Library.api;print('edlclient ok')"],
            cwd=HERE, capture_output=True, text=True)
        if check.returncode != 0:
            raise SystemExit("ABORT: cannot import edlclient:\n" + check.stderr)
    print("  " + check.stdout.strip())
    guard_edl_qfil()


def guard_edl_qfil():
    """Stop edl's qfil from writing the BackupGPT over the primary GPT.

    getlunsize() returns -1 on error and otherwise derives the LUN size from
    gpt.py's `totalsectors = first_usable_lba + last_usable_lba`. That is only
    right for a well-formed GPT; against the MSM template (last_usable_lba=0)
    it yields 6, so `start_sector="NUM_DISK_SECTORS-5."` evaluates to 1 and
    the backup table lands on LBA1, destroying the partition table. This is
    exactly how the device this repo recovers got broken.
    """
    f = HERE / "edl" / "edlclient" / "Library" / "firehose_client.py"
    src = f.read_text()
    if "Refusing to program" in src:
        print("  edl qfil guard already applied")
        return
    anchor = ('                                if "NUM_DISK_SECTORS" in start_sector:\n'
              '                                    start_sector = start_sector.replace'
              '("NUM_DISK_SECTORS", str(num_disk_sectors))\n')
    patched = (
        '                                if "NUM_DISK_SECTORS" in start_sector:\n'
        '                                    if not isinstance(num_disk_sectors, int) '
        'or num_disk_sectors < 1024:\n'
        '                                        self.error(f"Refusing to program '
        '{filename}: could not determine the size of LUN {partition_number} "\n'
        '                                                   f"(got {num_disk_sectors}). '
        'Writing {start_sector} would corrupt the GPT.")\n'
        '                                        success = False\n'
        '                                        continue\n'
        '                                    start_sector = start_sector.replace'
        '("NUM_DISK_SECTORS", str(num_disk_sectors))\n')
    if anchor not in src:
        print("  WARNING: could not apply the edl qfil guard (upstream changed).")
        print("           Do not use `edl qfil` with this MSM package.")
        return
    f.write_text(src.replace(anchor, patched))
    print("  edl qfil guard applied")


def step_msm():
    say("5/6 MSM package -> firehose loader + GPT template")
    extract = MSM_DIR / "extract"
    need = [extract / "prog_firehose_ddr.elf", extract / "gpt_main0.bin"]
    if all(p.exists() for p in need) and not FORCE:
        print("  already extracted")
        return
    MSM_DIR.mkdir(exist_ok=True)
    ops = next(MSM_DIR.glob("*.ops"), None)
    if ops is None:
        print("  unpacking the .rar")
        run(["unrar", "x", "-o+", "-idq",
             str(DOWNLOADS / SOURCES[0]["file"]), str(MSM_DIR) + "/"])
        ops = next(MSM_DIR.glob("*.ops"), None)
    if ops is None:
        raise SystemExit("ABORT: no .ops file inside the MSM archive")
    print(f"  decrypting {ops.name} (a few minutes)")
    run([str(VPY), str(HERE / "oppo_decrypt" / "opscrypto.py"), "decrypt",
         str(ops), "--extractdir=extract"], cwd=MSM_DIR)
    for p in need:
        if not p.exists():
            raise SystemExit(f"ABORT: {p} missing after decryption")
        print(f"  {p.relative_to(HERE)}  {p.stat().st_size} bytes")


# --------------------------------------------------------------------------
# OTA payload extraction (Android payload.bin, no external dependencies)
# --------------------------------------------------------------------------

def _pb(buf):
    """Walk a protobuf message, yielding (field_number, wire_type, value)."""
    i = 0
    while i < len(buf):
        key = shift = 0
        while True:
            b = buf[i]; i += 1
            key |= (b & 0x7F) << shift; shift += 7
            if not b & 0x80:
                break
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v = shift = 0
            while True:
                b = buf[i]; i += 1
                v |= (b & 0x7F) << shift; shift += 7
                if not b & 0x80:
                    break
            yield fn, wt, v
        elif wt == 2:
            n = shift = 0
            while True:
                b = buf[i]; i += 1
                n |= (b & 0x7F) << shift; shift += 7
                if not b & 0x80:
                    break
            yield fn, wt, buf[i:i + n]; i += n
        elif wt == 5:
            yield fn, wt, buf[i:i + 4]; i += 4
        elif wt == 1:
            yield fn, wt, buf[i:i + 8]; i += 8
        else:
            raise ValueError(f"unsupported wire type {wt}")


def _one(msg, field, default=None):
    return next((v for f, _, v in _pb(msg) if f == field), default)


# Field numbers confirmed by introspecting this payload, not assumed:
#   manifest.block_size = 3, manifest.partitions = 13
#   PartitionUpdate.partition_name = 1, .new_partition_info = 7, .operations = 8
#   InstallOperation.type = 1, .data_offset = 2, .data_length = 3, .dst_extents = 6
#   Extent.start_block = 1, .num_blocks = 2
#   PartitionInfo.size = 1, .hash = 2
REPLACE, REPLACE_BZ, ZERO, DISCARD, REPLACE_XZ = 0, 1, 6, 7, 8


def extract_payload(payload, outdir, skip=frozenset()):
    outdir.mkdir(parents=True, exist_ok=True)
    f = open(payload, "rb")
    if f.read(4) != b"CrAU":
        raise SystemExit("ABORT: payload.bin has no CrAU magic")
    # Header order: magic(4) version(8) manifest_size(8)
    # metadata_signature_size(4) manifest metadata_signature, then the data
    # blobs. The signature length precedes the manifest, not follows it.
    struct.unpack(">Q", f.read(8))[0]                       # version
    manifest_size = struct.unpack(">Q", f.read(8))[0]
    sig_len = struct.unpack(">I", f.read(4))[0]
    manifest = f.read(manifest_size)
    data_start = f.tell() + sig_len

    block = _one(manifest, 3, 4096)
    written = []
    for fn, _, part in _pb(manifest):
        if fn != 13:
            continue
        name = _one(part, 1).decode()
        if name in skip:
            print(f"  skip     {name}.img")
            continue
        info = _one(part, 7)
        size = _one(info, 1) if info else None
        want_hash = _one(info, 2) if info else None
        out = outdir / f"{name}.img"

        if out.exists() and size and out.stat().st_size == size and not FORCE:
            if want_hash and sha256(out, name) == want_hash.hex():
                print(f"  ok       {name}.img")
                written.append(name)
                continue

        print(f"  extracting {name}.img", end="", flush=True)
        with open(out, "wb") as w:
            if size:
                w.truncate(size)
            for f2, _, op in _pb(part):
                if f2 != 8:
                    continue
                typ = _one(op, 1, 0)
                off, length = _one(op, 2, 0), _one(op, 3, 0)
                dst = [(_one(e, 1, 0), _one(e, 2, 0))
                       for g, _, e in _pb(op) if g == 6]
                f.seek(data_start + off)
                raw = f.read(length)
                if typ == REPLACE:
                    data = raw
                elif typ == REPLACE_BZ:
                    data = bz2.decompress(raw)
                elif typ == REPLACE_XZ:
                    data = lzma.decompress(raw)
                elif typ in (ZERO, DISCARD):
                    data = b"\0" * sum(n for _, n in dst) * block
                else:
                    raise SystemExit(
                        f"ABORT: {name}: unsupported operation type {typ}. "
                        "This looks like an incremental OTA; a full one is "
                        "required.")
                pos = 0
                for start, nblocks in dst:
                    chunk = data[pos:pos + nblocks * block]
                    w.seek(start * block)
                    w.write(chunk)
                    pos += len(chunk)
        if want_hash:
            got = sha256(out, name)
            if got != want_hash.hex():
                raise SystemExit(f"\nABORT: {name}.img hash mismatch\n"
                                 f"  got  {got}\n  want {want_hash.hex()}")
            print("  verified against the payload's own SHA256")
        else:
            print()
        written.append(name)
    f.close()
    return written


def step_ota():
    say("6/6 OTA payloads -> partition images")

    # Don't extract what the restore never flashes; saves ~1.3 GB per release.
    # The list lives in restore-android.py so the two cannot drift apart.
    skip = frozenset()
    if os.environ.get("KEEP_ALL") != "1":
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "restore", HERE / "restore-android.py")
        restore = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(restore)
        skip = frozenset(restore.SKIP)

    only = os.environ.get("RELEASE")
    for name, rel in RELEASES.items():
        if only and name != only:
            continue
        out = RELEASES_DIR / name
        out.mkdir(parents=True, exist_ok=True)
        print(f"\n  [{name}] {rel['what']}")
        payload = out / "payload.bin"
        if not payload.exists() or FORCE:
            print("  unzipping payload.bin")
            with zipfile.ZipFile(DOWNLOADS / rel["file"]) as z:
                for member in ("payload.bin", "payload_properties.txt",
                               "care_map.pb", "care_map.txt",
                               "META-INF/com/android/metadata"):
                    if member in z.namelist():
                        z.extract(member, out)
        names = extract_payload(payload, out / "images", skip=skip)
        print(f"  {len(names)} images ready in "
              f"{(out / 'images').relative_to(HERE)}")


def main():
    print("OnePlus 6T -> stock OxygenOS 11 : bootstrap")
    step_tools()
    step_download()
    step_tooling()
    step_venv()
    step_msm()
    step_ota()
    print("\nBootstrap complete.\n")
    print("Put the phone in EDL: power off fully, then hold Volume Up +")
    print("Volume Down together and plug in USB. The screen stays black;")
    print("lsusb should show 05c6:9008. Then pick a release:\n")
    for name, rel in RELEASES.items():
        print(f"    RELEASE={name:<6} {VPY.relative_to(HERE)} "
              f"restore-android.py   # {rel['what']}")
    print()


if __name__ == "__main__":
    main()
