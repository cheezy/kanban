defmodule Kanban.Workspaces.Export.ImporterTest do
  # async: false — points the process-wide :export_dir at a directory of its own.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.WorkspaceExportFixtures

  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.Importer
  alias Kanban.Workspaces.Export.Serializer
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Workspace

  setup do
    ctx = seed_workspace(export_org_fixture())
    dir = tmp_export_dir()
    ctx = Map.put(ctx, :dir, dir)
    path = export_archive(ctx)
    from(b in Board, where: b.workspace_id == ^ctx.workspace.id) |> Repo.delete_all()
    Map.put(ctx, :files, read_archive(path))
  end

  defp export_archive(ctx) do
    {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)
    %{success: 1} = Oban.drain_queue(queue: :workspace_exports)
    Repo.get!(WorkspaceExport, export.id).file_path
  end

  # Writes `files` (name => decoded JSON) as an archive whose manifest counts
  # match its rows, and imports it as the org-admin.
  defp import_files(ctx, files) do
    path = Path.join(ctx.dir, "crafted-#{System.unique_integer([:positive])}.zip")
    entries = files |> recount() |> Enum.map(&zip_entry/1)
    {:ok, _} = path |> String.to_charlist() |> :zip.create(entries)
    Importer.import_archive(path, ctx.org_admin.email)
  end

  defp recount(files) do
    counts =
      Map.new(Serializer.entities(), fn entity ->
        {Atom.to_string(entity), length(files[Serializer.file_name(entity)])}
      end)

    put_in(files, ["manifest.json", "counts"], counts)
  end

  defp zip_entry({name, data}), do: {String.to_charlist(name), Jason.encode!(data)}

  defp update_rows(files, entity, fun),
    do: Map.update!(files, Serializer.file_name(entity), &Enum.map(&1, fun))

  defp row(files, entity, id),
    do: Enum.find(files[Serializer.file_name(entity)], &(&1["id"] == id))

  # Sets `changes` on the task row exported from `task`.
  defp change_task(files, task, changes) do
    update_rows(files, :tasks, fn
      %{"id" => id} = row when id == task.id -> Map.merge(row, changes)
      row -> row
    end)
  end

  defp table_counts,
    do: Enum.map([Workspace, Board, Task, BoardUser], &Repo.aggregate(&1, :count))

  defp assert_refused(ctx, files, expected) do
    before = table_counts()
    assert {:error, {:invalid_row, _entity, _ref, _errors} = error} = import_files(ctx, files)
    assert expected.(error)
    assert table_counts() == before
  end

  describe "task hierarchy and identifiers" do
    test "a parent on another board is refused", ctx do
      files = change_task(ctx.files, ctx.beta_task, %{"parent_id" => ctx.goal.id})

      assert_refused(ctx, files, fn error ->
        error == {:invalid_row, :tasks, ctx.beta_task.identifier, :parent_on_another_board}
      end)
    end

    test "an archived duplicate of a task on another board is refused", ctx do
      files =
        change_task(ctx.files, ctx.beta_task, %{
          "archive_reason" => "duplicate",
          "archived_at" => "2026-01-01T00:00:00Z",
          "duplicate_of_id" => ctx.original.id
        })

      assert_refused(ctx, files, fn error ->
        error == {:invalid_row, :tasks, ctx.beta_task.identifier, :duplicate_on_another_board}
      end)
    end

    test "a task that is its own parent is refused", ctx do
      files = change_task(ctx.files, ctx.second, %{"parent_id" => ctx.second.id})

      assert_refused(ctx, files, fn error ->
        error == {:invalid_row, :tasks, ctx.second.identifier, :parent_is_itself}
      end)
    end

    test "a parent cycle is refused", ctx do
      files = change_task(ctx.files, ctx.goal, %{"parent_id" => ctx.first.id})

      assert_refused(ctx, files, fn {:invalid_row, :tasks, ref, reason} ->
        reason == :parent_cycle and ref in [ctx.goal.identifier, ctx.first.identifier]
      end)
    end

    test "two tasks with one identifier on one board are refused", ctx do
      files = change_task(ctx.files, ctx.second, %{"identifier" => ctx.first.identifier})

      assert_refused(ctx, files, fn error ->
        error == {:invalid_row, :tasks, ctx.first.identifier, :duplicate_identifier}
      end)
    end

    test "the same identifier on two boards is kept", ctx do
      files = change_task(ctx.files, ctx.beta_task, %{"identifier" => ctx.first.identifier})

      assert {:ok, %{counts: %{tasks: 6}}} = import_files(ctx, files)
    end

    test "a missing identifier or one with control or bidi characters is refused", ctx do
      row_number =
        Enum.find_index(ctx.files["tasks.json"], &(&1["id"] == ctx.second.id)) + 1

      for identifier <- [nil, "W\u202E9", "W9\n", "W9\u0000"] do
        files = change_task(ctx.files, ctx.second, %{"identifier" => identifier})

        assert_refused(ctx, files, fn error ->
          error == {:invalid_row, :tasks, "row #{row_number}", :invalid_identifier}
        end)
      end
    end
  end

  test "a clean archive still imports, history included", ctx do
    assert {:ok, report} = import_files(ctx, ctx.files)
    assert report.counts.tasks == 6
    assert report.reattributed == 0
    assert report.counts.task_history == length(ctx.files["task_history.json"])
    assert Repo.aggregate(TaskHistory, :count) >= report.counts.task_history
    assert row(ctx.files, :tasks, ctx.second.id)["identifier"] == ctx.second.identifier
  end
end
