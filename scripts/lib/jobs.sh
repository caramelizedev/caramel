# Background jobs for the build scripts; source it after `set -eu`.
#
#   job NAME COMMAND...   starts COMMAND with its stdout and stderr kept aside
#   finish_jobs           waits for every job in start order, replays each
#                         job's output, and fails naming the first that failed
#
# NAME is a plain word. A script that exits early still waits for its jobs, so
# no build outlives it; their output is then discarded.
JOBS=
JOBS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/caramel-jobs.XXXXXX")
trap 'for JOB in $JOBS; do wait "${JOB%%:*}" 2>/dev/null || true; done; rm -rf "$JOBS_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

job() {
    JOB_NAME=$1
    shift
    "$@" >"$JOBS_DIR/$JOB_NAME.out" 2>"$JOBS_DIR/$JOB_NAME.err" &
    JOBS="$JOBS $!:$JOB_NAME"
}

finish_jobs() {
    JOB_FAILED=
    for JOB in $JOBS; do
        wait "${JOB%%:*}" || JOB_FAILED=${JOB_FAILED:-${JOB#*:}}
        cat "$JOBS_DIR/${JOB#*:}.out"
        cat "$JOBS_DIR/${JOB#*:}.err" >&2
    done
    JOBS=
    if [ -n "$JOB_FAILED" ]; then
        echo "$JOB_FAILED failed" >&2
        return 1
    fi
}
