#!/system/bin/sh
# developer-mode-seed: turn on Developer options, USB debugging and Rooted
# debugging the first time this /data is booted. Installed by
# `build-lineage.sh --developer-mode`; absent from a stock build.
#
# Runs once per /data (marker file), from init as a oneshot in the
# permissive `su` domain, so it can write the settings provider and the
# adbroot store without its own sepolicy.
#
# Does NOT wait for sys.boot_completed. The setup wizard holds that
# property back until it is dismissed, so the first version of this script
# timed out after 120 s on every fresh /data without doing anything -- and
# because it was launched with exec_start, init sat blocked on it for those
# 120 s too. `settings` needs only the settings provider, which is up well
# before the wizard; probing it directly is the correct wait.

MARKER=/data/adbroot/.developer-mode-seeded
[ -f "$MARKER" ] && exit 0

# The adbroot store does not depend on any framework state. Do it first, so
# even if the settings provider never answers, rooted debugging is on.
mkdir -p /data/adbroot
chmod 0700 /data/adbroot
echo -n 1 > /data/adbroot/enabled
setprop service.adb.root 1

# Wait for the settings provider by asking it, not by proxy. Bounded.
i=0
until [ "$(settings get global device_provisioned 2>/dev/null)" != "" ]; do
    i=$((i + 1)); [ "$i" -ge 90 ] && { echo "developer-mode-seed: settings provider not up after 90s" >&2; exit 1; }
    sleep 1
done

settings put global development_settings_enabled 1
settings put global adb_enabled 1

# adbd started before adb_enabled and the adbroot flag existed; restart it so
# debugging and root are live now, without a reboot.
setprop ctl.restart adbd

touch "$MARKER"
