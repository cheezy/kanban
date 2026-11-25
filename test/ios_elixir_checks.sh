#!/usr/bin/env bash
# Runs the Phoenix checks an iOS task needs. The iOS hook set (.ios_dev.md)
# runs it before each task commit.
#
# A task that changed only mobile/ and .github/workflows/ios.yml runs the
# ExUnit tests that read those files. Any other change, or a change set that
# cannot be read, runs the whole partitioned suite, the format check, credo
# and sobelow, as the Stride hook set does.
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

ios_only() {
  local base paths path
  base="$(git merge-base main HEAD)" || return 1
  paths="$(git diff --name-only --no-renames "$base" -- . ':(exclude).stride.md' \
    && git ls-files --others --exclude-standard)" || return 1

  while IFS= read -r path; do
    case "$path" in
      '' | mobile/* | .github/workflows/ios.yml) ;;
      *)
        echo "== $path is outside mobile/, so the whole Phoenix suite runs"
        return 1
        ;;
    esac
  done <<< "$paths"
}

export MIX_ENV=test

if ios_only; then
  echo "== only the iOS app changed, so the tests that read mobile/ run"
  exec mix test --warnings-as-errors "${guards[@]}"
fi

bash test/partitioned_test.sh --warnings-as-errors || exit 1
mix format --check-formatted || exit 1
mix credo --strict || exit 1
mix sobelow --config
