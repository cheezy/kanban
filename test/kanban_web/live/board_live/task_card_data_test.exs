defmodule KanbanWeb.BoardLive.TaskCardDataTest do
  @moduledoc """
  Unit tests for the extracted task-card view-model builder (W1446). The board
  page renders these maps; the existing show_test.exs describe blocks exercise
  task_card_data through the LiveView, and these pin the pure computation
  directly, including the reviewer/meta/cycle-time fields and edge cases.
  """
  use ExUnit.Case, async: true

  alias Kanban.Tasks.Task
  alias KanbanWeb.BoardLive.TaskCardData

  describe "task_card_data/1 — review, meta, and cycle-time fields" do
    test "builds reviewer verdict, files-changed count, and cycle time for a completed task" do
      task = %Task{
        id: 1,
        type: :work,
        reviewer_result: %{
          "dispatched" => true,
          "issues_found" => 2,
          "acceptance_criteria_checked" => 4,
          "reason" => nil
        },
        actual_files_changed: "lib/a.ex, lib/b.ex, lib/c.ex",
        review_status: :approved,
        claimed_at: ~U[2026-01-01 10:00:00Z],
        completed_at: ~U[2026-01-01 12:30:00Z]
      }

      data = TaskCardData.task_card_data(task)

      assert data.reviewer_skipped? == false
      assert data.issues_found == 2
      assert data.criteria_checked == 4
      assert data.files_changed_count == 3
      assert data.review_status == :approved
      assert data.cycle_time == "2h 30m"
    end

    test "counts key_files, dependencies, and acceptance criteria lines" do
      task = %Task{
        id: 2,
        type: :work,
        key_files: [%{}, %{}],
        dependencies: ["W1"],
        acceptance_criteria: "one\ntwo\nthree"
      }

      data = TaskCardData.task_card_data(task)

      assert data.key_files_count == 2
      assert data.deps_count == 1
      assert data.acceptance_count == 3
    end

    test "reads a string-keyed reviewer skip reason and preserves the get_in_either quirk" do
      task = %Task{
        id: 3,
        type: :work,
        reviewer_result: %{"dispatched" => false, "reason" => "trivial"}
      }

      data = TaskCardData.task_card_data(task)

      assert data.reviewer_skip_reason == "trivial"
      # get_in_either/2 uses Enum.find_value, so a false-valued `dispatched`
      # is treated as "not found" (nil) — reviewer_skipped? stays false. This
      # mirrors the preserved show_test.exs behaviour (line 2509).
      assert data.reviewer_skipped? == false
    end

    test "builds a completed_by agent avatar" do
      data =
        TaskCardData.task_card_data(%Task{id: 4, type: :work, completed_by_agent: "Claude Opus"})

      assert %{kind: :agent, name: "Claude Opus"} = data.completed_by
    end
  end

  describe "task_card_data/1 — edge cases" do
    test "a task with no completion metadata has nil cycle time and no counts" do
      data = TaskCardData.task_card_data(%Task{id: 5, type: :work})

      assert data.cycle_time == nil
      assert data.files_changed_count == nil
      assert data.key_files_count == nil
      assert data.completed_by == nil
      assert data.reviewer_skipped? == false
    end
  end

  describe "task_card_data/4 — goal fields" do
    test "goal children come from goal_progress and promoted reflects the backlog set" do
      goal = %Task{id: 10, type: :goal}
      progress = %{10 => %{total: 4, completed: 2, percentage: 50}}

      not_promotable = TaskCardData.task_card_data(goal, MapSet.new(), progress, %{})
      assert not_promotable.children == %{total: 4, done: 2, review: 0, doing: 0, ready: 0}
      assert not_promotable.promoted == true

      in_backlog = TaskCardData.task_card_data(goal, MapSet.new([10]), progress, %{})
      assert in_backlog.promoted == false
    end

    test "a goal whose id is absent from goal_progress has nil children" do
      goal = %Task{id: 99, type: :goal}
      data = TaskCardData.task_card_data(goal, MapSet.new(), %{}, %{})
      assert data.children == nil
    end
  end

  describe "task_card_data — defensive branches" do
    test "a non-map reviewer_result yields no skip flag and nil verdict fields" do
      # Map.get(task, :reviewer_result) || %{} keeps a truthy non-map as-is, so
      # reviewer_skipped?/1 and get_in_either/2 hit their non-map fallbacks.
      data = TaskCardData.task_card_data(%Task{id: 1, type: :work, reviewer_result: "not a map"})

      assert data.reviewer_skipped? == false
      assert data.reviewer_skip_reason == nil
      assert data.criteria_checked == nil
    end

    test "a completed_at before claimed_at (negative duration) yields nil cycle time" do
      task = %Task{
        id: 2,
        type: :work,
        claimed_at: ~U[2026-01-01 12:00:00Z],
        completed_at: ~U[2026-01-01 10:00:00Z]
      }

      assert TaskCardData.task_card_data(task).cycle_time == nil
    end

    test "a non-binary completed_by_agent yields no avatar" do
      assert TaskCardData.task_card_data(%Task{id: 3, type: :work, completed_by_agent: 123}).completed_by ==
               nil
    end

    test "an assigned user with neither name nor email falls back to \"?\"" do
      data = TaskCardData.task_card_data(%Task{id: 4, type: :work, assigned_to: %{id: 7}})
      assert %{kind: :human, name: "?"} = data.claimed_by
    end
  end

  describe "task_card_data arities" do
    test "the /2 and /3 arities apply default goal_progress/goals_by_id" do
      task = %Task{id: 8, type: :work}
      assert %{promoted: true} = TaskCardData.task_card_data(task, MapSet.new())
      assert %{promoted: true} = TaskCardData.task_card_data(task, MapSet.new(), %{})
    end
  end
end
