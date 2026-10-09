defmodule KanbanWeb.JsHooksTest do
  @moduledoc """
  Runs the dependency-free `node --test` suites for LiveView JS hooks as part of
  `mix test`, so pure hook logic (such as the mention autocomplete's trigger
  detection) is checked alongside the server code it talks to.

  Skipped, with the reason shown, when `node` is not installed.
  """
  use ExUnit.Case, async: true

  @node System.find_executable("node")
  @suites [
    "assets/js/hooks/mention_autocomplete.test.mjs",
    "assets/js/hooks/comment_anchor.test.mjs",
    "assets/js/hooks/keyboard_shortcuts.test.mjs",
    "assets/js/hooks/snap_indicator.test.mjs",
    "assets/js/focus_after_move.test.mjs"
  ]

  if is_nil(@node), do: @moduletag(skip: "node is not installed")

  for suite <- @suites do
    test "node --test #{suite} passes" do
      {output, status} =
        System.cmd(@node, ["--test", unquote(suite)], cd: File.cwd!(), stderr_to_stdout: true)

      assert status == 0, output
    end
  end
end
