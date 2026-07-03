defmodule Kanban.Hooks.EnvironmentTest do
  @moduledoc """
  Direct unit tests for hook environment-variable construction (W1448). A single
  happy-path case exists in hooks_test.exs; this file pins the full key set, the
  opts defaults, and the nil/missing-optional-field fallbacks. Uses in-memory
  structs (Repo.preload is a no-op on an already-loaded :column) so the nil
  branches — which the create-path fixtures can't produce — are reachable.
  """
  use ExUnit.Case, async: true

  alias Kanban.Boards.Board
  alias Kanban.Columns.Column
  alias Kanban.Hooks.Environment
  alias Kanban.Tasks.Task

  @all_keys ~w(
    TASK_ID TASK_IDENTIFIER TASK_TITLE TASK_DESCRIPTION TASK_STATUS
    TASK_COMPLEXITY TASK_PRIORITY TASK_NEEDS_REVIEW
    BOARD_ID BOARD_NAME COLUMN_ID COLUMN_NAME AGENT_NAME HOOK_NAME
  )

  describe "build/3 — fully populated" do
    test "renders every task/board/column/context var and exactly the 14 keys" do
      column = %Column{id: 10, name: "Doing"}
      board = %Board{id: 20, name: "My Board"}

      task = %Task{
        id: 30,
        column_id: 10,
        identifier: "W30",
        title: "Do it",
        description: "the description",
        status: :blocked,
        complexity: :large,
        priority: :high,
        needs_review: true,
        column: column
      }

      env = Environment.build(task, board, agent_name: "Claude Opus", hook_name: "after_doing")

      assert env["TASK_ID"] == "30"
      assert env["TASK_IDENTIFIER"] == "W30"
      assert env["TASK_TITLE"] == "Do it"
      assert env["TASK_DESCRIPTION"] == "the description"
      assert env["TASK_STATUS"] == "blocked"
      assert env["TASK_COMPLEXITY"] == "large"
      assert env["TASK_PRIORITY"] == "high"
      assert env["TASK_NEEDS_REVIEW"] == "true"
      assert env["BOARD_ID"] == "20"
      assert env["BOARD_NAME"] == "My Board"
      assert env["COLUMN_ID"] == "10"
      assert env["COLUMN_NAME"] == "Doing"
      assert env["AGENT_NAME"] == "Claude Opus"
      assert env["HOOK_NAME"] == "after_doing"

      assert env |> Map.keys() |> Enum.sort() == Enum.sort(@all_keys)
    end
  end

  describe "build/3 — opts defaults" do
    test "defaults AGENT_NAME to Unknown and HOOK_NAME to unknown when opts omitted" do
      column = %Column{id: 1, name: "Ready"}
      board = %Board{id: 2, name: "B"}
      task = %Task{id: 3, column_id: 1, column: column}

      env = Environment.build(task, board)

      assert env["AGENT_NAME"] == "Unknown"
      assert env["HOOK_NAME"] == "unknown"
    end
  end

  describe "build/3 — missing optional fields" do
    test "falls back to empty strings and status/complexity/priority/review defaults" do
      column = %Column{id: 10, name: nil}
      board = %Board{id: 20, name: nil}

      task = %Task{
        id: 30,
        column_id: 10,
        identifier: nil,
        title: nil,
        description: nil,
        status: nil,
        complexity: nil,
        priority: nil,
        needs_review: nil,
        column: column
      }

      env = Environment.build(task, board)

      assert env["TASK_IDENTIFIER"] == ""
      assert env["TASK_TITLE"] == ""
      assert env["TASK_DESCRIPTION"] == ""
      assert env["TASK_STATUS"] == "open"
      assert env["TASK_COMPLEXITY"] == "medium"
      assert env["TASK_PRIORITY"] == "0"
      assert env["TASK_NEEDS_REVIEW"] == "false"
      assert env["BOARD_NAME"] == ""
      assert env["COLUMN_NAME"] == ""
    end
  end
end
