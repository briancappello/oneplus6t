# Droidian adaptation packaging for the OnePlus 6T (fajita)

**Status:** design approved, not yet implemented
**Date:** 2026-09-04

## Problem

Droidian boots on the fajita with a working display, GPU-accelerated
compositor and a usable Phosh session — but only because two fixes were
applied by hand over SSH:

1. `/dev/hwbinder`, `/dev/vndbinder`, `/dev/kgsl-3d0` and `/dev/ion` were
   `0600 root:root` on the host, so `phoc` (uid 32011) could not reach the
   HIDL composer or the Adreno GPU.
2. `polkit-agent-helper.socket` requires `pidfd`, which does not exist on
   this 4.9 vendor kernel, so every polkit authentication failed regardless
   of the password.

Both live only in the running filesystem. `droidian/build-rootfs.sh` unpacks
a **stock** `rootfs.img` and packs it untouched, so the next
`build-rootfs.sh` + `flash.sh` cycle silently discards them. There is
currently no seam through which anything of ours enters the image.

## Goals

- Every fix survives a reinstall, with no manual post-flash step.
- The generic fixes are reusable by other Halium porters, not buried in a
  device-specific package.
- No new host dependency, no `sudo`, no Docker — the properties this repo
  already advertises.

## Non-goals

- Fixing the device clock (stuck at Jan 1 1970; needs a route to the
  internet or an RTC write). Tracked separately.
- Mainline/postmarketOS. This document is Droidian only.

## Constraints, and how they were established

These were measured on this host and this device, not assumed.

| Constraint | Evidence |
|---|---|
| The build host is Arch: no `dpkg`, no `dpkg-deb`, no `fuse2fs` | `which` returns nothing for all three |
| arm64 maintainer scripts cannot run here | `binfmt_misc` has no registered handlers; only dynamic `qemu-aarch64`; `podman run --arch arm64` fails |
| Rootless podman cannot loop-mount ext4 | loop mount needs `CAP_SYS_ADMIN` in the *initial* user namespace |
| FUSE is usable unprivileged | `/dev/fuse` is `0666` on the host |
| The Android container has a private `/dev` | `/var/lib/lxc/android/config` sets `lxc.autodev = 0` and `lxc.mount.entry = tmpfs dev tmpfs nosuid 0 0` |
| ueventd's modes never reach the host | `/proc/<ueventd-pid>/root/dev/hwbinder` is `0666` while the host node was `0600` |
| Nothing in Droidian parses `ueventd.rc` | no script under `/usr/bin`, `/usr/sbin`, `/usr/lib/systemd` or `/var/lib/lxc/android` references it |

The decisive consequence is that **packages must ship no maintainer
scripts**. With no `postinst`, `dpkg --root=` executes no target binaries,
so no emulation is needed. This was validated, not assumed — see
[Validation](#validation-already-performed).

## Architecture

One source package produces three binary packages — the same pattern the
kernel packaging already uses (one source, six binaries).

| Package | Scope | Responsibility |
|---|---|---|
| `halium-hostdev-perms` | any Halium device | Derive host udev rules from the device's own `ueventd.rc` at boot |
| `halium-oldkernel-compat` | any kernel < 5.1 | Make polkit work without `pidfd` |
| `adaptation-oneplus-fajita` | fajita | Device glue; depends on the other two |

The split exists because the polkit failure is a **kernel-version** bug, not
a device bug. Every Halium port on a pre-5.1 vendor kernel hits it, and it
presents as "my password is rejected", which is maximally misleading.
Burying that in a fajita package hides it from everyone who needs it.

`halium-hostdev-perms` contains **no device knowledge at all** — it reads
the policy off the device it is running on. A porter installs it on hardware
we have never seen and it works.

## The seam

`droidian/build-rootfs.sh` currently does:

```
unzip rootfs.img  →  resize2fs 8G  →  mke2fs -d stage/ userdata.img
```

The packages are installed into `stage/rootfs.img` between `resize2fs` and
`mke2fs`. That single insertion point is what makes fixes survive a
reinstall, because `flash.sh` writes that image to `userdata`.

```
podman run --rm -i --device /dev/fuse --cap-add SYS_ADMIN \
    --security-opt apparmor=unconfined -v "$PWD":/work \
    quay.io/droidian/build-essential:current-amd64 bash -s <<'EOF'
apt-get install -y fuse2fs fuse3
fuse2fs -o rw,fakeroot /work/rootfs.img /mnt/rootfs
mountpoint -q /mnt/rootfs || exit 1          # fuse2fs forks; rc is meaningless
dpkg --root=/mnt/rootfs -i /work/*.deb
fusermount3 -u /mnt/rootfs
EOF
```

`--cap-add SYS_ADMIN` is a capability inside the container's user
namespace. It is **not** host root.

A new `droidian/build-adaptation.sh` builds the three `.deb`s, mirroring
`build-kernel.sh` (which already uses this container via the
`whereis -b docker` → podman shim). `build-rootfs.sh` gains an
`ADAPTATION=0` escape hatch to pack a stock image for comparison.

## halium-hostdev-perms

### Why the host `/dev` is wrong

The Android container gets a private tmpfs `/dev`, so `ueventd` applies the
vendor's modes only inside the container. The host `/dev` is devtmpfs driven
by udev, and the only Android rules there come from `lxc-android`'s
`65-android.rules`, which covers `binder`, `ashmem`, `log_*`, `event*`,
`uhid`, `mtp_usb` and `rfkill`. That was sufficient before Treble. On
API 28 every HIDL HAL — including the graphics composer — lives on
**`hwbinder`**, which that file never mentions.

### Deriving the rule set

The set of nodes to fix is **computed, never hand-listed**:

```
{ nodes declared in ueventd.rc }  ∩  { nodes the session user cannot open }
                                  \  { nodes matched by a deny rule }
```

On this device the first set is ~230 nodes and the intersection is **71**.

The second term is the safety invariant and is not optional. Applying
Android's declarations wholesale would actively break the device: the host
has `/dev/input/event*` as `root:android_input` where `ueventd.rc` says
`root:input`, and `/dev/dri/card0` as `root:video` where `ueventd.rc` says
`root:graphics`. Touch and display work *because of* the host values.
Droidian runs a Debian-style group convention and adds the session user to
those groups. Two conventions coexist; failures occur only where **neither**
covers a node. Restricting to currently-unreachable nodes is self-limiting
and cannot regress a working convention.

Security posture: this grants no more than the device's own vendor policy
already grants its system services. We restore the shipped policy on the
host side; we do not invent access.

### Policy drop-ins

A drop-in directory, not one config file — both the generic and the device
package need to contribute policy, and a shared conffile would make them
conflict in dpkg.

```
/usr/lib/halium-hostdev-perms/policy.d/10-defaults.conf   generic package
/usr/lib/halium-hostdev-perms/policy.d/50-fajita.conf     device package
/etc/halium-hostdev-perms/policy.d/*.conf                 local; wins
```

Precedence follows the systemd convention people already know: lexical order
by filename, later wins, and a file in `/etc` **masks** the same filename in
`/usr/lib`.

```
# 10-defaults.conf
deny /dev/diag
deny /dev/ramdump_*
deny /dev/subsys_*
```

Roughly 20 of the 71 nodes are debug/forensic. Nothing in a Droidian session
needs them and `/dev/diag` is the modem diagnostic channel, so they are
denied by default. Opting back in is one fragment:

```
# /etc/halium-hostdev-perms/policy.d/90-local.conf
allow /dev/diag
```

This can be written into the rootfs at image-build time next to where the
`.deb`s are installed, **or** edited on a running device followed by
`systemctl restart halium-hostdev-perms`. It is not baked into `boot.img`
and changing it never requires a reflash.

`allow` only removes a node from the deny-list. It never overrides the
reachability test, so no fragment can cause the unit to "fix"
`/dev/input/event*` and break touch.

### Unit and ordering

```
[Unit]
After=android-mount.service
Before=lxc@android.service
```

Verified chain: `systemd-udev-settle` → `android-mount.service` (mounts
`/android/vendor`) → `lxc@android.service` →
`android-service@hwcomposer.service` → `phosh.service`. That guarantees
`ueventd.rc` is readable and the rules are applied before anything opens the
nodes.

The unit writes `/etc/udev/rules.d/70-halium-hostdev-perms.rules`, then
`udevadm control --reload-rules`, `udevadm trigger` for the affected nodes,
and `udevadm settle`.

### Self-check

- Logs every node changed, `old → new`, so
  `journalctl -u halium-hostdev-perms` is a complete audit of what was widened.
- **Fails loudly** if parsing `ueventd.rc` yields zero declarations. Silently
  doing nothing is precisely how this bug stayed hidden for a whole session.
- Runs `udevadm verify` on the generated file before reloading. A rule with a
  trailing inline `# comment` is silently discarded by udev, and
  `udevadm control --reload-rules` reports nothing — this was hit during
  investigation and must not recur.

## halium-oldkernel-compat

Droidian's polkitd runs its auth helper as a socket-activated unit, which
requires `pidfd`. `pidfd_open` landed in Linux 5.1; this device runs the
vendor 4.9 kernel. Every attempt produced:

```
polkit-agent-helper-1: Pidfd not supported on this platform,
                       disable polkit-agent-helper.socket and use setuid helper
polkit-agent-helper@N-...service: Main process exited, code=exited, status=1/FAILURE
```

The helper states its own fix. There was no fallback because
`/usr/lib/polkit-1/polkit-agent-helper-1` ships `-rwxr-xr-x`, not setuid.
The failure is indistinguishable from a wrong password, which is why it cost
time.

Contents:

- `/etc/systemd/system/polkit-agent-helper.socket` → `/dev/null`, shipped as
  a plain symlink in the `.deb`. This is a systemd mask expressed as a file,
  so it needs no `postinst`.
- A oneshot that applies
  `dpkg-statoverride --update --add root root 4755 /usr/lib/polkit-1/polkit-agent-helper-1`.

`dpkg-statoverride` rather than a bare `chmod u+s` so that a `polkitd`
upgrade cannot silently drop the setuid bit and resurrect the bug.

The unit is guarded on `uname -r` and is a **no-op on kernels ≥ 5.1**, so
the package is safe to install on a mainline port. The same 4.9-vs-pidfd
family also produces
`xdg-desktop-portal: Failed to get pidfd for host process N: Function not implemented`,
which is cosmetic and out of scope here.

## adaptation-oneplus-fajita

Depends on both generic packages. This is not a metapackage; it has real
device work outstanding.

**Camera — diagnosed, not yet fixed.** It is *not* a permissions problem
(zero camera nodes appear in the inaccessible set; `/dev/video*`,
`/dev/media*` and `/dev/v4l-subdev*` are `0660 root:video` and the session
user is in `video`) and *not* a Phosh problem (Phosh is not in the path).
All three vendor HALs run — `android.hardware.camera.provider@2.4-service`,
`vendor.oneplus.camera.CameraHIDL@1.0-service`, `camera_service` — and
`gstreamer1.0-droid` is installed. The actual failure is GStreamer caps
negotiation:

```
CameraBin error: "GStreamer error: negotiation problem."
qrc:/main.qml:228: Error: Cannot assign [undefined] to QSize
```

`droidcamsrc` reports no resolution, so `QSize` is undefined. This needs
per-device camera configuration and is the first job for this package.

Also outstanding, carried over from the upstream `oneplus6` adaptation and
still unverified on fajita:

- `op6-getcutout` with **6T** values. The 6T's waterdrop notch differs from
  the 6's teardrop. `getcutout`'s `50-notch.conf` already points
  `G_RESOURCE_OVERLAYS` at `/var/lib/droidian/phosh-notch`, **which does not
  exist**.
- `brightness.service` — `actual_brightness` reads 0 even with
  `bl_power=0` and `brightness=800`.
- `double-tap`, `droidian-perf`, `op6-otg`, and the `50-fajita.conf` policy
  fragment.

Naming is explicitly `fajita` throughout, per the existing convention in
this repo — upstream's ambiguous "oneplus6 / Oneplus 6/6T" is not carried
over.

## Validation already performed

The load-bearing assumption — that arm64 `.deb`s can be installed into
`rootfs.img` from this host with no qemu and no root — was proven before
this design was accepted. The spike ran under `.work/`, which is
gitignored and transient; the recipe it validated is recorded verbatim
above in [The seam](#the-seam), and `droidian/build-adaptation.sh` becomes
its permanent form.

A no-maintainer-script arm64 package shaped like the real ones (udev rule,
systemd unit, enablement symlink, `/dev/null` mask) was installed into the
**real** 8 GiB Droidian rootfs:

```
dpkg --root=/mnt/rootfs -i spike.deb   →  rc=0
dpkg --root=/mnt/rootfs -l             →  ii  ...-spike  0.0.1  arm64
dpkg --root=/mnt/rootfs --audit        →  (empty: no triggers pending)
```

Both symlinks and the regular file landed correctly, verified afterwards
from the host with `debugfs -R`. The dpkg-triggers risk that was flagged
during design did not materialise, so `--no-triggers` is not required.

Three findings worth keeping:

1. `fuse2fs` execs `fusermount3`, which is in the separate **`fuse3`**
   package. Without it the mount silently no-ops — and `fuse2fs` still
   returns **0**, because it forks. Never trust its exit code; assert with
   `mountpoint -q`. Two spike runs "succeeded" while mounting nothing.
2. `--device /dev/fuse` alone gives `fusermount3: mount failed: Operation
   not permitted`. `--cap-add SYS_ADMIN` is also required.
3. btrfs `cp --reflink=auto` clones the 8 GiB rootfs in 0.13 s for zero
   bytes. Every experiment gets a disposable image.

The udev rule generation was separately proven on hardware: all five nodes
were set to `0600 root:root`, udev was triggered, and every one returned to
its `ueventd.rc` value with `phosh` still active. Flipping permissions on a
live system is safe because POSIX checks permissions at `open()`, not per
operation, so running clients keep their existing descriptors.

## Verification plan

Baseline first, so pre-existing failures are never confused with new ones.

1. **Offline** — build the three `.deb`s; assert none contains a maintainer
   script (`dpkg-deb --ctrl-tarfile | tar t` shows only `control`/`md5sums`);
   `udevadm verify` the generated rules against a captured `ueventd.rc`
   fixture.
2. **Image** — install into a reflink copy of `rootfs.img`; assert the three
   packages register `ii`, `dpkg --audit` is clean, and `e2fsck -fn` passes
   after `fuse2fs` (which bypasses the journal).
3. **Hardware** — flash, then with the device booted assert:
   - `systemctl is-active phosh` is `active` and `NRestarts` is low
   - `phoc` logs `GL renderer: Adreno (TM) 630` (hardware path, not the
     pixman fallback)
   - `/dev/hwbinder` is `0666`, `/dev/kgsl-3d0` is `0666 system:system`
   - `/dev/diag` is **still** `0600` — proving the deny default holds
   - `/dev/input/event0` is **still** `root:android_input` — proving the
     safety invariant held
   - polkit authentication succeeds with no manual intervention
4. **Regression** — reboot once and re-assert. The whole point is surviving
   a reinstall.

## Open questions

- Whether `halium-hostdev-perms` and `halium-oldkernel-compat` are worth
  proposing upstream to Droidian. Both are device-independent. Deferred
  until they have run on hardware other than this one.
- The device clock (Jan 1 1970) breaks TLS and `apt` on-device, and produces
  `unix_chkpwd: account droidian has password changed in future`. Needs its
  own decision: NAT the USB link, or set the clock at boot.
