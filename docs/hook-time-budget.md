# Hook Time Budget

This document is for contributors who change this repository's own
[`.stride.md`](../.stride.md), the `precommit` alias in [`mix.exs`](../mix.exs)
or anything that makes the test suite slower. It explains how the blocking
`after_doing` and `after_goal` hooks fit inside the Stride plugin's time budget,
what each line is for, and how to measure them again. Introduced by W2723, after
W2696's `after_doing` used 282 s of a 290 s budget and the `after_goal` hooks of
G526 and G527 timed out inside `mix precommit`, so their pushes never ran.

## How the budget works

The Stride plugin runs every command of one `.stride.md` section under **one
shared clock**. When the clock runs out, the running command is killed, the
rest of the section never starts, and the hook exits `124`. For a timed-out
`after_goal` that means `git push origin main` never runs, and the goal's
commits stay local.

The budget is resolved per section, in this order: the
`STRIDE_HOOK_TIMEOUT_OVERRIDE` environment variable, then the server's hook
timeout, then the plugin default. In plugin 1.88.0 the default is 600 s for
every section, and any value is clamped to 890 s.

A personal Claude Code settings file can set `STRIDE_HOOK_TIMEOUT_OVERRIDE`. A
value of 290 dates from when the plugin's ceiling was 290 s. With plugin 1.88.0
it *lowers* the budget from 600 s to 290 s. Whether to keep it is the
developer's decision. The layout below aims to finish in **70% of 290 s
(203 s)**, so it fits either way.

## The suite runs as three partitions

ExUnit runs every `async: false` module one at a time, after all the async
modules. In this suite that serial tail is about 197 s of a 280 s run, so a
single `mix test` cannot fit a 203 s target however fast the async half gets.

[`test/partitioned_test.sh`](../test/partitioned_test.sh) runs the suite as
`mix test --partitions 3` in three VMs at once:

- Each VM gets a disjoint share of the test files, so each one runs about a
  third of the serial tail. Every test still runs exactly once, with its
  assertions unchanged.
- `config/test.exs` already names the database `kanban_test<N>` from
  `MIX_TEST_PARTITION`, so each VM has its own database. The `test` alias
  creates and migrates it, so the first run on a machine is slower.
- The script compiles once, with `--warnings-as-errors`, before the VMs start,
  so they never compile `_build/test` at the same time.
- Each VM gets `--max-cases` of twice the core count divided by the number of
  VMs, rounded up (6 on an 8-core machine). So the VMs together run about as
  many async tests at once as one `mix test` does. With ExUnit's default in
  every VM, three VMs ran three times as many. Timing-sensitive tests, such as
  ones with a fixed sleep or a PDF render, then failed in two of six runs.
- Each VM also runs with `+S` set to (`--max-cases` + 3) / 2 schedulers, 4 on
  an 8-core machine. `config/test.exs` sizes the Repo pool at twice the
  schedulers online, so with the default of 8 each VM opened 17 database
  connections and one run held 51. Two runs at once then passed Postgres's
  `max_connections` of 100, and every partition of both failed. With 4
  schedulers each VM's pool is 8.
- It exits `0` only when every partition passes. Each partition is reported
  as soon as it ends: a failed one's full output, a passing one's summary
  lines.
- If it is killed, as a hook deadline does, it stops the VMs still running and
  prints the last 200 lines of each one's log, so a failure in a partition
  that had not been reported yet is not lost.
- It passes its arguments to `mix test`. `TEST_PARTITIONS` changes the number
  of VMs, `TEST_MAX_CASES` the per-VM concurrency and `TEST_SCHEDULERS` the
  per-VM schedulers. It is for the whole suite: given fewer test files than
  partitions, a partition gets none and fails, so run a few files with
  `mix test`.

Three VMs was the fastest count measured on an 8-core machine. Four was slower,
because one partition drew most of the slow serial modules:

| VMs | Wall clock | Slowest partition's serial time |
|---|---|---|
| 1 (`mix test`) | 281-284 s | 198 s |
| 2 | 186 s | 142 s |
| 3 | 130 s | 90 s |
| 4 | 143 s | 102 s |

The 2-VM figure includes creating the partition databases for the first time.
These counts were measured with ExUnit's default concurrency in every VM. The
Measurements section below has the figures with the per-VM `--max-cases`.

## after_doing

| Line | Why |
|---|---|
| `bash test/partitioned_test.sh --warnings-as-errors` | The whole suite, with the same `--warnings-as-errors` flag as the `precommit` leg |
| `MIX_ENV=test mix format --check-formatted` | `MIX_ENV=test` makes it reuse the test build the suite just compiled |
| `MIX_ENV=test mix credo --strict` | As above |
| `MIX_ENV=test mix sobelow --config` | As above. This is the repository's only static security scan in a blocking hook. `.sobelow-conf` sets `exit: false`, so it fails the hook only when sobelow cannot run, not on a finding |
| `[ -z "$(git status --porcelain --untracked-files=all)" ] \|\| (git add -A && git commit ...)` | The task commit. It used to test `git diff --quiet HEAD --`, which ignores untracked files, so a task that only added new files made no commit. It now commits whenever anything, untracked files included, is left over |
| `m="$(git rev-parse --git-path stride-green-tree)"; ...` | Records the tree that was just tested green (see below) |

The hook sets no `MIX_ENV`, so before W2723 the format, credo and sobelow lines
ran in `dev`. `mix format` loads the HEEx formatter plugin, and loading a plugin
compiles the project in the current environment. So each `after_doing` compiled
`_build/dev` underneath a running `mix phx.server`, which also stops the dev
server's code reloader from seeing the change.

### The green-tree marker

The last line writes `HEAD^{tree}` to `.git/stride-green-tree`, the path
`git rev-parse --git-path stride-green-tree` names. It does this only when the
working tree is clean after the commit, checked with
`git status --porcelain --untracked-files=all` so that a
`status.showUntrackedFiles=no` setting cannot hide an untracked file.
Otherwise it deletes the marker, because then the tested content and the
committed tree differ. The marker sits inside `.git/`, so it is never tracked
and never makes the tree dirty.

The hook stops at the first failing line, so the marker is written only after
the suite and every static gate have passed and the commit has been made.

## after_goal

```bash
git checkout main
git fetch origin main
git rebase origin/main || { ...; exit 1; }
MIX_ENV=test mix do compile --warnings-as-errors + deps.unlock --unused + format + gettext.extract --check-up-to-date + dark_mode.scan + dark_mode.contrast --enforce + credo --strict
m="$(git rev-parse --git-path stride-green-tree)"; t="$(git rev-parse 'HEAD^{tree}')"; if [ -z "$(git status --porcelain)" ] && [ -f "$m" ] && [ "$(cat "$m")" = "$t" ]; then echo "...not re-run"; else bash test/partitioned_test.sh --warnings-as-errors || { echo "...not pushing"; exit 1; }; fi
git push origin main
```

`after_goal` used to run `mix precommit`, which ran the whole suite a second
time, right after the last task's `after_doing` had run it on the same code.
Now:

- **The `mix do` line runs every `precommit` leg except the suite**, in the
  alias's order, in `MIX_ENV=test` like the alias. The alias itself is
  unchanged, so `mix precommit` and the list in the
  [Stride development guidelines skill](multi-agent-instructions/stride-development-guidelines/SKILL.md)
  still mean what they did.
- **A dirty working tree stops the push.** After the `mix do` line, any change
  left in the working tree, untracked files included, makes the line print
  what is left and exit `1`, so the push does not run. A suite run on that tree
  would test content that `git push` does not send, and a leg that rewrites a
  file, such as `format` or `deps.unlock --unused`, would leave its rewrite
  unpushed and block the next `before_doing`.
- **The suite runs again unless the tree being pushed was already tested
  green.** On a clean tree, the suite is skipped only when the marker exists and
  names exactly `HEAD^{tree}`. That is the common case: the last task's
  `before_review` fast-forwards `main` to the task's commit, and the rebase is a
  no-op when `origin/main` has not moved.
- **Anything else runs the suite before the push.** That includes a rebase that
  brought in new commits from `origin/main`, a manual commit after the last
  `after_doing`, or a missing marker. A failed suite stops the section, so the
  push does not run.

A tree hash, rather than "did the rebase move `HEAD`", answers the question
that matters: was this exact content tested green? Each hook line runs in a
fresh shell, so no earlier `HEAD` survives from one line to the next anyway.

Two limits remain. Gitignored files never count as dirty, so a test that reads
an ignored input can see different content in `after_doing` and `after_goal`
on the same tree. And commits that a rebase brings in from `origin/main` get
`credo` and the suite in `after_goal`, but no `sobelow --config`, as before
W2723, because `precommit` has never run sobelow.

**The fallback costs a full partitioned suite on top of the static legs.** When
`origin/main` moved during the goal, `after_goal` runs the `mix do` line and then
the suite. Timed once on an idle machine, before the scheduler cap below, that
took 62 s plus 130 s, 192 s before the push, inside 203 s. With the cap the
suite took 119 s to 132 s, which puts the fallback at about 181 s to 194 s. If
it ever does not fit, it fails closed: the push does not run.

## Gates before and after W2723

| Gate | Before | After |
|---|---|---|
| Test suite | `after_doing` (`mix test`); again in `after_goal` (`precommit`) | `after_doing`, partitioned, with `--warnings-as-errors`; again in `after_goal` unless the pushed tree was tested green |
| `format --check-formatted` | `after_doing`, `dev` | `after_doing`, `test` |
| `credo --strict` | `after_doing`, `dev`; `after_goal` (`precommit`) | `after_doing`, `test`; `after_goal` (`mix do`) |
| `sobelow --config` | `after_doing` | `after_doing`, `test` |
| `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `gettext.extract --check-up-to-date`, `dark_mode.scan`, `dark_mode.contrast --enforce` | `after_goal` (`precommit`) | `after_goal` (`mix do`) |

Every gate still runs in a blocking hook before the commit or the push it
guards.

## Measurements

Median of three runs on an idle 8-core machine (no other `mix test` running,
checked with `pgrep -f "mix test"`). Each command was timed on its own, in
seconds.

| Command | Before | After |
|---|---|---|
| Test suite | 283.6 (`mix test`) | 129.4 (`test/partitioned_test.sh`) |
| `format --check-formatted` | 1.3 | 1.3 |
| `credo --strict` | 16.5 | 16.4 |
| `sobelow --config` | 3.4 | 3.4 |
| **`after_doing` total** | **304.8** | **150.5** |
| `git fetch origin main` | — | 0.3 |
| `after_goal` legs before the push, suite skipped | 304.7 (`mix precommit`) | 61.5 (`mix do`) |
| `mix precommit` (the alias, unchanged) | 304.7 | 301.3 |

The partitioned suite took 119.2 s, 129.4 s and 132.4 s across the three
runs, with 4 schedulers per VM. The slowest run put the whole `after_doing`
section at 153.5 s, under 203 s. Before the scheduler cap the same script
took 129.9 s to 169.3 s, because three VMs of 8 schedulers each competed for
8 cores. The serial suite took 280.7 s to 284.3 s.

The format, credo and sobelow "before" figures were taken in `MIX_ENV=test`,
because compiling `dev` beside a running dev server is not allowed. The hook
ran them in `dev`, and when the dev build was stale that added a compile, so
the real "before" figures were at least this high.

### The slowest tests

`MIX_ENV=test mix test --slowest 25` before W2723 named 25 tests taking 54.6 s,
19.4% of the suite's total test time. The ten slowest:

| Test | Time |
|---|---|
| `test/kanban/docs_relative_links_test.exs:21` | 6.3 s |
| `test/kanban/chromic_pdf_cleanup_test.exs:75` | 5.5 s |
| `test/kanban/chrome_watchdog_test.exs:125` | 4.9 s |
| `test/kanban/application_test.exs:94` | 3.5 s |
| `test/kanban/audit_log/signing_test.exs:286` | 3.4 s |
| `test/kanban/chrome_watchdog_test.exs:133` | 3.3 s |
| `test/kanban/chrome_watchdog_test.exs:145` | 3.1 s |
| `test/kanban/chrome_watchdog_test.exs:118` | 2.3 s |
| `test/kanban/accounts/two_factor_test.exs:218` | 2.1 s |
| `test/kanban/attachments/storage/s3_test.exs:598` | 2.1 s |

W2723 changes no existing test, so the same tests are the slowest after it. No
single test is worth more than a few seconds: the time is in the serial tail as a
whole, which is why the fix is partitioning rather than speeding tests up.

### Cold builds and a shared machine

Exploratory sessions measured the layout away from an idle, warm machine:

- **A cold `_build/test`** (after `mix clean`, or a `deps.get` that brings in
  new versions) adds a compile of about 85-90 s before the first test. Three
  cold runs of the whole `after_doing` section took 246 s, about 278 s and
  more than 290 s. Under a 290 s budget that can time out; under the 600 s
  default every cold run fits with about 300 s to spare.
- **Two `after_doing` runs at once** passed Postgres's `max_connections`
  before the scheduler cap, peaking at 103 connections, and failed every
  partition of both. With the cap, two runs 30 s apart peaked at 67
  connections in all, dev server included, and none was refused.
- **Two runs at once still share the partition databases**, because both
  name them `kanban_test1` to `kanban_test3`. A test that commits data outside
  the sandbox can then see the other run's rows: in that overlapped pair, the
  second run failed two such tests and exited `1`. Two plain `mix test` runs
  share `kanban_test` the same way, so this predates W2723, and the gate fails
  rather than passing.
- **Another session recompiling `_build/test`** while the suite runs fails
  thousands of tests with "module ... is not available". A single `mix test`
  is exposed the same way, so this predates W2723.
- **Timing-sensitive tests can still fail under load**, for example a ChromicPDF
  render timing out right after a cold build. The gate fails, which is the safe
  outcome, and the failing partition's full output is printed.

## Keeping it in shape

- `.stride_dev.md` is the Stride-mode copy of `.stride.md` that
  `./stride_dev.sh` copies back over it. Make every hook change in both
  files, and keep their `after_doing` and `after_goal` sections identical. The
  contract test below checks this. `.plugin_dev.md`, the plugin-mode variant
  with empty hooks, is deliberately different.
- [`test/kanban/stride_hooks_contract_test.exs`](../test/kanban/stride_hooks_contract_test.exs)
  fails when the `mix do` legs drift from the `precommit` alias, or when a gate
  moves after the commit or the push it guards. It also runs the commit and
  marker lines in a throwaway git repository with a stub suite, so the skip
  condition and the dirty-tree refusal are tested, not just their wording. When you change the alias,
  change the `mix do` line in `after_goal` and the list in the development
  guidelines skill in the same commit.
- To measure again, check that no other `mix test` is running, then time each
  command on its own, three times, and compare the median with 70% of the
  budget in force.
- When the suite grows back towards the target, the next levers are the
  slowest `async: false` modules (`mix test --slowest-modules 25` names them)
  and a fourth partition once the serial modules spread more evenly.
