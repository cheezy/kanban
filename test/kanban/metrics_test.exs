defmodule Kanban.MetricsTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Metrics
  alias Kanban.Tasks

  describe "get_dashboard_summary/2" do
    test "returns all metrics in a single call" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Create completed task
      task = task_fixture(column)
      {:ok, _} = complete_task_with_timestamps(task)

      {:ok, summary} = Metrics.get_dashboard_summary(board.id)

      assert Map.has_key?(summary, :throughput)
      assert Map.has_key?(summary, :cycle_time)
      assert Map.has_key?(summary, :lead_time)
      assert Map.has_key?(summary, :wait_time)
    end

    test "handles empty board" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, summary} = Metrics.get_dashboard_summary(board.id)

      assert summary.throughput == []
      assert summary.cycle_time.count == 0
      assert summary.lead_time.count == 0
      assert summary.wait_time.review_wait.count == 0
      assert summary.wait_time.backlog_wait.count == 0
    end

    test "accepts time_range option" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, summary} = Metrics.get_dashboard_summary(board.id, time_range: :last_7_days)

      assert summary.throughput == []
    end
  end

  describe "get_throughput/2" do
    test "returns completed tasks count per day" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Create tasks completed on different days
      task1 = task_fixture(column)
      task2 = task_fixture(column)

      completed_at_1 = DateTime.add(DateTime.utc_now(), -2, :day)
      completed_at_2 = DateTime.add(DateTime.utc_now(), -1, :day)

      {:ok, _} = Tasks.update_task(task1, %{completed_at: completed_at_1})
      {:ok, _} = Tasks.update_task(task2, %{completed_at: completed_at_2})

      {:ok, throughput} = Metrics.get_throughput(board.id, time_range: :last_7_days)

      assert length(throughput) == 2
      assert Enum.all?(throughput, fn item -> item.count == 1 end)
    end

    test "returns empty list for board with no completed tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task_fixture(column)

      {:ok, throughput} = Metrics.get_throughput(board.id)

      assert throughput == []
    end

    test "filters by time_range" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Complete task 60 days ago (outside last_30_days)
      completed_at = DateTime.add(DateTime.utc_now(), -60, :day)
      {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})

      {:ok, throughput_30} = Metrics.get_throughput(board.id, time_range: :last_30_days)
      {:ok, throughput_90} = Metrics.get_throughput(board.id, time_range: :last_90_days)

      assert throughput_30 == []
      assert length(throughput_90) == 1
    end

    test "filters by today time range" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task_today = task_fixture(column)
      task_yesterday = task_fixture(column)

      # Complete one task today
      completed_today = DateTime.utc_now()
      {:ok, _} = Tasks.update_task(task_today, %{completed_at: completed_today})

      # Complete another task yesterday
      completed_yesterday = DateTime.add(DateTime.utc_now(), -1, :day)
      {:ok, _} = Tasks.update_task(task_yesterday, %{completed_at: completed_yesterday})

      {:ok, throughput_today} = Metrics.get_throughput(board.id, time_range: :today)
      {:ok, throughput_7_days} = Metrics.get_throughput(board.id, time_range: :last_7_days)

      assert length(throughput_today) == 1
      assert length(throughput_7_days) == 2
    end

    test "filters by agent_name" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} =
        complete_task_with_timestamps(task1, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _} =
        complete_task_with_timestamps(task2, %{completed_by_agent: "GPT-4"})

      {:ok, throughput} =
        Metrics.get_throughput(board.id, agent_name: "Claude Sonnet 4.5")

      refute Enum.empty?(throughput)
    end

    test "excludes weekends when option is set" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Complete task on a Saturday (2026-02-01 was a Sunday, so use a Saturday)
      saturday = ~U[2026-01-31 10:00:00Z]
      {:ok, _} = Tasks.update_task(task, %{completed_at: saturday})

      {:ok, throughput_with_weekends} = Metrics.get_throughput(board.id, exclude_weekends: false)

      {:ok, throughput_without_weekends} =
        Metrics.get_throughput(board.id, exclude_weekends: true)

      assert [_] = throughput_with_weekends
      assert throughput_without_weekends == []
    end

    test "only counts tasks from specified board" do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)
      column1 = column_fixture(board1)
      column2 = column_fixture(board2)

      task1 = task_fixture(column1)
      task2 = task_fixture(column2)

      {:ok, _} = complete_task_with_timestamps(task1)
      {:ok, _} = complete_task_with_timestamps(task2)

      {:ok, throughput1} = Metrics.get_throughput(board1.id)
      {:ok, throughput2} = Metrics.get_throughput(board2.id)

      refute Enum.empty?(throughput1)
      refute Enum.empty?(throughput2)
    end
  end

  describe "get_cycle_time_stats/2" do
    test "calculates average cycle time from claimed_at to completed_at" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -24, :hour)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 1
      assert stats.average_hours >= 23 and stats.average_hours <= 25
      assert stats.min_hours >= 23
      assert stats.max_hours <= 25
    end

    test "returns zero stats for empty board" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.average_hours == 0
      assert stats.median_hours == 0
      assert stats.min_hours == 0
      assert stats.max_hours == 0
      assert stats.count == 0
    end

    test "excludes tasks without claimed_at" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Complete without claiming
      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 0
    end

    test "calculates median correctly" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      # Create 5 tasks with different cycle times
      for hours <- [10, 20, 30, 40, 50] do
        task = task_fixture(column)
        claimed_at = DateTime.add(DateTime.utc_now(), -hours, :hour)
        completed_at = DateTime.utc_now()

        {:ok, _} =
          Tasks.update_task(task, %{
            claimed_at: claimed_at,
            completed_at: completed_at
          })
      end

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 5
      assert stats.median_hours == 30.0
      assert stats.average_hours == 30.0
    end

    test "filters by time_range" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Complete task 60 days ago
      claimed_at = DateTime.add(DateTime.utc_now(), -60, :day) |> DateTime.add(-24, :hour)
      completed_at = DateTime.add(DateTime.utc_now(), -60, :day)

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, stats_30} = Metrics.get_cycle_time_stats(board.id, time_range: :last_30_days)
      {:ok, stats_90} = Metrics.get_cycle_time_stats(board.id, time_range: :last_90_days)

      assert stats_30.count == 0
      assert stats_90.count == 1
    end
  end

  describe "get_lead_time_stats/2" do
    test "calculates lead time from inserted_at to completed_at" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Task created 48 hours ago, completed now
      inserted_at =
        DateTime.add(DateTime.utc_now(), -48, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      completed_at = DateTime.utc_now()

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})

      {:ok, stats} = Metrics.get_lead_time_stats(board.id)

      assert stats.count == 1
      assert stats.average_hours >= 47 and stats.average_hours <= 49
    end

    test "always uses completed_at regardless of reviewed_at" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      inserted_at =
        DateTime.add(DateTime.utc_now(), -48, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      completed_at = DateTime.add(DateTime.utc_now(), -2, :hour)
      reviewed_at = DateTime.utc_now()

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      {:ok, _} =
        Tasks.update_task(task, %{
          completed_at: completed_at,
          reviewed_at: reviewed_at
        })

      {:ok, stats} = Metrics.get_lead_time_stats(board.id)

      assert stats.count == 1
      # Should be ~46 hours (to completed_at), not ~48 hours (to reviewed_at)
      assert stats.average_hours >= 45 and stats.average_hours <= 47
    end

    test "returns zero stats for empty board" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, stats} = Metrics.get_lead_time_stats(board.id)

      assert stats.count == 0
    end
  end

  describe "get_wait_time_stats/2" do
    test "calculates review wait time" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      completed_at = DateTime.add(DateTime.utc_now(), -12, :hour)
      reviewed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          completed_at: completed_at,
          reviewed_at: reviewed_at
        })

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      assert stats.review_wait.count == 1
      assert stats.review_wait.average_hours >= 11 and stats.review_wait.average_hours <= 13
    end

    test "calculates backlog wait time" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      inserted_at =
        DateTime.add(DateTime.utc_now(), -18, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      claimed_at = DateTime.utc_now()

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      {:ok, _} = Tasks.update_task(task, %{claimed_at: claimed_at})

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      assert stats.backlog_wait.count == 1
      assert stats.backlog_wait.average_hours >= 17 and stats.backlog_wait.average_hours <= 19
    end

    test "returns separate stats for review and backlog wait" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column)
      task2 = task_fixture(column)

      # Task 1: Has review wait time
      {:ok, _} =
        Tasks.update_task(task1, %{
          completed_at: DateTime.add(DateTime.utc_now(), -6, :hour),
          reviewed_at: DateTime.utc_now()
        })

      # Task 2: Has backlog wait time
      inserted_at =
        DateTime.add(DateTime.utc_now(), -12, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      {:ok, task2} =
        task2
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      {:ok, _} = Tasks.update_task(task2, %{claimed_at: DateTime.utc_now()})

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      assert stats.review_wait.count == 1
      assert stats.backlog_wait.count == 1
    end

    test "returns zero stats when no wait times exist" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      assert stats.review_wait.count == 0
      assert stats.backlog_wait.count == 0
    end
  end

  describe "get_cycle_time_stats/2 with weekend exclusion" do
    test "excludes weekend time from cycle time calculation" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Claimed Friday evening, completed Monday morning (includes full weekend)
      claimed_at = ~U[2026-01-30 18:00:00Z]
      completed_at = ~U[2026-02-02 10:00:00Z]

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, stats_with_weekends} = Metrics.get_cycle_time_stats(board.id, exclude_weekends: false)

      {:ok, stats_without_weekends} =
        Metrics.get_cycle_time_stats(board.id, exclude_weekends: true)

      assert stats_with_weekends.count == 1
      assert stats_without_weekends.count == 1
      # Should be significantly less when excluding weekends (2 full weekend days = 48 hours)
      assert stats_without_weekends.average_hours < stats_with_weekends.average_hours - 40
    end

    test "handles tasks completed on weekends with exclusion" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Claimed and completed on Saturday
      claimed_at = ~U[2026-01-31 10:00:00Z]
      completed_at = ~U[2026-01-31 16:00:00Z]

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id, exclude_weekends: true)

      assert stats.count == 1
      # Weekend time should be excluded
      assert stats.average_hours >= 0
    end
  end

  describe "get_lead_time_stats/2 with weekend exclusion" do
    test "excludes weekend time from lead time calculation" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Created Friday, completed Monday (includes weekend)
      inserted_at =
        ~U[2026-01-30 10:00:00Z]
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      completed_at = ~U[2026-02-02 10:00:00Z]

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})

      {:ok, stats_with_weekends} = Metrics.get_lead_time_stats(board.id, exclude_weekends: false)

      {:ok, stats_without_weekends} =
        Metrics.get_lead_time_stats(board.id, exclude_weekends: true)

      assert stats_without_weekends.average_hours < stats_with_weekends.average_hours - 40
    end
  end

  describe "get_wait_time_stats/2 with weekend exclusion" do
    test "excludes weekends from review wait time" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Completed Friday, reviewed Monday
      completed_at = ~U[2026-01-30 18:00:00Z]
      reviewed_at = ~U[2026-02-02 10:00:00Z]

      {:ok, _} =
        Tasks.update_task(task, %{
          completed_at: completed_at,
          reviewed_at: reviewed_at
        })

      {:ok, stats_with_weekends} = Metrics.get_wait_time_stats(board.id, exclude_weekends: false)

      {:ok, stats_without_weekends} =
        Metrics.get_wait_time_stats(board.id, exclude_weekends: true)

      assert stats_without_weekends.review_wait.average_hours <
               stats_with_weekends.review_wait.average_hours - 40
    end

    test "excludes weekends from backlog wait time" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Created Friday, claimed Monday
      inserted_at =
        ~U[2026-01-30 10:00:00Z]
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      claimed_at = ~U[2026-02-02 10:00:00Z]

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      {:ok, _} = Tasks.update_task(task, %{claimed_at: claimed_at})

      {:ok, stats_with_weekends} = Metrics.get_wait_time_stats(board.id, exclude_weekends: false)

      {:ok, stats_without_weekends} =
        Metrics.get_wait_time_stats(board.id, exclude_weekends: true)

      assert stats_without_weekends.backlog_wait.average_hours <
               stats_with_weekends.backlog_wait.average_hours - 40
    end
  end

  describe "time_range: :all_time" do
    test "get_throughput includes tasks from any date" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Complete task 365 days ago
      completed_at = DateTime.add(DateTime.utc_now(), -365, :day)
      {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})

      {:ok, throughput_30} = Metrics.get_throughput(board.id, time_range: :last_30_days)
      {:ok, throughput_all} = Metrics.get_throughput(board.id, time_range: :all_time)

      assert throughput_30 == []
      refute Enum.empty?(throughput_all)
    end

    test "get_cycle_time_stats includes tasks from any date" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -365, :day) |> DateTime.add(-24, :hour)
      completed_at = DateTime.add(DateTime.utc_now(), -365, :day)

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      {:ok, stats_30} = Metrics.get_cycle_time_stats(board.id, time_range: :last_30_days)
      {:ok, stats_all} = Metrics.get_cycle_time_stats(board.id, time_range: :all_time)

      assert stats_30.count == 0
      assert stats_all.count == 1
    end

    test "get_lead_time_stats includes tasks from any date" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      completed_at = DateTime.add(DateTime.utc_now(), -365, :day)
      {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})

      {:ok, stats_30} = Metrics.get_lead_time_stats(board.id, time_range: :last_30_days)
      {:ok, stats_all} = Metrics.get_lead_time_stats(board.id, time_range: :all_time)

      assert stats_30.count == 0
      assert stats_all.count == 1
    end
  end

  describe "agent filtering edge cases" do
    test "filters by created_by_agent when task not completed by agent" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column)
      task2 = task_fixture(column)

      # Task1 created by Claude but not completed by agent
      {:ok, _} =
        Tasks.update_task(task1, %{
          created_by_agent: "Claude Sonnet 4.5",
          completed_at: DateTime.utc_now()
        })

      # Task2 created by GPT-4
      {:ok, _task2} =
        Tasks.update_task(task2, %{
          created_by_agent: "GPT-4",
          completed_at: DateTime.utc_now()
        })

      {:ok, throughput} =
        Metrics.get_throughput(board.id, agent_name: "Claude Sonnet 4.5")

      refute Enum.empty?(throughput)
    end

    test "includes tasks where agent is creator OR completer" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column)
      task2 = task_fixture(column)

      # Task1 created by Claude (completed on day 1)
      {:ok, _} =
        Tasks.update_task(task1, %{
          created_by_agent: "Claude Sonnet 4.5",
          claimed_at: DateTime.add(DateTime.utc_now(), -48, :hour),
          completed_at: DateTime.add(DateTime.utc_now(), -24, :hour)
        })

      # Task2 completed by Claude (completed on day 2)
      {:ok, _} =
        complete_task_with_timestamps(task2, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, throughput} =
        Metrics.get_throughput(board.id, agent_name: "Claude Sonnet 4.5")

      # Should have 2 days with tasks (or 1 day if both completed same day)
      # Check that total count across all days is 2
      total_count = Enum.reduce(throughput, 0, fn day, acc -> acc + day.count end)
      assert total_count == 2
    end
  end

  describe "multiple tasks on same date" do
    test "aggregates throughput correctly for multiple tasks on same day" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Create 5 tasks completed on the same day
      completed_at = DateTime.add(DateTime.utc_now(), -1, :day)

      for _ <- 1..5 do
        task = task_fixture(column)
        {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})
      end

      {:ok, throughput} = Metrics.get_throughput(board.id)

      day_count =
        Enum.find(throughput, fn t ->
          Date.compare(t.date, DateTime.to_date(completed_at)) == :eq
        end)

      assert day_count != nil
      assert day_count.count == 5
    end

    test "calculates stats correctly with multiple tasks" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      # Create 10 tasks with varying cycle times
      for hours <- 1..10 do
        task = task_fixture(column)
        claimed_at = DateTime.add(DateTime.utc_now(), -hours, :hour)
        completed_at = DateTime.utc_now()

        {:ok, _} =
          Tasks.update_task(task, %{
            claimed_at: claimed_at,
            completed_at: completed_at
          })
      end

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 10
      assert stats.min_hours >= 0.9
      assert stats.max_hours <= 10.1
      assert stats.median_hours == 5.5
    end
  end

  describe "invalid/unknown time_range" do
    test "defaults to last_30_days for unknown time_range" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Complete task 60 days ago (outside 30 days, inside 90 days)
      completed_at = DateTime.add(DateTime.utc_now(), -60, :day)
      {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})

      {:ok, throughput_invalid} =
        Metrics.get_throughput(board.id, time_range: :invalid_range)

      {:ok, throughput_30} = Metrics.get_throughput(board.id, time_range: :last_30_days)

      assert throughput_invalid == throughput_30
      assert throughput_invalid == []
    end

    test "handles nil time_range" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)
      {:ok, _} = complete_task_with_timestamps(task)

      {:ok, throughput_nil} = Metrics.get_throughput(board.id, time_range: nil)
      {:ok, throughput_default} = Metrics.get_throughput(board.id)

      assert throughput_nil == throughput_default
    end
  end

  describe "Decimal seconds conversion" do
    test "handles Decimal type from database for cycle time" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      claimed_at = DateTime.add(DateTime.utc_now(), -2, :hour)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          claimed_at: claimed_at,
          completed_at: completed_at
        })

      # This should handle Decimal conversion internally
      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 1
      assert is_float(stats.average_hours)
      assert stats.average_hours >= 1.9 and stats.average_hours <= 2.1
    end

    test "handles Decimal type for wait time stats" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      completed_at = DateTime.add(DateTime.utc_now(), -3, :hour)
      reviewed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          completed_at: completed_at,
          reviewed_at: reviewed_at
        })

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      assert stats.review_wait.count == 1
      assert is_float(stats.review_wait.average_hours)
      assert stats.review_wait.average_hours >= 2.9 and stats.review_wait.average_hours <= 3.1
    end
  end

  describe "min and max hours in stats" do
    test "returns correct min and max for cycle time" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      # Create tasks with 1h, 5h, and 10h cycle times
      for hours <- [1, 5, 10] do
        task = task_fixture(column)
        claimed_at = DateTime.add(DateTime.utc_now(), -hours, :hour)
        completed_at = DateTime.utc_now()

        {:ok, _} =
          Tasks.update_task(task, %{
            claimed_at: claimed_at,
            completed_at: completed_at
          })
      end

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 3
      assert stats.min_hours >= 0.9 and stats.min_hours <= 1.1
      assert stats.max_hours >= 9.9 and stats.max_hours <= 10.1
    end

    test "returns correct min and max for lead time" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      # Create tasks with different lead times
      for hours <- [12, 24, 48] do
        task = task_fixture(column)

        inserted_at =
          DateTime.add(DateTime.utc_now(), -hours, :hour)
          |> DateTime.to_naive()
          |> NaiveDateTime.truncate(:second)

        completed_at = DateTime.utc_now()

        {:ok, task} =
          task
          |> Ecto.Changeset.change(%{inserted_at: inserted_at})
          |> Kanban.Repo.update()

        {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})
      end

      {:ok, stats} = Metrics.get_lead_time_stats(board.id)

      assert stats.count == 3
      assert stats.min_hours >= 11.9 and stats.min_hours <= 12.1
      assert stats.max_hours >= 47.9 and stats.max_hours <= 48.1
    end
  end

  describe "get_agents/1" do
    test "returns list of agents who completed tasks" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column)
      task2 = task_fixture(column)

      {:ok, _} =
        complete_task_with_timestamps(task1, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _} = complete_task_with_timestamps(task2, %{completed_by_agent: "GPT-4"})

      {:ok, agents} = Metrics.get_agents(board.id)

      assert "Claude Sonnet 4.5" in agents
      assert "GPT-4" in agents
      assert length(agents) == 2
    end

    test "returns list of agents who created tasks" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      {:ok, _} =
        Tasks.update_task(task, %{
          created_by_agent: "Claude Sonnet 4.5",
          completed_at: DateTime.utc_now()
        })

      {:ok, agents} = Metrics.get_agents(board.id)

      assert "Claude Sonnet 4.5" in agents
    end

    test "returns unique sorted list of agents" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      # Create multiple tasks by same agents
      task1 = task_fixture(column)
      task2 = task_fixture(column)
      task3 = task_fixture(column)

      {:ok, _} =
        complete_task_with_timestamps(task1, %{completed_by_agent: "GPT-4"})

      {:ok, _} =
        complete_task_with_timestamps(task2, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _} =
        complete_task_with_timestamps(task3, %{completed_by_agent: "GPT-4"})

      {:ok, agents} = Metrics.get_agents(board.id)

      # Should be sorted alphabetically and unique
      assert agents == ["Claude Sonnet 4.5", "GPT-4"]
    end

    test "returns empty list for board with no agent activity" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task_fixture(column)

      {:ok, agents} = Metrics.get_agents(board.id)

      assert agents == []
    end

    test "includes agents from both created_by_agent and completed_by_agent" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task1 = task_fixture(column)
      task2 = task_fixture(column)

      # Task1 created by one agent, completed by another
      {:ok, _} =
        Tasks.update_task(task1, %{
          created_by_agent: "Claude Opus",
          claimed_at: DateTime.add(DateTime.utc_now(), -24, :hour),
          completed_at: DateTime.utc_now(),
          completed_by_agent: "Claude Sonnet 4.5"
        })

      # Task2 only created by agent
      {:ok, _} = Tasks.update_task(task2, %{created_by_agent: "GPT-4"})

      {:ok, agents} = Metrics.get_agents(board.id)

      assert "Claude Opus" in agents
      assert "Claude Sonnet 4.5" in agents
      assert "GPT-4" in agents
      assert length(agents) == 3
    end

    test "only returns agents from specified board" do
      user = user_fixture()
      board1 = ai_optimized_board_fixture(user)
      board2 = ai_optimized_board_fixture(user)
      column1 = column_fixture(board1)
      column2 = column_fixture(board2)

      task1 = task_fixture(column1)
      task2 = task_fixture(column2)

      {:ok, _} =
        complete_task_with_timestamps(task1, %{completed_by_agent: "Claude Sonnet 4.5"})

      {:ok, _} = complete_task_with_timestamps(task2, %{completed_by_agent: "GPT-4"})

      {:ok, agents1} = Metrics.get_agents(board1.id)
      {:ok, agents2} = Metrics.get_agents(board2.id)

      assert agents1 == ["Claude Sonnet 4.5"]
      assert agents2 == ["GPT-4"]
    end
  end

  describe "regular board metrics - cycle time from TaskHistory" do
    test "derives cycle time from first TaskHistory move" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Simulate first move (work started) 24 hours ago
      started_at =
        DateTime.add(DateTime.utc_now(), -24, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      create_move_history(task, "Backlog", "Doing", started_at)

      # Complete the task now
      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 1
      assert stats.average_hours >= 23 and stats.average_hours <= 25
    end

    test "uses earliest move as start time when multiple moves exist" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # First move 48 hours ago
      first_move_at =
        DateTime.add(DateTime.utc_now(), -48, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      # Second move 24 hours ago
      second_move_at =
        DateTime.add(DateTime.utc_now(), -24, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      create_move_history(task, "Backlog", "Doing", first_move_at)
      create_move_history(task, "Doing", "Review", second_move_at)

      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 1
      # Should use first move (48h ago), not second move (24h ago)
      assert stats.average_hours >= 47 and stats.average_hours <= 49
    end

    test "returns zero stats when no TaskHistory moves exist" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)
      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 0
    end

    test "excludes incomplete tasks from cycle time" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      started_at =
        DateTime.add(DateTime.utc_now(), -24, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      create_move_history(task, "Backlog", "Doing", started_at)
      # Don't set completed_at

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 0
    end

    test "filters cycle time by time_range for regular boards" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Move happened 60 days ago
      started_at =
        DateTime.add(DateTime.utc_now(), -60, :day)
        |> DateTime.add(-24, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      create_move_history(task, "Backlog", "Doing", started_at)

      completed_at = DateTime.add(DateTime.utc_now(), -60, :day)
      {:ok, _} = Tasks.update_task(task, %{completed_at: completed_at})

      {:ok, stats_30} = Metrics.get_cycle_time_stats(board.id, time_range: :last_30_days)
      {:ok, stats_90} = Metrics.get_cycle_time_stats(board.id, time_range: :last_90_days)

      assert stats_30.count == 0
      assert stats_90.count == 1
    end

    test "calculates stats correctly with multiple regular board tasks" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      for hours <- [10, 20, 30] do
        task = task_fixture(column)

        started_at =
          DateTime.add(DateTime.utc_now(), -hours, :hour)
          |> DateTime.to_naive()
          |> NaiveDateTime.truncate(:second)

        create_move_history(task, "Backlog", "Doing", started_at)
        {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})
      end

      {:ok, stats} = Metrics.get_cycle_time_stats(board.id)

      assert stats.count == 3
      assert stats.median_hours >= 19.9 and stats.median_hours <= 20.1
      assert stats.min_hours >= 9.9 and stats.min_hours <= 10.1
      assert stats.max_hours >= 29.9 and stats.max_hours <= 30.1
    end
  end

  describe "regular board metrics - wait time from TaskHistory" do
    test "returns empty review_wait and calculates backlog_wait from TaskHistory" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Set inserted_at to 18 hours ago
      inserted_at =
        DateTime.add(DateTime.utc_now(), -18, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      # First move happened now (18 hours of waiting)
      first_moved_at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      create_move_history(task, "Backlog", "Doing", first_moved_at)

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      # Review wait should always be empty for regular boards
      assert stats.review_wait.count == 0
      assert stats.review_wait.average_hours == 0

      # Backlog wait should reflect time from inserted_at to first move
      assert stats.backlog_wait.count == 1
      assert stats.backlog_wait.average_hours >= 17 and stats.backlog_wait.average_hours <= 19
    end

    test "returns zero stats when no TaskHistory moves exist for wait time" do
      user = user_fixture()
      board = board_fixture(user)

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      assert stats.review_wait.count == 0
      assert stats.backlog_wait.count == 0
    end

    test "backlog wait uses earliest move per task" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      inserted_at =
        DateTime.add(DateTime.utc_now(), -48, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      # First move 24 hours ago
      first_move_at =
        DateTime.add(DateTime.utc_now(), -24, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      # Second move 12 hours ago
      second_move_at =
        DateTime.add(DateTime.utc_now(), -12, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      create_move_history(task, "Backlog", "Doing", first_move_at)
      create_move_history(task, "Doing", "Review", second_move_at)

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      # Backlog wait should be ~24 hours (inserted_at to first move)
      assert stats.backlog_wait.count == 1
      assert stats.backlog_wait.average_hours >= 23 and stats.backlog_wait.average_hours <= 25
    end

    test "filters backlog wait by time_range for regular boards" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Task created 60 days ago
      inserted_at =
        DateTime.add(DateTime.utc_now(), -60, :day)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      first_moved_at =
        DateTime.add(DateTime.utc_now(), -59, :day)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      create_move_history(task, "Backlog", "Doing", first_moved_at)

      {:ok, stats_30} = Metrics.get_wait_time_stats(board.id, time_range: :last_30_days)
      {:ok, stats_90} = Metrics.get_wait_time_stats(board.id, time_range: :last_90_days)

      assert stats_30.backlog_wait.count == 0
      assert stats_90.backlog_wait.count == 1
    end
  end

  describe "regular board metrics - agents" do
    test "returns empty list for regular boards" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      {:ok, _} =
        Tasks.update_task(task, %{
          completed_by_agent: "Claude Sonnet 4.5",
          completed_at: DateTime.utc_now()
        })

      {:ok, agents} = Metrics.get_agents(board.id)

      # Regular boards should always return empty agent list
      assert agents == []
    end
  end

  describe "regular board metrics - throughput works without changes" do
    test "throughput works for regular boards using completed_at" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)
      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      {:ok, throughput} = Metrics.get_throughput(board.id)

      refute Enum.empty?(throughput)
      assert hd(throughput).count == 1
    end
  end

  describe "regular board metrics - lead time works without changes" do
    test "lead time works for regular boards using inserted_at to completed_at" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      inserted_at =
        DateTime.add(DateTime.utc_now(), -24, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      {:ok, stats} = Metrics.get_lead_time_stats(board.id)

      assert stats.count == 1
      assert stats.average_hours >= 23 and stats.average_hours <= 25
    end
  end

  describe "regular board metrics - dashboard summary" do
    test "dashboard summary works for regular boards" do
      user = user_fixture()
      board = board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Create TaskHistory move and complete the task
      started_at =
        DateTime.add(DateTime.utc_now(), -24, :hour)
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      create_move_history(task, "Backlog", "Doing", started_at)
      {:ok, _} = Tasks.update_task(task, %{completed_at: DateTime.utc_now()})

      {:ok, summary} = Metrics.get_dashboard_summary(board.id)

      assert Map.has_key?(summary, :throughput)
      assert Map.has_key?(summary, :cycle_time)
      assert Map.has_key?(summary, :lead_time)
      assert Map.has_key?(summary, :wait_time)

      # Regular board should have zero review_wait
      assert summary.wait_time.review_wait.count == 0
    end
  end

  # Helper functions

  defp create_move_history(task, from_column, to_column, inserted_at) do
    %Kanban.Tasks.TaskHistory{}
    |> Kanban.Tasks.TaskHistory.changeset(%{
      type: :move,
      task_id: task.id,
      from_column: from_column,
      to_column: to_column
    })
    |> Ecto.Changeset.force_change(:inserted_at, inserted_at)
    |> Kanban.Repo.insert!()
  end

  defp complete_task_with_timestamps(task, attrs \\ %{}) do
    claimed_at = DateTime.add(DateTime.utc_now(), -24, :hour)
    completed_at = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          claimed_at: claimed_at,
          completed_at: completed_at
        },
        attrs
      )

    Tasks.update_task(task, attrs)
  end
end
