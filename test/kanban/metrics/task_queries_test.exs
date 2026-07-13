defmodule Kanban.Metrics.TaskQueriesTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Metrics.TaskQueries
  alias Kanban.Tasks

  describe "get_cycle_time_tasks/2 - AI-optimized boards" do
    setup :ai_board_with_column

    test "returns completed tasks using claimed_at as the start marker", %{column: column} do
      task = task_fixture(column)
      claimed_at = ~U[2026-06-01 09:00:00Z]
      completed_at = ~U[2026-06-01 12:00:00Z]
      {:ok, _} = complete_task(task, %{claimed_at: claimed_at, completed_at: completed_at})

      board_id = board_id(column)
      assert [row] = TaskQueries.get_cycle_time_tasks(board_id, time_range: :all_time)
      assert row.identifier == task.identifier
      assert row.claimed_at == claimed_at
      assert row.completed_at == completed_at
      # 3 hours between claim and completion.
      assert_in_delta to_float(row.cycle_time_seconds), 10_800.0, 0.1
    end

    test "excludes tasks completed without a claimed_at", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      board_id = board_id(column)
      assert TaskQueries.get_cycle_time_tasks(board_id, time_range: :all_time) == []
    end

    test "excludes goal-type tasks", %{column: column} do
      goal = task_fixture(column, %{type: :goal})
      {:ok, _} = complete_task(goal)

      board_id = board_id(column)
      assert TaskQueries.get_cycle_time_tasks(board_id, time_range: :all_time) == []
    end

    test "returns an empty list when no tasks are completed", %{column: column} do
      _open = task_fixture(column)

      board_id = board_id(column)
      assert TaskQueries.get_cycle_time_tasks(board_id, time_range: :all_time) == []
    end

    test "filters by agent_name when provided", %{column: column} do
      mine = task_fixture(column)
      theirs = task_fixture(column)
      {:ok, _} = complete_task(mine, %{completed_by_agent: "Claude Opus 4.8"})
      {:ok, _} = complete_task(theirs, %{completed_by_agent: "Some Other Agent"})

      board_id = board_id(column)

      assert [row] =
               TaskQueries.get_cycle_time_tasks(board_id,
                 time_range: :all_time,
                 agent_name: "Claude Opus 4.8"
               )

      assert row.identifier == mine.identifier
    end
  end

  describe "get_cycle_time_tasks/2 - regular boards" do
    setup :regular_board_with_column

    test "derives the start from the earliest move event", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_at: ~U[2026-06-02 15:00:00Z]})
      create_move_history(task, "Backlog", "In Progress", ~U[2026-06-02 09:00:00Z])

      board_id = board_id(column)
      assert [row] = TaskQueries.get_cycle_time_tasks(board_id, time_range: :all_time)
      assert row.identifier == task.identifier
      # 6 hours between the first move and completion.
      assert_in_delta to_float(row.cycle_time_seconds), 21_600.0, 0.1
    end

    test "uses the earliest move when several moves exist", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_at: ~U[2026-06-02 15:00:00Z]})
      create_move_history(task, "Backlog", "In Progress", ~U[2026-06-02 09:00:00Z])
      create_move_history(task, "In Progress", "Review", ~U[2026-06-02 13:00:00Z])

      board_id = board_id(column)
      assert [row] = TaskQueries.get_cycle_time_tasks(board_id, time_range: :all_time)
      # Still measured from the 09:00 move, not the later 13:00 one.
      assert_in_delta to_float(row.cycle_time_seconds), 21_600.0, 0.1
    end

    test "excludes tasks that were never moved", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      board_id = board_id(column)
      assert TaskQueries.get_cycle_time_tasks(board_id, time_range: :all_time) == []
    end
  end

  describe "get_cycle_time_tasks/2 - time range" do
    setup :ai_board_with_column

    test "bounds results by completed_at within the range", %{column: column} do
      recent = task_fixture(column)
      old = task_fixture(column)
      {:ok, _} = complete_task(recent, %{completed_at: DateTime.utc_now()})

      {:ok, _} =
        complete_task(old, %{completed_at: DateTime.add(DateTime.utc_now(), -60, :day)})

      board_id = board_id(column)
      rows = TaskQueries.get_cycle_time_tasks(board_id, time_range: :last_30_days)

      identifiers = Enum.map(rows, & &1.identifier)
      assert recent.identifier in identifiers
      refute old.identifier in identifiers
    end
  end

  describe "get_lead_time_tasks/2" do
    setup :regular_board_with_column

    test "measures lead time from inserted_at to completed_at", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_at: DateTime.utc_now()})

      board_id = board_id(column)
      assert [row] = TaskQueries.get_lead_time_tasks(board_id, time_range: :all_time)
      assert row.identifier == task.identifier
      assert Map.has_key?(row, :inserted_at)
      refute Map.has_key?(row, :claimed_at)
      assert to_float(row.lead_time_seconds) >= 0.0
    end

    test "does not require a move event (unlike cycle time on regular boards)", %{
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_at: DateTime.utc_now()})

      board_id = board_id(column)
      # No move history created; lead time still returns the row.
      assert [_row] = TaskQueries.get_lead_time_tasks(board_id, time_range: :all_time)
    end

    test "excludes goal-type tasks", %{column: column} do
      goal = task_fixture(column, %{type: :goal})
      {:ok, _} = complete_task(goal)

      board_id = board_id(column)
      assert TaskQueries.get_lead_time_tasks(board_id, time_range: :all_time) == []
    end

    test "filters by agent_name when provided", %{column: column} do
      mine = task_fixture(column)
      theirs = task_fixture(column)
      {:ok, _} = complete_task(mine, %{completed_by_agent: "Claude Opus 4.8"})
      {:ok, _} = complete_task(theirs, %{completed_by_agent: "Some Other Agent"})

      board_id = board_id(column)

      assert [row] =
               TaskQueries.get_lead_time_tasks(board_id,
                 time_range: :all_time,
                 agent_name: "Claude Opus 4.8"
               )

      assert row.identifier == mine.identifier
    end

    test "returns an empty list when no tasks are completed", %{column: column} do
      _open = task_fixture(column)

      board_id = board_id(column)
      assert TaskQueries.get_lead_time_tasks(board_id, time_range: :all_time) == []
    end
  end

  describe "get_throughput_tasks/2" do
    setup :ai_board_with_column

    test "returns completed non-goal tasks with the throughput row keys", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{completed_at: ~U[2026-06-01 12:00:00Z]})

      board_id = board_id(column)
      assert [row] = TaskQueries.get_throughput_tasks(board_id, time_range: :all_time)
      assert row.identifier == task.identifier
      assert Map.has_key?(row, :claimed_at)
      assert Map.has_key?(row, :inserted_at)
      assert row.completed_at == ~U[2026-06-01 12:00:00Z]
      refute Map.has_key?(row, :cycle_time_seconds)
    end

    test "excludes goal-type tasks", %{column: column} do
      goal = task_fixture(column, %{type: :goal})
      {:ok, _} = complete_task(goal)

      board_id = board_id(column)
      assert TaskQueries.get_throughput_tasks(board_id, time_range: :all_time) == []
    end

    test "excludes tasks that are not completed", %{column: column} do
      _open = task_fixture(column)

      board_id = board_id(column)
      assert TaskQueries.get_throughput_tasks(board_id, time_range: :all_time) == []
    end

    test "bounds results by completed_at within the time range", %{column: column} do
      recent = task_fixture(column)
      old = task_fixture(column)
      {:ok, _} = complete_task(recent, %{completed_at: DateTime.utc_now()})
      {:ok, _} = complete_task(old, %{completed_at: DateTime.add(DateTime.utc_now(), -60, :day)})

      board_id = board_id(column)

      identifiers =
        board_id |> TaskQueries.get_throughput_tasks(time_range: :last_30_days) |> ids()

      assert recent.identifier in identifiers
      refute old.identifier in identifiers
    end

    test "filters by agent_name when provided", %{column: column} do
      mine = task_fixture(column)
      theirs = task_fixture(column)
      {:ok, _} = complete_task(mine, %{completed_by_agent: "Claude Opus 4.8"})
      {:ok, _} = complete_task(theirs, %{completed_by_agent: "Some Other Agent"})

      board_id = board_id(column)

      assert [row] =
               TaskQueries.get_throughput_tasks(board_id,
                 time_range: :all_time,
                 agent_name: "Claude Opus 4.8"
               )

      assert row.identifier == mine.identifier
    end
  end

  describe "get_completed_goals/2" do
    setup :ai_board_with_column

    test "returns goals with a completed_at", %{column: column} do
      goal = task_fixture(column, %{type: :goal})
      {:ok, _} = complete_task(goal, %{completed_at: ~U[2026-06-01 12:00:00Z]})

      board_id = board_id(column)
      assert [row] = TaskQueries.get_completed_goals(board_id, time_range: :all_time)
      assert row.identifier == goal.identifier
      # completed_at comes back via coalesce(completed_at, updated_at) as a
      # NaiveDateTime — the exact (preserved) shape of the original inline query.
      assert row.completed_at == ~N[2026-06-01 12:00:00]
    end

    test "returns goals sitting in a column named done even without completed_at", %{board: board} do
      done_column = column_fixture(board, %{name: "Done"})
      goal = task_fixture(done_column, %{type: :goal})

      assert [row] = TaskQueries.get_completed_goals(board.id, time_range: :all_time)
      assert row.identifier == goal.identifier
      # completed_at falls back to updated_at via coalesce, so it is never nil.
      refute is_nil(row.completed_at)
    end

    test "excludes non-goal tasks", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      board_id = board_id(column)
      assert TaskQueries.get_completed_goals(board_id, time_range: :all_time) == []
    end

    test "filters by agent_name when provided", %{column: column} do
      mine = task_fixture(column, %{type: :goal})
      theirs = task_fixture(column, %{type: :goal})
      {:ok, _} = complete_task(mine, %{completed_by_agent: "Claude Opus 4.8"})
      {:ok, _} = complete_task(theirs, %{completed_by_agent: "Some Other Agent"})

      board_id = board_id(column)

      assert [row] =
               TaskQueries.get_completed_goals(board_id,
                 time_range: :all_time,
                 agent_name: "Claude Opus 4.8"
               )

      assert row.identifier == mine.identifier
    end
  end

  describe "get_review_wait_tasks/2 - AI-optimized boards" do
    setup :ai_board_with_column

    test "measures review wait from completed_at to reviewed_at", %{column: column} do
      task = task_fixture(column)

      {:ok, _} =
        complete_task(task, %{
          completed_at: ~U[2026-06-01 10:00:00Z],
          reviewed_at: ~U[2026-06-01 12:00:00Z]
        })

      board_id = board_id(column)
      assert [row] = TaskQueries.get_review_wait_tasks(board_id, time_range: :all_time)
      assert row.identifier == task.identifier
      # 2 hours between completion and review.
      assert_in_delta to_float(row.review_wait_seconds), 7200.0, 0.1
    end

    test "clamps a negative wait to zero (GREATEST)", %{column: column} do
      task = task_fixture(column)

      {:ok, _} =
        complete_task(task, %{
          completed_at: ~U[2026-06-01 12:00:00Z],
          reviewed_at: ~U[2026-06-01 10:00:00Z]
        })

      board_id = board_id(column)
      assert [row] = TaskQueries.get_review_wait_tasks(board_id, time_range: :all_time)
      assert to_float(row.review_wait_seconds) == 0.0
    end

    test "excludes tasks that were never reviewed", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{reviewed_at: nil})

      board_id = board_id(column)
      assert TaskQueries.get_review_wait_tasks(board_id, time_range: :all_time) == []
    end

    test "filters by agent_name when provided", %{column: column} do
      mine = task_fixture(column)
      theirs = task_fixture(column)
      reviewed = %{reviewed_at: ~U[2026-06-01 12:00:00Z], completed_at: ~U[2026-06-01 10:00:00Z]}
      {:ok, _} = complete_task(mine, Map.put(reviewed, :completed_by_agent, "Claude Opus 4.8"))
      {:ok, _} = complete_task(theirs, Map.put(reviewed, :completed_by_agent, "Other Agent"))

      board_id = board_id(column)

      assert [row] =
               TaskQueries.get_review_wait_tasks(board_id,
                 time_range: :all_time,
                 agent_name: "Claude Opus 4.8"
               )

      assert row.identifier == mine.identifier
    end
  end

  describe "get_review_wait_tasks/2 - regular boards" do
    setup :regular_board_with_column

    test "always returns an empty list (no review step)", %{column: column} do
      task = task_fixture(column)

      {:ok, _} =
        complete_task(task, %{
          completed_at: ~U[2026-06-01 10:00:00Z],
          reviewed_at: ~U[2026-06-01 12:00:00Z]
        })

      board_id = board_id(column)
      assert TaskQueries.get_review_wait_tasks(board_id, time_range: :all_time) == []
    end
  end

  describe "get_backlog_wait_tasks/2 - AI-optimized boards" do
    setup :ai_board_with_column

    test "measures backlog wait from inserted_at to claimed_at", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task, %{claimed_at: ~U[2026-06-01 12:00:00Z]})

      board_id = board_id(column)
      assert [row] = TaskQueries.get_backlog_wait_tasks(board_id, time_range: :all_time)
      assert row.identifier == task.identifier
      assert row.claimed_at == ~U[2026-06-01 12:00:00Z]
      assert to_float(row.backlog_wait_seconds) >= 0.0
    end

    test "excludes tasks without a claimed_at", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      board_id = board_id(column)
      assert TaskQueries.get_backlog_wait_tasks(board_id, time_range: :all_time) == []
    end

    test "filters by agent_name when provided", %{column: column} do
      mine = task_fixture(column)
      theirs = task_fixture(column)
      {:ok, _} = complete_task(mine, %{completed_by_agent: "Claude Opus 4.8"})
      {:ok, _} = complete_task(theirs, %{completed_by_agent: "Some Other Agent"})

      board_id = board_id(column)

      assert [row] =
               TaskQueries.get_backlog_wait_tasks(board_id,
                 time_range: :all_time,
                 agent_name: "Claude Opus 4.8"
               )

      assert row.identifier == mine.identifier
    end
  end

  describe "get_backlog_wait_tasks/2 - regular boards" do
    setup :regular_board_with_column

    test "derives backlog wait from the first move event, aliased to claimed_at", %{
      column: column
    } do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)
      create_move_history(task, "Backlog", "In Progress", ~U[2026-06-01 12:00:00Z])

      board_id = board_id(column)
      assert [row] = TaskQueries.get_backlog_wait_tasks(board_id, time_range: :all_time)
      assert row.identifier == task.identifier
      assert row.claimed_at == ~N[2026-06-01 12:00:00]
      assert to_float(row.backlog_wait_seconds) >= 0.0
    end

    test "excludes tasks that were never moved", %{column: column} do
      task = task_fixture(column)
      {:ok, _} = complete_task(task)

      board_id = board_id(column)
      assert TaskQueries.get_backlog_wait_tasks(board_id, time_range: :all_time) == []
    end
  end

  describe "default options (opts omitted)" do
    setup :ai_board_with_column

    test "every query defaults to the last-30-days window", %{column: column} do
      task = task_fixture(column)

      {:ok, _} =
        complete_task(task, %{
          needs_review: true,
          reviewed_at: DateTime.utc_now()
        })

      goal = task_fixture(column, %{type: :goal})
      {:ok, _} = Tasks.update_task(goal, %{completed_at: DateTime.utc_now()})

      board_id = board_id(column)

      assert [%{identifier: cycle_id}] = TaskQueries.get_cycle_time_tasks(board_id)
      assert cycle_id == task.identifier

      assert [%{identifier: lead_id}] = TaskQueries.get_lead_time_tasks(board_id)
      assert lead_id == task.identifier

      assert [%{identifier: throughput_id}] = TaskQueries.get_throughput_tasks(board_id)
      assert throughput_id == task.identifier

      assert [%{identifier: goal_id}] = TaskQueries.get_completed_goals(board_id)
      assert goal_id == goal.identifier

      assert [%{identifier: review_id}] = TaskQueries.get_review_wait_tasks(board_id)
      assert review_id == task.identifier

      assert [%{identifier: backlog_id}] = TaskQueries.get_backlog_wait_tasks(board_id)
      assert backlog_id == task.identifier
    end

    test "the default window excludes completions older than 30 days", %{column: column} do
      task = task_fixture(column)
      old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)

      {:ok, _} =
        complete_task(task, %{
          claimed_at: DateTime.add(old, -3600, :second),
          completed_at: old,
          reviewed_at: old
        })

      board_id = board_id(column)

      assert TaskQueries.get_cycle_time_tasks(board_id) == []
      assert TaskQueries.get_lead_time_tasks(board_id) == []
      assert TaskQueries.get_throughput_tasks(board_id) == []
      assert TaskQueries.get_review_wait_tasks(board_id) == []
      assert TaskQueries.get_backlog_wait_tasks(board_id) == []
    end
  end

  defp ai_board_with_column(_context) do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  defp regular_board_with_column(_context) do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  defp complete_task(task, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          claimed_at: DateTime.add(DateTime.utc_now(), -24, :hour),
          completed_at: DateTime.utc_now()
        },
        attrs
      )

    Tasks.update_task(task, attrs)
  end

  defp create_move_history(task, from_column, to_column, inserted_at) do
    %Kanban.Tasks.TaskHistory{}
    |> Kanban.Tasks.TaskHistory.changeset(%{
      type: :move,
      task_id: task.id,
      from_column: from_column,
      to_column: to_column
    })
    |> Ecto.Changeset.force_change(
      :inserted_at,
      inserted_at |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
    )
    |> Kanban.Repo.insert!()
  end

  defp board_id(column), do: Kanban.Repo.reload!(column).board_id

  defp to_float(%Decimal{} = value), do: Decimal.to_float(value)
  defp to_float(value) when is_number(value), do: value / 1

  defp ids(rows), do: Enum.map(rows, & &1.identifier)
end
