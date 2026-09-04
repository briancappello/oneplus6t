#!/usr/bin/env python
"""
Run commands on a booted Droidian device over SSH.

    ./droidian/ssh.py 'systemctl --failed'
    ./droidian/ssh.py -r 'cat /sys/class/backlight/panel0-backlight/bl_power'
    ./droidian/ssh.py -f local.deb:/tmp/local.deb          # upload
    ./droidian/ssh.py -g /var/log/foo:/tmp/foo             # download

-r runs through sudo. The command is shipped base64-encoded and unpacked on the
far side, because quoting a shell pipeline through ssh -> sudo -> sh mangles it.

Env: DEV_IP (10.15.19.82), DEV_USER (droidian), DEV_PASS (1234).
"""
import base64
import os
import sys
import time

import paramiko

IP = os.environ.get("DEV_IP", "10.15.19.82")
USER = os.environ.get("DEV_USER", "droidian")
PASS = os.environ.get("DEV_PASS", "1234")


def connect(timeout=15, tries=6):
    """The USB-NCM link drops handshakes fairly often; retry rather than fail."""
    for n in range(tries):
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            c.connect(IP, username=USER, password=PASS, timeout=timeout,
                      banner_timeout=timeout, auth_timeout=timeout,
                      look_for_keys=False, allow_agent=False)
            return c
        except Exception as e:
            c.close()
            if n == tries - 1:
                raise
            print(f"ssh: {type(e).__name__}: {e} (retry {n + 1}/{tries - 1})",
                  file=sys.stderr)
            time.sleep(2)


def run(client, cmd, root=False, timeout=120):
    """Returns (rc, stdout, stderr). Root commands go over base64 to survive quoting."""
    if root:
        # The blob must NOT be piped into sudo -- that would steal sudo's stdin,
        # which is where the password has to arrive. Decode it in a command
        # substitution instead, so sudo keeps the ssh channel as its stdin.
        blob = base64.b64encode(cmd.encode()).decode()
        cmd = f"""sudo -S -p '' /bin/bash -c "$(echo '{blob}' | base64 -d)" """
    stdin, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    if root:
        stdin.write(PASS + "\n")
        stdin.flush()
    stdin.channel.shutdown_write()
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    return stdout.channel.recv_exit_status(), out, err


def main():
    args = sys.argv[1:]
    root = False
    if args and args[0] == "-r":
        root, args = True, args[1:]
    if not args:
        sys.exit(__doc__)

    c = connect()
    try:
        if args[0] in ("-f", "-g"):
            src, dst = args[1].split(":", 1)
            sftp = c.open_sftp()
            sftp.put(src, dst) if args[0] == "-f" else sftp.get(src, dst)
            sftp.close()
            print(f"ok {src} -> {dst}")
            return 0
        rc, out, err = run(c, " ".join(args), root=root)
        sys.stdout.write(out)
        sys.stderr.write(err)
        return rc
    finally:
        c.close()


if __name__ == "__main__":
    sys.exit(main())
