#!/usr/bin/env python3
"""Pull the ramoops (pstore) region out of a device sitting in Qualcomm ramdump mode.

    ./droidian/dump-ramoops.py

When the kernel panics, CONFIG_QCOM_DLOAD_MODE=y halts the SoC in ramdump mode
(USB 05c6:900e) instead of rebooting, so DRAM still holds the console log that
CONFIG_PSTORE_RAM wrote. `edl memorydump` would dump four 2 GB DDR blobs; the
ramoops region is 4 MB at a known address, so read only that.

Address comes from the device tree, not guesswork:

    arch/arm64/boot/dts/qcom/sdm845_enchilada_soc.dtsi
        ramoops: ramoops@0xAC300000 {
            compatible = "ramoops";
            reg = <0 0xAC300000 0 0x00400000>;
            record-size  = <0x40000>;
            console-size = <0x40000>;
        };
"""

import os
import re
import sys

sys.path.insert(0, "/home/brian/oneplus6t/edl")

from edlclient.Library.Connection.usblib import usb_class          # noqa: E402
from edlclient.Library.sahara import sahara                        # noqa: E402
from edlclient.Library.sahara_defs import cmd_t, sahara_mode_t     # noqa: E402
from edlclient.Config.usb_ids import default_ids                   # noqa: E402

RAMOOPS_BASE = 0xAC300000
RAMOOPS_SIZE = 0x00400000
OUT = "/home/brian/oneplus6t/droidian/out/ramoops.bin"


def dump(out=OUT, reset=False):
    cdc = usb_class(portconfig=default_ids, loglevel=40, serial_number=None)
    sh = sahara(cdc, loglevel=40)
    sh.programmer = ""

    print("waiting for the device in ramdump mode (05c6:900e)...")
    if not cdc.connect():
        sys.exit("no device")

    # The device sends its own HELLO first; sahara.connect() consumes it and
    # reports the mode. Only then do we answer with a memory-debug HELLO.
    conn = sh.connect()
    print("sahara connect:", conn)
    version = 2 if conn.get("data") is None else getattr(conn["data"], "version", 2)

    if not sh.cmd_hello(sahara_mode_t.SAHARA_MODE_MEMORY_DEBUG, version=version):
        sys.exit("device did not accept memory-debug hello; is it in ramdump mode?")
    res = sh.get_rsp()
    print("rsp:", {k: v for k, v in res.items() if k != "data"})
    if res.get("cmd") not in (cmd_t.SAHARA_MEMORY_DEBUG, cmd_t.SAHARA_64BIT_MEMORY_DEBUG):
        sys.exit(f"unexpected sahara response: {res['cmd']}")

    print(f"reading {RAMOOPS_SIZE // 1024} KB at {RAMOOPS_BASE:#x}")
    with open(out, "wb") as wf:
        sh.read_memory(RAMOOPS_BASE, RAMOOPS_SIZE, True, wf)
    print(f"\nwrote {out}")
    if reset:
        # Sahara reset from memory-debug mode; the device boots normally (or
        # lands in EDL 9008, which device.sh knows how to leave).
        print("sahara reset:", sh.cmd_reset())


# Zone layout, from the DT node and ramoops_probe(): the dump records come
# first and take whatever is left after the fixed zones, then console, ftrace,
# pmsg. Each zone is a persistent_ram ring: sig, start, size, then data.
ZONES = {
    "console": (0x180000, 0x40000),
    "ftrace":  (0x1C0000, 0x40000),
    "pmsg":    (0x200000, 0x200000),
}
PERSISTENT_RAM_SIG = 0x43474244   # "DBGC"


def zone(data, name):
    """The ring's contents in write order, or None if the zone is not valid."""
    import struct
    off, size = ZONES[name]
    sig, start, used = struct.unpack_from("<III", data, off)
    if sig != PERSISTENT_RAM_SIG:
        return None
    buf = data[off + 12: off + size]
    cap = size - 12
    used = min(used, cap); start = min(start, cap)
    if used < cap:
        return buf[:used]
    return buf[start:] + buf[:start]


def report(path=OUT, outdir=None):
    """Write console.txt and pmsg.txt next to the blob; print what was found."""
    data = open(path, "rb").read()
    outdir = outdir or os.path.dirname(path)
    for name in ("console", "pmsg"):
        z = zone(data, name)
        if z is None:
            print(f"{name}: no valid zone (signature missing)")
            continue
        text = z.decode("utf-8", "replace").replace("\x00", "")
        dst = os.path.join(outdir, f"{name}.txt")
        open(dst, "w").write(text)
        print(f"{name}: {len(z)} bytes, {text.count(chr(10))} lines -> {dst}")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--reset", action="store_true", help="Sahara-reset the device after the dump")
    ap.add_argument("--report", action="store_true", help="only parse an existing blob")
    a = ap.parse_args()
    if not a.report:
        dump(a.out, a.reset)
    report(a.out)
