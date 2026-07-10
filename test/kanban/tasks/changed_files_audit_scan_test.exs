defmodule Kanban.Tasks.ChangedFilesAuditScanTest do
  @moduledoc """
  DB-backed tests for `ChangedFilesAudit.scan_missing_diffs/0` — the standing
  sweep + alert over review tasks missing their diff (W1660).
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Tasks
  alias Kanban.Tasks.ChangedFilesAudit

  setup do
    user = user_fixture()
    board = board_fixture(user)
    review = column_fixture(board, %{name: "Review", position: 1})
    doing = column_fixture(board, %{name: "Doing", position: 2})

    ref = attach_missing_diff_telemetry()

    %{board: board, review: review, doing: doing, ref: ref}
  end

  defp attach_missing_diff_telemetry do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      "scan-missing-#{inspect(ref)}",
      [:kanban, :task, :changed_files_missing],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("scan-missing-#{inspect(ref)}") end)
    ref
  end

  defp task_in(column, attrs) do
    {:ok, task} = column |> task_fixture() |> Tasks.update_task(attrs)
    task
  end

  test "returns and alerts on a review task whose diff is missing", %{
    review: review,
    board: board,
    ref: ref
  } do
    task =
      task_in(review, %{
        identifier: "D110",
        actual_files_changed: "lib/a.ex",
        changed_files: []
      })

    assert [%{id: id}] = ChangedFilesAudit.scan_missing_diffs()
    assert id == task.id

    assert_received {:telemetry, ^ref, %{count: 1},
                     %{task_id: ^id, identifier: "D110", board_id: board_id}}

    assert board_id == board.id
  end

  test "ignores a review task that already has a diff", %{review: review, ref: ref} do
    task_in(review, %{
      actual_files_changed: "lib/a.ex",
      changed_files: [%{"path" => "lib/a.ex", "diff" => "+ x"}]
    })

    assert ChangedFilesAudit.scan_missing_diffs() == []
    refute_received {:telemetry, ^ref, _measurements, _metadata}
  end

  test "ignores a diff-missing task that is not in the Review column", %{doing: doing, ref: ref} do
    task_in(doing, %{actual_files_changed: "lib/a.ex", changed_files: []})

    assert ChangedFilesAudit.scan_missing_diffs() == []
    refute_received {:telemetry, ^ref, _measurements, _metadata}
  end

  test "ignores a genuine no-op review task (nothing changed)", %{review: review, ref: ref} do
    task_in(review, %{actual_files_changed: "", changed_files: []})

    assert ChangedFilesAudit.scan_missing_diffs() == []
    refute_received {:telemetry, ^ref, _measurements, _metadata}
  end
end
