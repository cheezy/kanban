#!/usr/bin/env bash
# Runs the whole ExUnit suite as parallel partitions, one VM each.
#
# Why: ExUnit runs every `async: false` module one at a time, after the
# async modules. In this repo that serial tail is about 197 s of a 240-280 s
# suite (W2723), so one `mix test` cannot fit the blocking hooks' budget.
# `mix test --partitions N` gives each VM a disjoint share of the test
# files, so the serial tail is split N ways. Every test still runs, with
# its assertions unchanged; config/test.exs already gives each partition
# its own database (kanban_test<N>).
#
# Each VM gets --max-cases 2 * cores / N (rounded up), so the three VMs
# together run about as many async tests at once as one `mix test` does
# (2 * cores). With ExUnit's default per VM, three VMs ran three times as
# many, and timing-sensitive tests (fixed sleeps, PDF renders) failed under
# the load in two of six runs.
#
# Each VM also gets +S schedulers, (max-cases + 3) / 2 of them (4 for 6
# cases), because config/test.exs sizes the Repo pool at twice the
# schedulers online. At the default of 8 schedulers each VM opened 17
# connections, one run held 51, and two runs at once passed Postgres's
# max_connections of 100, failing every partition of both.
#
# Usage: test/partitioned_test.sh [mix test options...]
#   TEST_PARTITIONS  number of VMs (default 3)
#   TEST_MAX_CASES   async tests at once in each VM (default above)
#   TEST_SCHEDULERS  schedulers in each VM, and so half its pool (default above)
#
# Runs the whole suite. To run a few files, use mix test: with fewer files
# than partitions, a partition gets none and exits 1.
#
# Exits 0 only when every partition exits 0. Each partition is reported as
# soon as it ends: a failing one's full output, a passing one's summary
# lines. If the script is killed (a hook deadline), it stops the VMs still
# running and prints the end of each one's log, so the failure is not lost.
set -u

partitions="${TEST_PARTITIONS:-3}"
case "$partitions" in
  '' | *[!0-9]* | 0)
    echo "TEST_PARTITIONS must be a positive integer, got '$partitions'" >&2
    exit 2
    ;;
esac

cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)"
max_cases="${TEST_MAX_CASES:-$(((2 * cores + partitions - 1) / partitions))}"
case "$max_cases" in
  '' | *[!0-9]* | 0)
    echo "TEST_MAX_CASES must be a positive integer, got '$max_cases'" >&2
    exit 2
    ;;
esac

schedulers="${TEST_SCHEDULERS:-$(((max_cases + 3) / 2))}"
case "$schedulers" in
  '' | *[!0-9]* | 0)
    echo "TEST_SCHEDULERS must be a positive integer, got '$schedulers'" >&2
    exit 2
    ;;
esac

export MIX_ENV=test

# Compile once before the VMs start, so they never compile _build/test at
# the same time.
mix compile --warnings-as-errors || exit 1

logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

pids=()
reported=()
for i in $(seq 1 "$partitions"); do
  MIX_TEST_PARTITION="$i" ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-} +S $schedulers:$schedulers" \
    mix test --partitions "$partitions" --max-cases "$max_cases" "$@" > "$logs/$i.log" 2>&1 &
  pids+=("$!")
  reported+=(0)
done

on_kill() {
  for i in $(seq 1 "$partitions"); do
    if [ "${reported[$((i - 1))]}" = 0 ]; then
      kill "${pids[$((i - 1))]}" 2>/dev/null
      echo "== partition $i/$partitions killed before it ended; the last 200 lines of its output follow"
      tail -n 200 "$logs/$i.log"
    fi
  done
  exit 143
}
trap on_kill TERM INT

status=0
left="$partitions"
while [ "$left" -gt 0 ]; do
  for i in $(seq 1 "$partitions"); do
    pid="${pids[$((i - 1))]}"
    if [ "${reported[$((i - 1))]}" = 0 ] && ! kill -0 "$pid" 2>/dev/null; then
      if wait "$pid"; then
        echo "== partition $i/$partitions passed"
        grep -E '^(Finished in|Result:|[0-9]+ (doctests?, )?tests?,)' "$logs/$i.log"
      else
        status=1
        echo "== partition $i/$partitions FAILED; its full output follows"
        cat "$logs/$i.log"
      fi
      reported[$((i - 1))]=1
      left=$((left - 1))
    fi
  done
  [ "$left" -gt 0 ] && sleep 1
done

exit "$status"
