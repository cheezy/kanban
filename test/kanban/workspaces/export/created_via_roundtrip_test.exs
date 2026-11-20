defmodule Kanban.Workspaces.Export.CreatedViaRoundtripTest do
  @moduledoc """
  A task's `created_via` (W2760) through a workspace export and import: the
  export writes it, the import keeps it, and an archive written before it was
  exported imports its tasks with none.
  """
  # async: false — points the process-wide :export_dir at a directory of its own.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.WorkspaceExportFixtures

  alias Kanban.Boards.Board
  alias Kanban.Tasks.Task
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.Importer
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Workspace

  setup do
    ctx = seed_workspace(export_org_fixture())

    {1, _} =
      from(t in Task, where: t.id == ^ctx.first.id)
      |> Repo.update_all(set: [created_via: :mobile])

    dir = tmp_export_dir()
    path = export_archive(ctx)
    files = raw_archive(path)

    # The import makes a new workspace; the source boards go, so the imported
    # tasks are the only ones with their identifiers.
    from(b in Board, where: b.workspace_id == ^ctx.workspace.id) |> Repo.delete_all()

    Map.merge(ctx, %{dir: dir, path: path, files: files})
  end

  defp export_archive(ctx) do
    {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)
    %{success: 1} = Oban.drain_queue(queue: :workspace_exports)
    Repo.get!(WorkspaceExport, export.id).file_path
  end

  defp task_rows(files), do: Jason.decode!(files["tasks.json"])

  defp with_task_rows(files, fun),
    do: Map.put(files, "tasks.json", files |> task_rows() |> Enum.map(fun) |> Jason.encode!())

  # The seeded titles are unique, so a title names one imported task.
  defp imported(ctx, %Task{title: title}) do
    board_ids = org_board_ids(ctx.organization.id)

    from(t in Task,
      join: c in assoc(t, :column),
      where: c.board_id in subquery(board_ids) and t.title == ^title
    )
    |> Repo.one!()
  end

  defp org_board_ids(organization_id) do
    from(b in Board,
      join: w in Workspace,
      on: w.id == b.workspace_id,
      where: w.organization_id == ^organization_id,
      select: b.id
    )
  end

  test "the export writes created_via on every task row", ctx do
    rows = ctx.files |> task_rows() |> Map.new(&{&1["id"], &1})

    assert rows[ctx.first.id]["created_via"] == "mobile"
    assert Map.has_key?(rows[ctx.second.id], "created_via")
    assert rows[ctx.second.id]["created_via"] == nil
    assert rows[ctx.goal.id]["created_via"] == nil
  end

  test "an import keeps created_via", ctx do
    assert {:ok, %{counts: %{tasks: 6}}} = Importer.import_archive(ctx.path, ctx.org_admin.email)

    assert imported(ctx, ctx.first).created_via == :mobile
    assert imported(ctx, ctx.second).created_via == nil
    assert imported(ctx, ctx.goal).created_via == nil
  end

  test "an archive written before created_via was exported imports with none", ctx do
    old = with_task_rows(ctx.files, &Map.delete(&1, "created_via"))
    refute old |> task_rows() |> Enum.any?(&Map.has_key?(&1, "created_via"))

    assert {:ok, %{counts: %{tasks: 6}}} =
             ctx.dir |> write_raw_archive(old) |> Importer.import_archive(ctx.org_admin.email)

    assert imported(ctx, ctx.first).created_via == nil
  end

  test "a created_via the task schema does not know refuses the import", ctx do
    crafted =
      with_task_rows(ctx.files, fn
        %{"id" => id} = row when id == ctx.first.id -> Map.put(row, "created_via", "fax")
        row -> row
      end)

    before = Repo.aggregate(Task, :count)

    assert {:error, {:invalid_row, :tasks, _ref, %{created_via: ["is invalid"]}}} =
             ctx.dir |> write_raw_archive(crafted) |> Importer.import_archive(ctx.org_admin.email)

    assert Repo.aggregate(Task, :count) == before
  end
end
