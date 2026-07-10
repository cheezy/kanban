defmodule Kanban.Tasks.ChangedFilesAuditTest do
  use ExUnit.Case, async: true

  alias Kanban.Tasks.ChangedFilesAudit
  alias Kanban.Tasks.Task

  describe "diff_missing?/1" do
    test "true when files were changed but changed_files is empty" do
      assert ChangedFilesAudit.diff_missing?(%Task{
               actual_files_changed: "lib/foo.ex",
               changed_files: []
             })

      assert ChangedFilesAudit.diff_missing?(%Task{
               actual_files_changed: "lib/a.ex, lib/b.ex",
               changed_files: nil
             })
    end

    test "false for a genuine no-op change (both empty)" do
      refute ChangedFilesAudit.diff_missing?(%Task{actual_files_changed: "", changed_files: []})
      refute ChangedFilesAudit.diff_missing?(%Task{actual_files_changed: nil, changed_files: []})

      refute ChangedFilesAudit.diff_missing?(%Task{
               actual_files_changed: "   ",
               changed_files: []
             })
    end

    test "false when a diff was uploaded" do
      refute ChangedFilesAudit.diff_missing?(%Task{
               actual_files_changed: "lib/foo.ex",
               changed_files: [%{"path" => "lib/foo.ex", "diff" => "patch"}]
             })
    end
  end

  describe "audit_review_bound_task/2" do
    test "emits telemetry and returns the task unchanged when the diff is missing" do
      test_pid = self()

      :telemetry.attach(
        "test-cfa-missing",
        [:kanban, :task, :changed_files_missing],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      task = %Task{
        id: 7,
        identifier: "D999",
        actual_files_changed: "lib/foo.ex",
        changed_files: []
      }

      assert ChangedFilesAudit.audit_review_bound_task(task, 55) == task

      assert_received {:telemetry, %{count: 1}, %{task_id: 7, identifier: "D999", board_id: 55}}

      :telemetry.detach("test-cfa-missing")
    end

    test "does not emit telemetry for a no-op change (both empty)" do
      test_pid = self()

      :telemetry.attach(
        "test-cfa-noop",
        [:kanban, :task, :changed_files_missing],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      task = %Task{id: 8, identifier: "W888", actual_files_changed: nil, changed_files: []}
      assert ChangedFilesAudit.audit_review_bound_task(task, 55) == task
      refute_received {:telemetry, _measurements, _metadata}

      :telemetry.detach("test-cfa-noop")
    end

    test "does not emit telemetry when a diff is present" do
      test_pid = self()

      :telemetry.attach(
        "test-cfa-present",
        [:kanban, :task, :changed_files_missing],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      task = %Task{
        id: 9,
        identifier: "D111",
        actual_files_changed: "lib/foo.ex",
        changed_files: [%{"path" => "lib/foo.ex", "diff" => "patch"}]
      }

      assert ChangedFilesAudit.audit_review_bound_task(task, 55) == task
      refute_received {:telemetry, _measurements, _metadata}

      :telemetry.detach("test-cfa-present")
    end
  end
end
