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


def main():
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
    with open(OUT, "wb") as wf:
        sh.read_memory(RAMOOPS_BASE, RAMOOPS_SIZE, True, wf)
    print(f"\nwrote {OUT}")


def report(path=OUT):
    """Pull readable kernel log lines out of the raw ramoops blob."""
    data = open(path, "rb").read()
    text = data.decode("utf-8", "replace")
    # kernel console lines look like "[  12.345678] message"
    lines = re.findall(r"\[\s*\d+\.\d+\][^\r\n\x00]{0,300}", text)
    print(f"{len(lines)} kernel log lines recovered\n")
    return lines


if __name__ == "__main__":
    if "--report" in sys.argv:
        for line in report():
            print(line)
    else:
        main()
