defmodule Kanban.AgentWorkflowHelpers do
  @moduledoc """
  Shared setup and builders for the `Kanban.Tasks.AgentWorkflow` test files
  under `test/kanban/tasks/agent_workflow/` (W2356).

      import Kanban.AgentWorkflowHelpers

      describe "claim_next_task/5" do
        setup :setup_board

        test "claims", ctx do
          task = create_open_task(ctx.ready, ctx.user)
          claimed = claim_for(task, ctx.user, ctx.board)
          # ...
        end
      end

  The helpers call the public `Kanban.Tasks.AgentWorkflow` functions, because
  the facade is the API under test.
  """

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.AgentWorkflow
  alias Kanban.Tasks.Task

  @doc """
  `setup` callback: creates an owner, a second user and an AI-optimized board,
  and returns them with the board's Ready, Doing, Review and Done columns.
  """
  def setup_board(_ctx) do
    user = user_fixture()
    other = user_fixture()
    board = ai_optimized_board_fixture(user)
    columns = Kanban.Columns.list_columns(board)

    %{
      user: user,
      other: other,
      board: board,
      ready: Enum.find(columns, &(&1.name == "Ready")),
      doing: Enum.find(columns, &(&1.name == "Doing")),
      review: Enum.find(columns, &(&1.name == "Review")),
      done: Enum.find(columns, &(&1.name == "Done"))
    }
  end

  @doc """
  Creates an open, non-human task in `column`, created by `user`. `attrs`
  (string keys) override the defaults.
  """
  def create_open_task(column, user, attrs \\ %{}) do
    base = %{
      "title" => "Test Task #{System.unique_integer([:positive])}",
      "status" => "open",
      "human_task" => false,
      "created_by_id" => user.id
    }

    {:ok, task} = Tasks.create_task(column, Map.merge(base, attrs))
    task
  end

  @doc """
  Claims `task` by identifier for `user` on `board` through the facade and
  returns the claimed task.
  """
  def claim_for(%Task{identifier: identifier}, user, board) do
    {:ok, claimed, _hook} =
      AgentWorkflow.claim_next_task([], user, board.id, identifier, "Test Agent")

    claimed
  end

  @doc """
  The minimal completion params `AgentWorkflow.complete_task/4` accepts.
  """
  def valid_complete_params do
    %{
      "completion_summary" => "Did the work",
      "actual_complexity" => "small",
      "actual_files_changed" => "lib/foo.ex, lib/bar.ex",
      "time_spent_minutes" => 30
    }
  end

  @doc """
  Records a review outcome on `task` directly, as a human reviewer would,
  without going through the review flow.
  """
  def set_review_status(task, status, reviewer) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    task
    |> Ecto.Changeset.change(%{
      review_status: status,
      reviewed_at: now,
      reviewed_by_id: reviewer.id
    })
    |> Repo.update!()
  end
end
