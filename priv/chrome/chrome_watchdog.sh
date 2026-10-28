#!/bin/sh
# Runs ChromicPDF's headless Chrome and stops it when the Erlang VM that
# launched it is gone, so Chrome can never outlive the app (Kanban.ChromeWatchdog).
#
#   chrome_watchdog.sh --kanban-chrome=PATH [--kanban-watch-pid=PID] [chrome args...]
#
# --kanban-chrome is the real Chrome executable. --kanban-watch-pid is the VM's
# OS pid; without it the script simply execs Chrome. Both options are removed
# before Chrome sees its arguments.
#
# ChromicPDF runs this through `sh -c` with the DevTools pipe on fds 3 and 4.
# Chrome inherits them unchanged. Every second the watcher checks the VM pid;
# once it is gone, Chrome gets SIGTERM, then SIGKILL after 2 seconds. A
# SIGTERM, SIGHUP or SIGINT sent to this script stops Chrome the same way. The
# script exits with Chrome's exit status.

chrome=
watch_pid=

for arg do
  shift
  case $arg in
    --kanban-chrome=*) chrome=${arg#--kanban-chrome=} ;;
    --kanban-watch-pid=*) watch_pid=${arg#--kanban-watch-pid=} ;;
    *) set -- "$@" "$arg" ;;
  esac
done

if [ -z "$chrome" ]; then
  echo "chrome_watchdog.sh: --kanban-chrome=PATH is required" >&2
  exit 64
fi

case $watch_pid in
  '') exec "$chrome" "$@" ;;
  *[!0-9]*)
    echo "chrome_watchdog.sh: --kanban-watch-pid must be a number" >&2
    exit 64
    ;;
esac

# SIGTERM, then SIGKILL if Chrome is still running 2 seconds later.
stop_chrome() {
  kill -TERM "$1" 2>/dev/null || return 0
  tries=0
  while [ "$tries" -lt 20 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
    tries=$((tries + 1))
  done
  kill -KILL "$1" 2>/dev/null
  return 0
}

# The trap is set before Chrome starts, so a signal that arrives while it is
# starting still stops it. `stopping` records that a signal arrived.
chrome_pid=
stopping=
trap 'stopping=1; [ -z "$chrome_pid" ] || stop_chrome "$chrome_pid"' TERM HUP INT

"$chrome" "$@" &
chrome_pid=$!
[ -z "$stopping" ] || stop_chrome "$chrome_pid"

# Chrome holds its own copies of the pipe. Drop this script's, so the VM sees
# the pipe close as soon as Chrome exits.
exec 0</dev/null 1>/dev/null 3<&- 4>&-

# The watcher writes nothing, so it gets no stderr: if it ever outlived this
# script it must not hold the caller's output pipe open.
(
  trap - TERM HUP INT
  while kill -0 "$watch_pid" 2>/dev/null; do
    sleep 1
  done
  stop_chrome "$chrome_pid"
) 2>/dev/null &
watcher_pid=$!

# A trapped signal interrupts wait with status 128+signal before Chrome has
# exited, so wait again after any signal. Do not test whether Chrome is still
# running instead: the shell can reap Chrome between commands once it exits,
# and only wait returns the status it reaped. A wait that answers 127 means an
# earlier wait already returned Chrome's status, so keep that one.
status=
while :; do
  stopping=
  wait "$chrome_pid"
  rc=$?
  [ "$rc" -eq 127 ] && [ -n "$status" ] && break
  status=$rc
  [ -n "$stopping" ] || break
done

# SIGKILL, not SIGTERM: the watcher is forked with this script's TERM trap and
# only resets it once it runs. A SIGTERM that lands before then is caught and
# then dropped by the reset, which leaves the watcher polling the VM forever.
kill -KILL "$watcher_pid" 2>/dev/null
exit "$status"
