#!/usr/bin/env bash
# Runs the Phoenix checks an iOS task needs. The iOS hook set (.ios_dev.md)
# runs it before each task commit.
#
# A task that changed only mobile/, .github/workflows/ios.yml and the
# stride-ios skill runs the ExUnit tests that read those files. Nothing in the
# Phoenix app reads the skill, which every iOS task adds its lessons to. A
# task that also changed the app's strings (the msgid list, the mobile gettext
# files and the strings test) runs
# the same tests, plus the format check and credo on the Elixir files among
# them: nothing in the web app reads the mobile domain. Any other change, or a
# change set that cannot be read, runs the whole partitioned suite, the format
# check, credo and sobelow, as the Stride hook set does.
#
# The change set is everything since the task's branch left main, committed or
# not, untracked files included. .stride.md is left out because ios_dev.sh
# copies over it. The after_goal hook still runs the whole suite before a push.
set -u

cd "$(dirname "$0")/.." || exit 1

# Every test file that reads mobile/ or ios.yml. The hook contract test fails
# when a test reads them and is not listed.
guards=(
  test/kanban/mobile
  test/kanban/docs_relative_links_test.exs
  test/kanban/ios_hook_scripts_test.exs
  test/kanban/mobile_api_docs_test.exs
  test/kanban/repository_layout_test.exs
  test/kanban/stride_hooks_contract_test.exs
  test/kanban_web/controllers/api/mobile_fixtures_test.exs
  test/kanban_web/controllers/api/open_api_contract_test.exs
  test/mix/ios
  test/mix/ios_test.exs
  test/mix/tasks/ios
  test/mix/tasks/mobile
)

# The Elixir files among the string changes, for the format check and credo.
string_sources=()

ios_only() {
  local base paths path
  base="$(git merge-base main HEAD)" || return 1
  paths="$(git diff --name-only --no-renames "$base" -- . ':(exclude).stride.md' \
    && git ls-files --others --exclude-standard)" || return 1

  while IFS= read -r path; do
    case "$path" in
      '' | mobile/* | .github/workflows/ios.yml | .claude/skills/stride-ios/*) ;;
      priv/gettext/mobile.pot | priv/gettext/*/LC_MESSAGES/mobile.po) ;;
      lib/kanban/mobile/strings/msgids.ex | test/kanban/mobile/strings_test.exs)
        if [ -f "$path" ]; then string_sources+=("$path"); fi
        ;;
      *)
        echo "== $path is outside mobile/, so the whole Phoenix suite runs"
        return 1
        ;;
    esac
  done <<< "$paths"
  return 0
}

export MIX_ENV=test

if ios_only; then
  echo "== only the iOS app and its strings changed, so the tests that read mobile/ run"
  mix test --warnings-as-errors "${guards[@]}" || exit 1
  [ "${#string_sources[@]}" -eq 0 ] && exit 0
  mix format --check-formatted "${string_sources[@]}" || exit 1
  exec mix credo --strict "${string_sources[@]}"
fi

bash test/partitioned_test.sh --warnings-as-errors || exit 1
mix format --check-formatted || exit 1
mix credo --strict || exit 1
mix sobelow --config
