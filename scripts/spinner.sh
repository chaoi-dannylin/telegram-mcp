#!/bin/sh
#
# spinner.sh — reusable terminal loading animation.
#
# Designed to be sourced by zsh/bash/sh scripts:
#
#   . "$SCRIPT_DIR/spinner.sh"
#
#   spinner_start "Fetching usage…"
#   ...slow work...
#   spinner_stop
#
#   # or wrap one command, preserving its exit status:
#   spinner_run "Committing…" git commit -m "msg"
#
#   # or wrap one command and keep its output for later:
#   spinner_capture /tmp/out.log "Pushing…" git push
#
# Vendored from a shared personal spinner library so every local tool animates
# identically. Local changes: safe under `set -e`, and the animation exits by
# itself once the sourcing script is gone (Ctrl-C would otherwise orphan it —
# a non-interactive shell's background jobs ignore SIGINT).
#
# The animation writes to stderr, so stdout stays clean for piping, and
# auto-disables when stderr is not a TTY (pipes, CI, captured output) or when
# NO_COLOR is set. A non-UTF-8 locale falls back to ASCII frames.
#
# Return values: spinner_run / spinner_capture return the wrapped command's
# exit status; spinner_start / spinner_stop always return 0.

: "${SPINNER_INTERVAL:=0.08}"
# Built with printf rather than written as literal control characters, so the
# file stays plain ASCII and survives copy/paste and editor round-trips.
_SPINNER_ESC=$(printf '\033')
: "${SPINNER_COLOR:=${_SPINNER_ESC}[38;5;87m}"
: "${SPINNER_RESET:=${_SPINNER_ESC}[0m}"
: "${SPINNER_FRAMES:=⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏}"
: "${SPINNER_FRAMES_ASCII:=| / - \\}"

_SPINNER_PID=""

# 0 when the animation should be drawn: stderr is a TTY and color is allowed.
spinner_enabled() {
    [ -t 2 ] || return 1
    [ -z "${NO_COLOR:-}" ] || return 1
    return 0
}

# Braille needs a UTF-8 capable locale; anything else gets the ASCII frames.
_spinner_frames() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *UTF-8*|*utf8*|*UTF8*|*utf-8*) printf '%s' "$SPINNER_FRAMES" ;;
        *) printf '%s' "$SPINNER_FRAMES_ASCII" ;;
    esac
}

# spinner_start [message] — begin animating until spinner_stop.
spinner_start() {
    _spinner_msg=${1:-Working…}
    spinner_enabled || return 0
    spinner_stop
    (
        # shellcheck disable=SC2046  # deliberate word splitting into $1..$n
        set -- $(_spinner_frames)
        _n=$#
        _i=0
        while kill -0 $$ 2>/dev/null; do
            _i=$(( _i % _n + 1 ))
            eval "_f=\${$_i}"
            printf '\r%s%s%s %s\033[K' \
                "$SPINNER_COLOR" "$_f" "$SPINNER_RESET" "$_spinner_msg" >&2
            sleep "$SPINNER_INTERVAL"
        done
    ) &
    _SPINNER_PID=$!
}

# spinner_stop — stop the animation and clear its line.
spinner_stop() {
    [ -n "$_SPINNER_PID" ] || return 0
    kill "$_SPINNER_PID" 2>/dev/null || :
    wait "$_SPINNER_PID" 2>/dev/null || :
    _SPINNER_PID=""
    printf '\r\033[K' >&2
    return 0
}

# spinner_run <message> <command> [args...] — animate while the command runs.
spinner_run() {
    _spinner_label=$1
    shift
    spinner_start "$_spinner_label"
    _spinner_status=0
    "$@" || _spinner_status=$?
    spinner_stop
    return $_spinner_status
}

# spinner_capture <logfile> <message> <command> [args...]
# Animate while the command runs, sending its stdout and stderr to <logfile>
# instead of the screen — so a verbose tool stays quiet until the caller
# decides whether to show the log.
spinner_capture() {
    _spinner_log=$1
    _spinner_label=$2
    shift 2
    spinner_start "$_spinner_label"
    _spinner_status=0
    "$@" >"$_spinner_log" 2>&1 || _spinner_status=$?
    spinner_stop
    return $_spinner_status
}
