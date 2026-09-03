#!/usr/bin/env bash
# Flash the A11 secure/bootloader chain via EDL to fix the A9<->A11 crashdump.
# These are the partitions fastboot refused ("Critical Partitions"). Both slots.
set -uo pipefail
ROM=/home/brian/oneplus6t
EDL=/home/brian/oneplus6t/edl/.venv/bin/edl

# partition -> image (both slots for each)
declare -A IMG=(
  [xbl]=xbl.img
  [xbl_config]=xbl_config.img
  [abl]=abl.img
  [tz]=tz.img
  [hyp]=hyp.img
  [devcfg]=devcfg.img
  [keymaster]=keymaster.img
  [cmnlib]=cmnlib.img
  [cmnlib64]=cmnlib64.img
)

parts=""
files=""
for base in xbl xbl_config abl tz hyp devcfg keymaster cmnlib cmnlib64; do
  img="$ROM/${IMG[$base]}"
  [ -f "$img" ] || { echo "MISSING: $img" >&2; exit 1; }
  for slot in a b; do
    parts="${parts:+$parts,}${base}_${slot}"
    files="${files:+$files,}${img}"
  done
done

echo "Partitions: $parts"
echo ">>> Flashing secure chain via EDL (both slots)..."
"$EDL" w "$parts" "$files" --memory=ufs
