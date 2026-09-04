#!/usr/bin/env bash
#
# Build the three adaptation .debs.
#
#   ./droidian/adaptation/build-adaptation.sh
#
# All three are Architecture: all -- shell scripts, systemd units and config,
# no compiled code -- so unlike the kernel and the camera app these need no
# arm64 emulation. dpkg-deb is not available on an Arch host, so the build runs
# in the Droidian container, which is amd64 and needs no qemu here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(dirname "$HERE")/out-adaptation"
IMAGE="quay.io/droidian/build-essential:current-amd64"
PKGS="halium-hostdev-perms halium-oldkernel-compat adaptation-oneplus-fajita"

runtime() {
    command -v docker >/dev/null && { echo docker; return; }
    command -v podman >/dev/null && { echo podman; return; }
    echo "Need docker or podman." >&2; exit 1
}

echo ">>> offline tests"
"$HERE/tests/run-tests.sh"

echo ">>> asserting no maintainer scripts"
for p in $PKGS; do
    extra=$(ls "$HERE/$p/DEBIAN" | grep -v '^control$' || true)
    [ -z "$extra" ] || { echo "$p has maintainer scripts: $extra" >&2; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT"
$(runtime) run --rm -v "$HERE":/src -v "$OUT":/out "$IMAGE" /bin/sh -c '
set -e
for p in '"$PKGS"'; do
    cp -a "/src/$p" "/tmp/$p"
    chown -R root:root "/tmp/$p"
    find "/tmp/$p" -name apply -o -name generate-rules | xargs -r chmod 0755
    dpkg-deb --build "/tmp/$p" /out/
done
'

echo
echo ">>> built"
for f in "$OUT"/*.deb; do
    printf '    %-52s %s bytes\n' "$(basename "$f")" "$(stat -c%s "$f")"
done
