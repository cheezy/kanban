defmodule Kanban.Workspaces.Export.CleanupWorkerTest do
  # Not async: tests point the process-wide :export_dir at their own directory.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.WorkspaceExportFixtures

  alias Kanban.Workspaces.Export.CleanupWorker
  alias Kanban.Workspaces.Export.WorkspaceExport

  setup do
    Map.put(export_org_fixture(), :export_dir, tmp_export_dir())
  end

  defp export(ctx, attrs) do
    {:ok, export} =
      ctx.workspace.id
      |> WorkspaceExport.create_changeset(ctx.org_admin.id)
      |> Repo.insert()

    export |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp archive(ctx, name) do
    path = Path.join([ctx.export_dir, "#{ctx.workspace.id}", name])
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "zip")
    path
  end

  defp now, do: DateTime.utc_now(:second)

  defp run(at \\ DateTime.utc_now()),
    do: perform_job(CleanupWorker, %{"now" => DateTime.to_iso8601(at)})

  test "deletes an expired archive and marks the export expired", ctx do
    path = archive(ctx, "1.zip")

    expired =
      export(ctx, status: "succeeded", file_path: path, expires_at: DateTime.add(now(), -60))

    assert :ok = run()

    refute File.exists?(path)

    assert %WorkspaceExport{status: "expired", file_path: nil} =
             Repo.get!(WorkspaceExport, expired.id)
  end

  test "leaves an unexpired archive alone", ctx do
    path = archive(ctx, "2.zip")

    fresh =
      export(ctx, status: "succeeded", file_path: path, expires_at: DateTime.add(now(), 3600))

    assert :ok = run()

    assert File.exists?(path)
    assert Repo.get!(WorkspaceExport, fresh.id).status == "succeeded"
  end

  test "keeps a succeeded export whose archive this machine cannot see until it expires", ctx do
    # With more than one machine the archive may live on another one, so a
    # missing file is never taken as gone.
    elsewhere =
      export(ctx,
        status: "succeeded",
        file_path: Path.join(ctx.export_dir, "missing.zip"),
        expires_at: DateTime.add(now(), 3600)
      )

    assert :ok = run()
    assert Repo.get!(WorkspaceExport, elsewhere.id).status == "succeeded"

    assert :ok = run(DateTime.add(DateTime.utc_now(), 2, :hour))
    assert Repo.get!(WorkspaceExport, elsewhere.id).status == "expired"
  end

  test "deletes the archive directory of a workspace that no longer exists", ctx do
    live = archive(ctx, "live.zip")
    orphan = Path.join([ctx.export_dir, "#{ctx.workspace.id + 100_000}", "gone.zip"])
    orphan |> Path.dirname() |> File.mkdir_p!()
    File.write!(orphan, "zip")
    stray = Path.join(ctx.export_dir, "not-a-workspace")
    File.mkdir_p!(stray)

    assert :ok = run()

    refute orphan |> Path.dirname() |> File.exists?()
    assert File.exists?(live)
    assert File.dir?(stray)
  end

  test "fails a stale pending or running export with timed_out", ctx do
    stale = export(ctx, status: "running")

    assert :ok = run(DateTime.add(DateTime.utc_now(), 7, :hour))

    assert %WorkspaceExport{status: "failed", error: "timed_out"} =
             Repo.get!(WorkspaceExport, stale.id)
  end

  test "keeps a recent running export", ctx do
    running = export(ctx, status: "running")
    assert :ok = run()
    assert Repo.get!(WorkspaceExport, running.id).status == "running"
  end

  test "deletes failed and expired rows after the keep period", ctx do
    old = export(ctx, status: "failed", error: "export_failed")
    assert :ok = run(DateTime.add(DateTime.utc_now(), 31, :day))
    refute Repo.get(WorkspaceExport, old.id)
  end

  test "never deletes a file outside the export directory", ctx do
    outside = Path.join(System.tmp_dir!(), "keep-me-#{System.unique_integer([:positive])}.zip")
    File.write!(outside, "keep")
    on_exit(fn -> File.rm(outside) end)

    export(ctx, status: "succeeded", file_path: outside, expires_at: DateTime.add(now(), -60))

    assert :ok = run()
    assert File.exists?(outside)
  end
end
