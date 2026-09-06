#!/system/bin/sh
# developer-mode-seed: turn on Developer options, USB debugging and Rooted
# debugging the first time this /data is booted. Installed by
# `build-lineage.sh --developer-mode`; absent from a stock build.
#
# Runs once per /data (marker file), from init as a oneshot in the
# permissive `su` domain, so it can write the settings provider and the
# adbroot store without its own sepolicy. Waits for the system server
# because `settings` is a content-provider call and post-fs-data is far too
# early for it.

MARKER=/data/adbroot/.developer-mode-seeded
[ -f "$MARKER" ] && exit 0

# `settings` needs system_server; boot_completed is the simplest reliable
# signal that it is answering. Bounded so a wedged boot cannot pin this
# service forever.
i=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    i=$((i + 1)); [ "$i" -ge 120 ] && exit 1
    sleep 1
done

settings put global development_settings_enabled 1
settings put global adb_enabled 1

# Rooted debugging. This is the entire toggle: adbroot_service reads
# /data/adbroot/enabled at start and adbd asks it whether root is allowed.
mkdir -p /data/adbroot
chmod 0700 /data/adbroot
echo -n 1 > /data/adbroot/enabled
setprop service.adb.root 1

# adbd was started before adb_enabled existed; restart so it comes up with
# debugging on and root allowed, without waiting for a reboot.
setprop ctl.restart adbd

touch "$MARKER"
