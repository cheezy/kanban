defmodule Kanban.Workspaces.Export.CleanupWorkerTest do
  # Not async: tests point the process-wide :export_dir at their own directory.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
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

  @hour 3600

  # A directory named as Writer.create_tmp_dir/1 names one, in `dir`, last
  # changed `age` seconds ago.
  defp aged_tmp_dir!(dir, age) do
    name = ".tmp-" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
    path = Path.join(dir, name)

    File.mkdir_p!(path)
    path |> Path.join("tasks.json") |> File.write!("left behind")
    File.touch!(path, System.os_time(:second) - age)

    path
  end

  # The run's info line, which the test config's :warning level would drop.
  defp run_logged do
    Logger.put_module_level(CleanupWorker, :info)
    on_exit(fn -> Logger.delete_module_level(CleanupWorker) end)

    capture_log([level: :info], fn -> assert :ok = run() end)
  end

  defp put_cleanup_env(settings) do
    previous = Application.get_env(:kanban, CleanupWorker)
    Application.put_env(:kanban, CleanupWorker, settings)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kanban, CleanupWorker, previous),
        else: Application.delete_env(:kanban, CleanupWorker)
    end)
  end

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
    # Named as the writer names it, <export_id>.zip.
    fresh = export(ctx, status: "succeeded", expires_at: DateTime.add(now(), 3600))
    path = archive(ctx, "#{fresh.id}.zip")
    fresh = fresh |> Ecto.Changeset.change(file_path: path) |> Repo.update!()

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

  describe "unreferenced archives" do
    test "the archive of a job killed before it marked its export succeeded goes once the export times out",
         ctx do
      # The writer renamed the archive into place; the job died before
      # mark_succeeded, so the row is still running with no file_path.
      killed = export(ctx, status: "running")
      path = archive(ctx, "#{killed.id}.zip")

      assert :ok = run()
      assert File.exists?(path)

      assert :ok = run(DateTime.add(DateTime.utc_now(), 7, :hour))

      assert %WorkspaceExport{status: "failed", error: "timed_out"} =
               Repo.get!(WorkspaceExport, killed.id)

      refute File.exists?(path)
    end

    test "deletes an archive whose export is failed or gone, keeps pending, running and succeeded ones",
         ctx do
      failed = export(ctx, status: "failed", error: "export_failed")
      gone = archive(ctx, "#{failed.id + 1_000_000}.zip")
      failed_path = archive(ctx, "#{failed.id}.zip")

      succeeded = export(ctx, status: "succeeded", expires_at: DateTime.add(now(), 3600))
      succeeded_path = archive(ctx, "#{succeeded.id}.zip")
      # One export of a workspace is active at a time: running, then pending.
      active = export(ctx, status: "running")
      active_path = archive(ctx, "#{active.id}.zip")
      other = archive(ctx, "notes.txt")

      log = run_logged()

      refute File.exists?(gone)
      refute File.exists?(failed_path)
      assert File.exists?(succeeded_path)
      assert File.exists?(active_path)
      assert File.exists?(other)
      assert log =~ "2 unreferenced archives"
      refute log =~ ctx.export_dir

      active |> Ecto.Changeset.change(status: "pending") |> Repo.update!()

      assert run_logged() =~ "0 unreferenced archives"
      assert File.exists?(active_path)
    end

    test "never follows a symlink named like an archive", ctx do
      outside =
        Path.join(System.tmp_dir!(), "stride-archive-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      target = Path.join(outside, "target.zip")
      File.write!(target, "zip")

      link = Path.join([ctx.export_dir, "#{ctx.workspace.id}", "999998.zip"])
      link |> Path.dirname() |> File.mkdir_p!()
      File.ln_s!(target, link)

      assert run_logged() =~ "0 unreferenced archives"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
      assert File.exists?(target)
    end

    test "never reads archives through a workspace directory that is a symlink", ctx do
      outside =
        Path.join(System.tmp_dir!(), "stride-archive-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      planted = Path.join(outside, "999999.zip")
      File.write!(planted, "zip")

      File.mkdir_p!(ctx.export_dir)
      link = Path.join(ctx.export_dir, "#{ctx.workspace.id}")
      File.ln_s!(outside, link)

      assert run_logged() =~ "0 unreferenced archives"
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
      assert File.exists?(planted)
    end
  end

  describe "stale temporary directories" do
    test "an hourly run removes a stale .tmp- directory in the export directory, keeps a fresh one",
         ctx do
      stale = aged_tmp_dir!(ctx.export_dir, 7 * @hour + 60)
      # Who Else Is Watching: an export still running on another machine that
      # shares the export directory, and one past the timeout but inside the
      # hour that covers clocks that disagree.
      running_elsewhere = aged_tmp_dir!(ctx.export_dir, 5 * @hour)
      within_margin = aged_tmp_dir!(ctx.export_dir, 6 * @hour + 60)
      live = archive(ctx, "live.zip")

      outside =
        Path.join(System.tmp_dir!(), "stride-sweep-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      target = aged_tmp_dir!(outside, 7 * @hour)
      link = Path.join(ctx.export_dir, Path.basename(aged_tmp_dir!(outside, 7 * @hour)))
      File.ln_s!(target, link)

      log = run_logged()

      refute File.exists?(stale)
      assert File.dir?(running_elsewhere)
      assert File.dir?(within_margin)
      assert File.exists?(live)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
      assert target |> Path.join("tasks.json") |> File.regular?()

      assert log =~ "removed, 1 stale temporary directories"
      refute log =~ ctx.export_dir
      refute log =~ outside
    end

    test "an export directory that does not exist sweeps nothing", ctx do
      refute File.exists?(ctx.export_dir)

      assert run_logged() =~ "0 removed, 0 stale temporary directories"
    end

    test "a directory the operating system refuses to remove is logged without a path and not counted",
         ctx do
      stale = aged_tmp_dir!(ctx.export_dir, 8 * @hour)
      File.chmod!(ctx.export_dir, 0o500)
      on_exit(fn -> File.chmod(ctx.export_dir, 0o700) end)

      log = run_logged()

      assert File.dir?(stale)
      assert log =~ "workspace export: a temporary directory could not be removed: :eacces"
      assert log =~ "0 stale temporary directories"
      refute log =~ ctx.export_dir
    end

    test "an export directory that others can write to is not swept", ctx do
      stale = aged_tmp_dir!(ctx.export_dir, 7 * @hour)
      File.chmod!(ctx.export_dir, 0o777)

      log = run_logged()

      assert File.dir?(stale)

      assert log =~
               "workspace export: the temporary directory root is not an owner-only directory"

      assert log =~ "0 stale temporary directories"
      refute log =~ ctx.export_dir
    end

    test "with no export directory configured, sweeps stride_exports and never the system temporary directory",
         ctx do
      # Developer Guidebook: EXPORT_DIR unset. TMPDIR points at a directory of
      # this test's own, so the real system temporary directory is untouched.
      tmp = Path.join(ctx.export_dir, "system-tmp")
      File.mkdir_p!(tmp)
      saved = System.get_env("TMPDIR")
      System.put_env("TMPDIR", tmp)
      Application.delete_env(:kanban, :export_dir)

      on_exit(fn ->
        if saved, do: System.put_env("TMPDIR", saved), else: System.delete_env("TMPDIR")
      end)

      in_tmp = aged_tmp_dir!(tmp, 8 * @hour)
      in_default = aged_tmp_dir!(Path.join(tmp, "stride_exports"), 8 * @hour)

      assert run_logged() =~ "1 stale temporary directories"
      assert File.dir?(in_tmp)
      refute File.exists?(in_default)
    end

    test "the threshold is an hour past :stale_after_hours, and an unusable one falls back to six hours",
         ctx do
      put_cleanup_env(stale_after_hours: 8)
      kept = aged_tmp_dir!(ctx.export_dir, 8 * @hour + 60)
      removed = aged_tmp_dir!(ctx.export_dir, 9 * @hour + 60)

      assert run_logged() =~ "1 stale temporary directories"
      assert File.dir?(kept)
      refute File.exists?(removed)

      put_cleanup_env(stale_after_hours: 0)
      younger = aged_tmp_dir!(ctx.export_dir, 6 * @hour + 60)

      assert run_logged() =~ "1 stale temporary directories"
      assert File.dir?(younger)
      refute File.exists?(kept)
    end
  end
end
