defmodule Kanban.ArchivesTest do
  @moduledoc """
  Tests for `Kanban.Archives` — the read API for the workspace Archive
  view. Covers `list_archived/1` (ordering, preloads, :reason and :scope
  filtering, the legacy nil-reason-treated-as-completed rule) and
  `archive_stats/1` (per-bucket counters and avg_cycle_minutes).
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Archives
  alias Kanban.Tasks

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, board: board, column: column}
  end

  defp archived_task!(column, attrs) do
    base = %{archived_at: DateTime.utc_now() |> DateTime.truncate(:second)}

    # :wontdo / :deferred / :cancelled reasons require an archive_note
    # at the changeset layer. Fill one in when callers don't, so the
    # tests stay focused on Archives behavior, not Task validation.
    attrs_with_note =
      case Map.get(attrs, :archive_reason) do
        reason when reason in [:wontdo, :deferred, :cancelled] ->
          Map.put_new(attrs, :archive_note, "Default test note for #{reason}")

        _ ->
          attrs
      end

    {:ok, task} =
      column
      |> task_fixture()
      |> Tasks.update_task(Map.merge(base, attrs_with_note))

    task
  end

  describe "list_archived/1 — base behaviour" do
    test "returns an empty list when no tasks are archived" do
      assert Archives.list_archived() == []
    end

    test "excludes non-archived tasks", %{column: column} do
      _live = task_fixture(column)
      assert Archives.list_archived() == []
    end

    test "returns archived tasks newest-first by archived_at",
         %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      older = archived_task!(column, %{archived_at: DateTime.add(now, -3600, :second)})
      newer = archived_task!(column, %{archived_at: now})

      ids = Archives.list_archived() |> Enum.map(& &1.id)
      assert ids == [newer.id, older.id]
    end

    test "preloads :column and :archived_by", %{column: column, user: user} do
      archived_task!(column, %{archive_reason: :completed, archived_by_id: user.id})

      [task] = Archives.list_archived()
      assert %Kanban.Columns.Column{} = task.column
      assert %Kanban.Accounts.User{id: id} = task.archived_by
      assert id == user.id
    end
  end

  describe "list_archived/1 — :reason filter" do
    test "filters to a specific reason", %{column: column} do
      archived_task!(column, %{archive_reason: :completed})
      keeper = archived_task!(column, %{archive_reason: :cancelled})

      ids = Archives.list_archived(reason: :cancelled) |> Enum.map(& &1.id)
      assert ids == [keeper.id]
    end

    test "reason :completed includes legacy rows with nil archive_reason",
         %{column: column} do
      explicit = archived_task!(column, %{archive_reason: :completed})
      legacy = archived_task!(column, %{archive_reason: nil})
      _other = archived_task!(column, %{archive_reason: :cancelled})

      ids = Archives.list_archived(reason: :completed) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([explicit.id, legacy.id])
    end

    test "reason nil returns every reason including legacy", %{column: column} do
      archived_task!(column, %{archive_reason: :completed})
      archived_task!(column, %{archive_reason: nil})
      archived_task!(column, %{archive_reason: :cancelled})

      assert length(Archives.list_archived()) == 3
      assert length(Archives.list_archived(reason: nil)) == 3
    end
  end

  describe "list_archived/1 — :scope filter" do
    test "excludes tasks on boards the scoped user cannot access",
         %{column: column} do
      archived_task!(column, %{archive_reason: :completed})

      other_user = user_fixture()
      other_scope = Scope.for_user(other_user)

      assert Archives.list_archived(scope: other_scope) == []
    end

    test "includes tasks on boards the scoped user owns",
         %{column: column, user: user} do
      archived_task!(column, %{archive_reason: :completed})
      scope = Scope.for_user(user)

      assert [_one] = Archives.list_archived(scope: scope)
    end

    test "scope: nil returns everything", %{column: column} do
      archived_task!(column, %{archive_reason: :completed})
      assert [_one] = Archives.list_archived(scope: nil)
    end
  end

  describe "list_archived_for_board/1" do
    test "returns only archived tasks on the given board",
         %{column: column, user: user} do
      _own = archived_task!(column, %{archive_reason: :completed})

      other = board_fixture(user_fixture())
      other_column = column_fixture(other)
      _foreign = archived_task!(other_column, %{archive_reason: :completed})

      ids = column.board_id |> Kanban.Archives.list_archived_for_board() |> Enum.map(& &1.id)
      assert length(ids) == 1
      assert _user = user
    end

    test "orders results newest-first by archived_at", %{column: column} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      older = archived_task!(column, %{archived_at: DateTime.add(now, -3600, :second)})
      newer = archived_task!(column, %{archived_at: now})

      ids = column.board_id |> Kanban.Archives.list_archived_for_board() |> Enum.map(& &1.id)
      assert ids == [newer.id, older.id]
    end

    test "preloads :column, :assigned_to, :archived_by, :duplicate_of, :parent",
         %{column: column, user: user} do
      canonical = task_fixture(column)

      archived_task!(column, %{
        archive_reason: :duplicate,
        duplicate_of_id: canonical.id,
        archived_by_id: user.id,
        assigned_to_id: user.id
      })

      [task] = Kanban.Archives.list_archived_for_board(column.board_id)
      assert %Kanban.Columns.Column{} = task.column
      assert %Kanban.Accounts.User{id: _} = task.archived_by
      assert %Kanban.Accounts.User{id: _} = task.assigned_to
      assert %Kanban.Tasks.Task{id: canonical_id} = task.duplicate_of
      assert canonical_id == canonical.id
      # :parent is loaded but nil here (no parent goal); the assoc should
      # NOT be %Ecto.Association.NotLoaded{}.
      refute match?(%Ecto.Association.NotLoaded{}, task.parent)
    end
  end

  describe "archive_stats_for_board/1" do
    test "returns the same bucket shape as archive_stats/1 but scoped to one board",
         %{column: column} do
      archived_task!(column, %{archive_reason: :completed})
      archived_task!(column, %{archive_reason: :cancelled})

      other = board_fixture(user_fixture())
      other_column = column_fixture(other)
      archived_task!(other_column, %{archive_reason: :completed})

      stats = Kanban.Archives.archive_stats_for_board(column.board_id)

      assert stats.total == 2
      assert stats.completed == 1
      assert stats.cancelled == 1
    end

    test "returns the zero map for a board with no archived tasks",
         %{column: column} do
      assert Kanban.Archives.archive_stats_for_board(column.board_id) == %{
               total: 0,
               completed: 0,
               cancelled: 0,
               wontdo_duplicate: 0,
               deferred: 0,
               avg_cycle_minutes: nil
             }
    end
  end

  describe "archive_stats/1" do
    test "returns zeros for an empty archive" do
      assert Archives.archive_stats() == %{
               total: 0,
               completed: 0,
               cancelled: 0,
               wontdo_duplicate: 0,
               deferred: 0,
               avg_cycle_minutes: nil
             }
    end

    test "counts the total across every archived task regardless of reason",
         %{column: column} do
      archived_task!(column, %{archive_reason: :completed})
      archived_task!(column, %{archive_reason: :cancelled})
      archived_task!(column, %{archive_reason: nil})

      assert Archives.archive_stats().total == 3
    end

    test "buckets :completed including legacy nil-reason rows", %{column: column} do
      archived_task!(column, %{archive_reason: :completed})
      archived_task!(column, %{archive_reason: nil})
      archived_task!(column, %{archive_reason: :cancelled})

      assert Archives.archive_stats().completed == 2
    end

    test "buckets :wontdo and :duplicate together", %{column: column} do
      archived_task!(column, %{archive_reason: :wontdo, archive_note: "skip"})

      canonical = task_fixture(column)

      archived_task!(column, %{
        archive_reason: :duplicate,
        duplicate_of_id: canonical.id
      })

      assert Archives.archive_stats().wontdo_duplicate == 2
    end

    test "buckets :deferred and :cancelled separately", %{column: column} do
      archived_task!(column, %{archive_reason: :deferred, archive_note: "later"})
      archived_task!(column, %{archive_reason: :cancelled, archive_note: "nope"})

      stats = Archives.archive_stats()
      assert stats.deferred == 1
      assert stats.cancelled == 1
    end

    test "avg_cycle_minutes averages non-nil time_spent_minutes only",
         %{column: column} do
      archived_task!(column, %{archive_reason: :completed, time_spent_minutes: 30})
      archived_task!(column, %{archive_reason: :completed, time_spent_minutes: 60})
      archived_task!(column, %{archive_reason: :completed, time_spent_minutes: nil})

      assert Archives.archive_stats().avg_cycle_minutes == 45
    end

    test "is scope-aware", %{column: column} do
      archived_task!(column, %{archive_reason: :completed})

      other_scope = Scope.for_user(user_fixture())

      assert Archives.archive_stats(scope: other_scope) == %{
               total: 0,
               completed: 0,
               cancelled: 0,
               wontdo_duplicate: 0,
               deferred: 0,
               avg_cycle_minutes: nil
             }
    end
  end
end
