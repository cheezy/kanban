defmodule Kanban.MetricsTest do
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
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

      {:ok, throughput_with_weekends} =
        Metrics.get_throughput(board.id, exclude_weekends: false, time_range: :all_time)

      {:ok, throughput_without_weekends} =
        Metrics.get_throughput(board.id, exclude_weekends: true, time_range: :all_time)

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

    test "clamps review wait time to zero when reviewed_at is before completed_at" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Simulate data inconsistency: reviewed_at is before completed_at
      reviewed_at = DateTime.add(DateTime.utc_now(), -6, :hour)
      completed_at = DateTime.utc_now()

      {:ok, _} =
        Tasks.update_task(task, %{
          completed_at: completed_at,
          reviewed_at: reviewed_at
        })

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      assert stats.review_wait.count == 1
      assert stats.review_wait.average_hours >= 0
      assert stats.review_wait.min_hours >= 0
    end

    test "clamps backlog wait time to zero when claimed_at is before inserted_at" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      column = column_fixture(board)

      task = task_fixture(column)

      # Simulate data inconsistency: claimed_at is before inserted_at
      # Set inserted_at to now and claimed_at to 6 hours ago
      inserted_at =
        DateTime.utc_now()
        |> DateTime.to_naive()
        |> NaiveDateTime.truncate(:second)

      claimed_at = DateTime.add(DateTime.utc_now(), -6, :hour)

      {:ok, task} =
        task
        |> Ecto.Changeset.change(%{inserted_at: inserted_at})
        |> Kanban.Repo.update()

      {:ok, _} = Tasks.update_task(task, %{claimed_at: claimed_at})

      {:ok, stats} = Metrics.get_wait_time_stats(board.id)

      assert stats.backlog_wait.count == 1
      assert stats.backlog_wait.average_hours >= 0
      assert stats.backlog_wait.min_hours >= 0
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

      {:ok, stats_with_weekends} =
        Metrics.get_cycle_time_stats(board.id, exclude_weekends: false, time_range: :all_time)

      {:ok, stats_without_weekends} =
        Metrics.get_cycle_time_stats(board.id, exclude_weekends: true, time_range: :all_time)

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

      {:ok, stats} =
        Metrics.get_cycle_time_stats(board.id, exclude_weekends: true, time_range: :all_time)

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

      {:ok, stats_with_weekends} =
        Metrics.get_lead_time_stats(board.id, exclude_weekends: false, time_range: :all_time)

      {:ok, stats_without_weekends} =
        Metrics.get_lead_time_stats(board.id, exclude_weekends: true, time_range: :all_time)

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

      {:ok, stats_with_weekends} =
        Metrics.get_wait_time_stats(board.id, exclude_weekends: false, time_range: :all_time)

      {:ok, stats_without_weekends} =
        Metrics.get_wait_time_stats(board.id, exclude_weekends: true, time_range: :all_time)

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

      {:ok, stats_with_weekends} =
        Metrics.get_wait_time_stats(board.id, exclude_weekends: false, time_range: :all_time)

      {:ok, stats_without_weekends} =
        Metrics.get_wait_time_stats(board.id, exclude_weekends: true, time_range: :all_time)

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

  # =====================================================================
  # Workspace-level functions (W579)
  # =====================================================================

  defp ws_setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column, scope: Scope.for_user(user)}
  end

  defp ws_complete!(task, days_ago, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    completed_at = DateTime.add(now, -days_ago * 86_400, :second)
    claimed_at = DateTime.add(completed_at, -3600, :second)

    final =
      Map.merge(
        %{claimed_at: claimed_at, completed_at: completed_at},
        Map.new(attrs)
      )

    {:ok, t} = Tasks.update_task(task, final)
    t
  end

  describe "workspace reads accept a :timezone option (W1264 pass-through)" do
    # The option is threaded now but not yet consumed; omitting it must match
    # passing the documented "Etc/UTC" default. This invariant holds before and
    # after the later local-day bucketing work (omitted always defaults to UTC).
    setup do
      %{column: column, scope: scope} = ws_setup()
      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)
      %{scope: scope}
    end

    test "workspace_kpis: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Metrics.workspace_kpis(scope: scope, timezone: "Etc/UTC") ==
               Metrics.workspace_kpis(scope: scope)
    end

    test "cycle_time_daily: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Metrics.cycle_time_daily(scope: scope, timezone: "Etc/UTC") ==
               Metrics.cycle_time_daily(scope: scope)
    end

    test "throughput_daily: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Metrics.throughput_daily(scope: scope, timezone: "Etc/UTC") ==
               Metrics.throughput_daily(scope: scope)
    end

    test "agent_leaderboard: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Metrics.agent_leaderboard(scope: scope, timezone: "Etc/UTC") ==
               Metrics.agent_leaderboard(scope: scope)
    end

    test "cumulative_flow: omitting :timezone equals passing Etc/UTC", %{scope: scope} do
      assert Metrics.cumulative_flow(scope: scope, timezone: "Etc/UTC") ==
               Metrics.cumulative_flow(scope: scope)
    end
  end

  describe "workspace_kpis/1 — zero / nil scope" do
    test "returns the zero map for a user with no boards" do
      user = user_fixture()
      scope = Scope.for_user(user)
      stats = Metrics.workspace_kpis(scope: scope)

      assert stats.cycle_time_median_minutes == 0
      assert stats.lead_time_p75_minutes == 0
      assert stats.throughput_per_day == 0.0
      assert stats.review_wait_minutes == 0
      assert stats.cycle_time_delta_pct == 0.0
      assert stats.lead_time_delta_pct == 0.0
      assert stats.throughput_delta_pct == 0.0
      assert stats.review_wait_delta_pct == 0.0
    end

    test "returns the zero map when :scope is nil" do
      stats = Metrics.workspace_kpis(scope: nil)
      assert stats.cycle_time_median_minutes == 0
      assert stats.throughput_per_day == 0.0
    end

    test "returns the zero map when :scope is a Scope with a nil user" do
      assert Metrics.workspace_kpis(scope: %Scope{user: nil}).cycle_time_median_minutes == 0
    end
  end

  describe "workspace_kpis/1 — aggregation + deltas" do
    test "aggregates cycle time across two boards", %{} do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)
      col1 = column_fixture(board1)
      col2 = column_fixture(board2)

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      completed_at = DateTime.add(now, -1 * 86_400, :second)

      Enum.each(1..3, fn _ ->
        t = task_fixture(col1)
        claimed = DateTime.add(completed_at, -60 * 60, :second)
        Tasks.update_task(t, %{claimed_at: claimed, completed_at: completed_at})
      end)

      Enum.each(1..2, fn _ ->
        t = task_fixture(col2)
        # 180-minute cycle on the second board.
        claimed = DateTime.add(completed_at, -180 * 60, :second)
        Tasks.update_task(t, %{claimed_at: claimed, completed_at: completed_at})
      end)

      stats = Metrics.workspace_kpis(scope: Scope.for_user(user))
      # 5 tasks total: median of [60, 60, 60, 180, 180] = 60
      assert stats.cycle_time_median_minutes == 60
    end

    test "delta_pct is computed against the previous 14-day window",
         %{} do
      %{column: column, scope: scope} = ws_setup()

      # Current window: 3 tasks completed in the last 14 days
      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)

      # Previous window: 1 task completed in the prior 14-day window
      column |> task_fixture() |> ws_complete!(20)

      stats = Metrics.workspace_kpis(scope: scope)

      # Throughput delta: current = 3/14, previous = 1/14, delta = +200%
      assert_in_delta stats.throughput_delta_pct, 200.0, 0.1
    end

    test "delta_pct is 0.0 when the previous window was empty (divide-by-zero guard)",
         %{} do
      %{column: column, scope: scope} = ws_setup()

      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)

      stats = Metrics.workspace_kpis(scope: scope)
      assert stats.cycle_time_delta_pct == 0.0
      assert stats.throughput_delta_pct == 0.0
    end

    test "filters strictly to boards the scoped user belongs to",
         %{} do
      %{column: column, scope: scope} = ws_setup()
      column |> task_fixture() |> ws_complete!(1)

      # A second user with their own board — must not leak into the
      # original user's stats.
      other = user_fixture()
      other_board = board_fixture(other)
      other_col = column_fixture(other_board)
      Enum.each(1..10, fn _ -> other_col |> task_fixture() |> ws_complete!(1) end)

      stats = Metrics.workspace_kpis(scope: scope)
      assert stats.throughput_per_day == 1 / 14
    end
  end

  describe "workspace reads — :board_ids filter (scoped_board_ids/1)" do
    # scoped_board_ids/1 is private; its behavior is exercised through a
    # workspace read. throughput_per_day == completed_count / 14, so the task
    # counts below map directly to the asserted throughput.
    setup do
      user = user_fixture()
      board1 = board_fixture(user)
      board2 = board_fixture(user)
      col1 = column_fixture(board1)
      col2 = column_fixture(board2)

      # 3 tasks on board1, 5 on board2 — distinct counts so leakage is visible.
      Enum.each(1..3, fn _ -> col1 |> task_fixture() |> ws_complete!(1) end)
      Enum.each(1..5, fn _ -> col2 |> task_fixture() |> ws_complete!(1) end)

      %{user: user, board1: board1, board2: board2, scope: Scope.for_user(user)}
    end

    test "no :board_ids option returns all visible board ids (unchanged)", %{scope: scope} do
      stats = Metrics.workspace_kpis(scope: scope)
      assert stats.throughput_per_day == 8 / 14
    end

    test "a subset :board_ids returns exactly that subset", %{scope: scope, board1: board1} do
      stats = Metrics.workspace_kpis(scope: scope, board_ids: [board1.id])
      assert stats.throughput_per_day == 3 / 14
    end

    test "ids the user cannot see are dropped (intersection with visible only)", %{scope: scope} do
      other = user_fixture()
      other_board = board_fixture(other)
      other_col = column_fixture(other_board)
      Enum.each(1..10, fn _ -> other_col |> task_fixture() |> ws_complete!(1) end)

      stats = Metrics.workspace_kpis(scope: scope, board_ids: [other_board.id])
      assert stats.throughput_per_day == 0.0
    end

    test "a visible/invisible mix keeps only the visible ids", %{scope: scope, board1: board1} do
      other = user_fixture()
      other_board = board_fixture(other)

      stats = Metrics.workspace_kpis(scope: scope, board_ids: [board1.id, other_board.id])
      assert stats.throughput_per_day == 3 / 14
    end

    test "an empty :board_ids list intersects to nothing and returns the zero value",
         %{scope: scope} do
      stats = Metrics.workspace_kpis(scope: scope, board_ids: [])
      assert stats.throughput_per_day == 0.0
    end

    test "duplicate ids in :board_ids are not double-counted", %{scope: scope, board1: board1} do
      stats = Metrics.workspace_kpis(scope: scope, board_ids: [board1.id, board1.id])
      assert stats.throughput_per_day == 3 / 14
    end

    test "a different workspace read (throughput_daily/1) also honors :board_ids",
         %{scope: scope, board1: board1} do
      all = Metrics.throughput_daily(scope: scope)
      filtered = Metrics.throughput_daily(scope: scope, board_ids: [board1.id])

      assert Enum.sum(all) == 8
      assert Enum.sum(filtered) == 3
    end
  end

  describe "cycle_time_daily/1" do
    test "returns 14 entries ordered oldest-to-newest with date keys",
         %{} do
      %{scope: scope} = ws_setup()
      entries = Metrics.cycle_time_daily(scope: scope)

      assert length(entries) == 14
      dates = Enum.map(entries, & &1.date)
      assert dates == Enum.sort(dates, Date)

      for %{date: d, agent_minutes: a, human_minutes: h} <- entries do
        assert %Date{} = d
        assert is_integer(a)
        assert is_integer(h)
      end
    end

    test "splits agent vs human minutes by created_by_agent presence",
         %{} do
      %{column: column, scope: scope} = ws_setup()

      # 2-hour cycle for the agent task today
      agent_task = task_fixture(column, %{created_by_agent: "Claude"})

      ws_complete!(agent_task, 0,
        claimed_at: DateTime.add(DateTime.utc_now(), -2 * 3600, :second)
      )

      # 30-minute cycle for the human task today
      human_task = task_fixture(column, %{created_by_agent: nil})

      ws_complete!(human_task, 0, claimed_at: DateTime.add(DateTime.utc_now(), -30 * 60, :second))

      entries = Metrics.cycle_time_daily(scope: scope)
      today = List.last(entries)

      assert today.agent_minutes == 120
      assert today.human_minutes == 30
    end

    test "returns 14 zero entries for an empty workspace" do
      scope = Scope.for_user(user_fixture())
      entries = Metrics.cycle_time_daily(scope: scope)
      assert length(entries) == 14
      assert Enum.all?(entries, &(&1.agent_minutes == 0 and &1.human_minutes == 0))
    end
  end

  describe "throughput_daily/1" do
    test "returns 14 integer counts ordered oldest-to-newest", %{} do
      %{column: column, scope: scope} = ws_setup()

      # 2 today, 1 three days ago
      Enum.each(1..2, fn _ -> column |> task_fixture() |> ws_complete!(0) end)
      column |> task_fixture() |> ws_complete!(3)

      counts = Metrics.throughput_daily(scope: scope)
      assert length(counts) == 14
      assert List.last(counts) == 2
      assert Enum.at(counts, length(counts) - 1 - 3) == 1
    end

    test "returns 14 zeros for an empty workspace" do
      counts = Metrics.throughput_daily(scope: Scope.for_user(user_fixture()))
      assert counts == List.duplicate(0, 14)
    end
  end

  describe "agent_leaderboard/1" do
    test "places agents before humans regardless of completed counts",
         %{} do
      %{column: column, scope: scope, user: user} = ws_setup()

      # 1 agent completion vs 5 human completions — agent must still
      # appear first because :agent contributors precede :human.
      agent_t = task_fixture(column, %{completed_by_agent: "Claude"})
      ws_complete!(agent_t, 1)

      Enum.each(1..5, fn _ ->
        t = task_fixture(column)
        ws_complete!(t, 1, %{completed_by_id: user.id})
      end)

      leaderboard = Metrics.agent_leaderboard(scope: scope)
      assert hd(leaderboard).kind == :agent
      assert hd(leaderboard).name == "Claude"
    end

    test "caps the leaderboard at 6 entries", %{} do
      %{column: column, scope: scope} = ws_setup()

      for i <- 1..10 do
        t = task_fixture(column, %{completed_by_agent: "Agent#{i}"})
        ws_complete!(t, 1)
      end

      leaderboard = Metrics.agent_leaderboard(scope: scope)
      assert length(leaderboard) == 6
    end

    test "computes success_pct from review_status / needs_review",
         %{} do
      %{column: column, scope: scope, user: user} = ws_setup()

      # 2 tasks for Claude: one approved (needs_review=true + :approved),
      # one no-review (needs_review=false) — both successful → 100%.
      t1 = task_fixture(column, %{completed_by_agent: "Claude", needs_review: true})
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      ws_complete!(t1, 1, %{
        review_status: :approved,
        reviewed_at: now,
        reviewed_by_id: user.id
      })

      t2 = task_fixture(column, %{completed_by_agent: "Claude", needs_review: false})
      ws_complete!(t2, 1)

      # 1 changes_requested task — failure → 66.66% across the 3-task set.
      t3 = task_fixture(column, %{completed_by_agent: "Claude", needs_review: true})

      ws_complete!(t3, 1, %{
        review_status: :changes_requested,
        reviewed_at: now,
        reviewed_by_id: user.id
      })

      [%{name: "Claude", success_pct: pct, completed: completed}] =
        Metrics.agent_leaderboard(scope: scope)

      assert completed == 3
      assert_in_delta pct, 66.66, 0.5
    end

    test "is empty when no completed tasks exist" do
      assert Metrics.agent_leaderboard(scope: Scope.for_user(user_fixture())) == []
    end
  end

  describe "cumulative_flow/1" do
    test "returns 14 snapshots with all five integer fields",
         %{} do
      %{scope: scope} = ws_setup()
      flow = Metrics.cumulative_flow(scope: scope)

      assert length(flow) == 14

      for snapshot <- flow do
        assert %Date{} = snapshot.date

        for k <- [:backlog, :ready, :doing, :review, :done] do
          assert is_integer(Map.fetch!(snapshot, k))
        end
      end
    end

    test "buckets tasks at the end-of-day cutoff", %{} do
      %{column: column, scope: scope} = ws_setup()

      # A task that's been in backlog forever (no claimed_at)
      _backlog = task_fixture(column)

      # A doing task (claimed yesterday, not completed)
      doing = task_fixture(column)
      yesterday = DateTime.add(DateTime.utc_now(), -86_400, :second)
      Tasks.update_task(doing, %{claimed_at: yesterday})

      # A done task (completed yesterday, no needs_review)
      done = task_fixture(column, %{needs_review: false})
      ws_complete!(done, 0)

      [today_snapshot] = scope |> then(&Metrics.cumulative_flow(scope: &1)) |> Enum.take(-1)

      assert today_snapshot.backlog >= 1
      assert today_snapshot.doing >= 1
      assert today_snapshot.done >= 1
      assert today_snapshot.ready == 0
    end

    test "returns 14 zero snapshots for an empty workspace" do
      flow = Metrics.cumulative_flow(scope: Scope.for_user(user_fixture()))
      assert length(flow) == 14

      for snapshot <- flow do
        assert snapshot.backlog == 0
        assert snapshot.ready == 0
        assert snapshot.doing == 0
        assert snapshot.review == 0
        assert snapshot.done == 0
      end
    end

    test "excludes archived tasks from every bucket", %{} do
      %{column: column, scope: scope} = ws_setup()

      archived = task_fixture(column)

      Tasks.update_task(archived, %{
        archived_at: DateTime.add(DateTime.utc_now(), -86_400, :second)
      })

      [today_snapshot] = scope |> then(&Metrics.cumulative_flow(scope: &1)) |> Enum.take(-1)

      # The archived task should not contribute to backlog (or any bucket).
      assert today_snapshot.backlog == 0
    end
  end

  describe "workspace reads — :window_days option" do
    test "with no :window_days every daily series keeps the 14-day default" do
      %{scope: scope} = ws_setup()

      assert length(Metrics.cycle_time_daily(scope: scope)) == 14
      assert length(Metrics.throughput_daily(scope: scope)) == 14
      assert length(Metrics.cumulative_flow(scope: scope)) == 14
    end

    test "a supported :window_days sets the daily series length" do
      %{scope: scope} = ws_setup()

      for w <- [7, 14, 30, 90] do
        assert length(Metrics.cycle_time_daily(scope: scope, window_days: w)) == w
        assert length(Metrics.throughput_daily(scope: scope, window_days: w)) == w
        assert length(Metrics.cumulative_flow(scope: scope, window_days: w)) == w
      end
    end

    test "an unsupported, nil, or absent :window_days clamps to 14" do
      %{scope: scope} = ws_setup()

      for bad <- [5, 1000, :foo, nil] do
        assert length(Metrics.cycle_time_daily(scope: scope, window_days: bad)) == 14
        assert length(Metrics.throughput_daily(scope: scope, window_days: bad)) == 14
        assert length(Metrics.cumulative_flow(scope: scope, window_days: bad)) == 14
      end

      # An out-of-range window yields exactly the default-window result.
      assert Metrics.cycle_time_daily(scope: scope, window_days: 5) ==
               Metrics.cycle_time_daily(scope: scope)
    end

    test "throughput_daily zero-path respects the resolved window" do
      scope = Scope.for_user(user_fixture())

      assert Metrics.throughput_daily(scope: scope, window_days: 7) == List.duplicate(0, 7)
      assert Metrics.throughput_daily(scope: scope, window_days: 5) == List.duplicate(0, 14)
    end

    test "the window bounds which completions are counted, not just the series length" do
      %{column: column, scope: scope} = ws_setup()

      # 2 completions inside every window, 1 completion only inside 30/90.
      Enum.each(1..2, fn _ -> column |> task_fixture() |> ws_complete!(1) end)
      column |> task_fixture() |> ws_complete!(20)

      within_7 = Metrics.throughput_daily(scope: scope, window_days: 7)
      within_default = Metrics.throughput_daily(scope: scope)
      within_30 = Metrics.throughput_daily(scope: scope, window_days: 30)

      assert Enum.sum(within_7) == 2
      assert Enum.sum(within_default) == 2
      assert Enum.sum(within_30) == 3
    end

    test "workspace_kpis throughput_per_day divides by the resolved window" do
      %{column: column, scope: scope} = ws_setup()

      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)

      assert_in_delta Metrics.workspace_kpis(scope: scope, window_days: 7).throughput_per_day,
                      3 / 7,
                      0.001

      assert_in_delta Metrics.workspace_kpis(scope: scope).throughput_per_day, 3 / 14, 0.001
    end

    test "workspace_kpis deltas use the matching previous window of the same length" do
      %{column: column, scope: scope} = ws_setup()

      # 3 completions a day ago, 1 completion ten days ago.
      Enum.each(1..3, fn _ -> column |> task_fixture() |> ws_complete!(1) end)
      column |> task_fixture() |> ws_complete!(10)

      # window 7: current = 3 (day-1), previous (days 7–14) = 1 (day-10) → +200%.
      assert_in_delta Metrics.workspace_kpis(scope: scope, window_days: 7).throughput_delta_pct,
                      200.0,
                      0.1

      # window 30: both completions fall inside the current window, previous is
      # empty → divide-by-zero guard collapses the delta to 0.0.
      assert Metrics.workspace_kpis(scope: scope, window_days: 30).throughput_delta_pct == 0.0
    end

    test "agent_leaderboard counts only completions inside the resolved window" do
      %{column: column, scope: scope} = ws_setup()

      column |> task_fixture(%{completed_by_agent: "Claude"}) |> ws_complete!(1)
      column |> task_fixture(%{completed_by_agent: "Claude"}) |> ws_complete!(20)

      assert [%{name: "Claude", completed: 1}] =
               Metrics.agent_leaderboard(scope: scope, window_days: 7)

      assert [%{name: "Claude", completed: 2}] =
               Metrics.agent_leaderboard(scope: scope, window_days: 30)
    end

    test "cumulative_flow returns one snapshot per day of the resolved window" do
      %{scope: scope} = ws_setup()

      flow = Metrics.cumulative_flow(scope: scope, window_days: 90)
      assert length(flow) == 90

      for snapshot <- flow do
        assert %Date{} = snapshot.date

        for k <- [:backlog, :ready, :doing, :review, :done] do
          assert is_integer(Map.fetch!(snapshot, k))
        end
      end
    end
  end
end
