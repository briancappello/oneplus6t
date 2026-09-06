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
HEARTBEAT="${HEARTBEAT:-60}"
IMAGE_TAG="${IMAGE_TAG:-lineage20-build:fajita}"
GONE_POLLS="${GONE_POLLS:-3}"   # consecutive no-container polls before "stopped"
gone=0

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

# Before ninja starts emitting percentages there is nothing for progress() to
# find, and a heartbeat of empty strings is no better than silence. Fall back to
# the script's own phase markers so sync and setup are visible too.
phase_line() { tr '\r' '\n' < "$LOG" 2>/dev/null | grep -aE '^>>> ' | tail -1; }

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
started=$(date +%s)
next_beat=0
while :; do
    # Say something on a healthy build. Reporting only on failure, completion or
    # timeout meant a working build and a wedged one looked identical: total
    # silence for the whole window. A flat target count across beats is now a
    # visible stall rather than an indistinguishable one.
    now=$(date +%s)
    if [ "$now" -ge "$next_beat" ]; then
        printf '    [%3dm] %s %s\n' \
            "$(( (now - started) / 60 ))" \
            "$(progress || true)" \
            "$(phase_line || true)"
        next_beat=$(( now + HEARTBEAT ))
    fi
    # Report a failure the moment it appears, not when the container finally
    # exits. ninja keeps scheduling the targets already queued after a target
    # fails, so a build can run for a long time -- and print thousands more
    # progress lines -- after the failure that doomed it. Waiting for the
    # container to stop meant sitting through all of that in silence.
    # "Tried to lock out/.lock" is included deliberately: it means a SECOND run
    # collided with one already in progress, which is not a build error and is
    # invisible in the log otherwise. "#### failed to build some targets" is
    # deliberately NOT matched -- lunch's internal dumpvars pass prints it on
    # perfectly healthy runs, which is what produced a false failure before.
    if build_region | grep -qaE '^FAILED:|^ninja: build stopped|Tried to lock out/\.lock'; then
        echo "=== FAILED at $(progress) ==="
        build_region | grep -aE '^FAILED:|missing dependencies|EAGAIN|OutOfMemoryError|errno=11|^ninja: build stopped|Tried to lock' | head -10
        exit 1
    fi
    # Filtered to OUR image: a plain `podman ps -q` counts any container on the
    # box, so an unrelated one makes a dead build look alive.
    #
    # Debounced: each phase is its own `podman run`, so between sync's container
    # exiting and build's starting there are a few seconds with NO container.
    # One sample landing in that gap declared a healthy build failed. Require
    # the absence to persist across consecutive polls before believing it.
    if [ -z "$("$RT" ps --filter "ancestor=$IMAGE_TAG" -q 2>/dev/null)" ]; then
        gone=$((gone + 1))
        if [ "$gone" -ge "$GONE_POLLS" ]; then
            echo "=== work stopped, $(progress) ==="
            report_outcome
            exit $?
        fi
    else
        gone=0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "=== still running after ${MAX_MINUTES}m: $(progress) ==="
        exit 2
    fi
    sleep "$INTERVAL"
done
