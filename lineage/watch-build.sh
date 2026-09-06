#!/usr/bin/env bash
#
# Follow a detached build-lineage.sh run and return the moment it stops.
#
#   ./lineage/watch-build.sh [logfile]
#
# Exit status: 0 build finished successfully, 1 it failed, 2 still running when
# MAX_MINUTES elapsed (not a failure, just this watcher giving up the terminal).
#
# WHY this exists as a script rather than an ad hoc loop:
#
#   Every hand-rolled version of this got one of two things wrong, repeatedly.
#   Either it slept for a fixed period and only then looked -- so a failure
#   three seconds in was not noticed for four minutes of wall clock -- or it
#   grepped the whole log for loose patterns and reported a failure that had
#   already been survived. `lunch` runs an internal dumpvars build that prints
#   "#### failed to build some targets ####" on a perfectly healthy run, so
#   scanning the entire log for that string produces a false failure every time.
#
#   The rules that actually work, encoded here once:
#     * Poll often. Liveness, not elapsed time, decides when to look.
#     * Liveness = is a container running. The build always runs in one, and
#       pgrep kept matching the watcher's own command line.
#     * Only judge the log AFTER the phase marker that starts the real build,
#       so `lunch`'s internal failure cannot be mistaken for the build's.

set -uo pipefail

LOG="${1:-$HOME/lineage20-build.log}"
INTERVAL="${INTERVAL:-15}"
MAX_MINUTES="${MAX_MINUTES:-30}"

RT="$(command -v podman >/dev/null && echo podman || echo docker)"

# The build phase prints this before invoking m. Everything before it belongs to
# image/doctor/sync and to lunch's dumpvars pass, none of which should be judged
# by ninja's error vocabulary.
MARKER='>>> brunch'

# Text of the log from the build phase onward, with \r progress bars unwound
# into lines so grep and tail behave.
build_region() {
    tr '\r' '\n' < "$LOG" 2>/dev/null | awk -v m="$MARKER" 'index($0,m){f=1} f'
}

progress() { build_region | grep -aoE '\[ *[0-9]+% [0-9]+/[0-9]+\]' | tail -1; }

report_outcome() {
    if build_region | grep -qa 'build completed successfully'; then
        echo "RESULT: SUCCESS"
        build_region | grep -a 'build completed successfully' | tail -1
        return 0
    fi
    echo "RESULT: FAILED"
    # The first FAILED: block is the cause; everything after it is fallout from
    # ninja draining the jobs already in flight. Show the cause first.
    build_region | grep -aE '^FAILED:|missing dependencies|^error:|ninja: build stopped' | head -12
    return 1
}

deadline=$(( $(date +%s) + MAX_MINUTES * 60 ))
while :; do
    if [ -z "$("$RT" ps -q 2>/dev/null)" ]; then
        echo "=== work stopped, $(progress) ==="
        report_outcome
        exit $?
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "=== still running after ${MAX_MINUTES}m: $(progress) ==="
        exit 2
    fi
    sleep "$INTERVAL"
done
