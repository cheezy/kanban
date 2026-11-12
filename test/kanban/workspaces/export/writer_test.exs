defmodule Kanban.Workspaces.Export.WriterTest do
  # async: false - tmp_export_dir/0 points the global :export_dir at its own
  # directory.
  use Kanban.DataCase, async: false

  import Kanban.AttachmentHookStorage, only: [use_hook_storage: 0]
  import Kanban.AttachmentsFixtures
  import Kanban.WorkspaceExportFixtures

  alias Kanban.Workspaces.Export.Writer

  setup do
    Map.put(export_org_fixture(), :export_dir, tmp_export_dir())
  end

  defp tmp_entries(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.filter(names, &String.starts_with?(&1, ".tmp-"))
      {:error, :enoent} -> []
    end
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # Waits for the export directory to hold no scratch directory: the guard
  # removes it from its own process, after the owner's :DOWN arrives.
  defp eventually_no_tmp_entries(dir, tries \\ 100)
  defp eventually_no_tmp_entries(dir, 0), do: tmp_entries(dir)

  defp eventually_no_tmp_entries(dir, tries) do
    case tmp_entries(dir) do
      [] ->
        []

      _left ->
        Process.sleep(20)
        eventually_no_tmp_entries(dir, tries - 1)
    end
  end

  describe "create_tmp_dir/1" do
    test "creates a different owner-only directory with a random name each time", ctx do
      File.mkdir_p!(ctx.export_dir)

      assert {:ok, first} = Writer.create_tmp_dir(ctx.export_dir)
      assert {:ok, second} = Writer.create_tmp_dir(ctx.export_dir)

      assert first != second
      assert Path.dirname(first) == ctx.export_dir

      for path <- [first, second] do
        assert File.dir?(path)
        assert mode(path) == 0o700
        assert Path.basename(path) =~ ~r/\A\.tmp-[A-Za-z0-9_-]{22}\z/
      end
    end
  end

  describe "mkdir_exclusive/1" do
    test "refuses a path that already exists instead of reusing it", ctx do
      path = Path.join(ctx.export_dir, ".tmp-planted")
      File.mkdir_p!(path)
      File.chmod!(path, 0o755)

      assert {:error, :eexist} = Writer.mkdir_exclusive(path)
      assert mode(path) == 0o755
    end

    test "refuses a planted symlink and leaves its target alone", ctx do
      File.mkdir_p!(ctx.export_dir)
      target = Path.join(ctx.export_dir, "elsewhere")
      File.mkdir_p!(target)
      link = Path.join(ctx.export_dir, ".tmp-link")
      File.ln_s!(target, link)

      assert {:error, :eexist} = Writer.mkdir_exclusive(link)
      assert File.ls!(target) == []
    end
  end

  describe "write_archive/3" do
    test "two writes for the same workspace both succeed and leave no scratch directory",
         ctx do
      assert {:ok, %{path: first}} = Writer.write_archive(ctx.workspace, 1, ctx.export_dir)
      assert {:ok, %{path: second}} = Writer.write_archive(ctx.workspace, 2, ctx.export_dir)

      assert first != second
      assert File.regular?(first) and File.regular?(second)
      assert mode(first) == 0o600
      assert mode(Path.dirname(first)) == 0o700
      assert tmp_entries(ctx.export_dir) == []
    end

    test "removes the scratch directory when the write fails", ctx do
      # A file where the workspace's archive directory should go.
      File.mkdir_p!(ctx.export_dir)
      ctx.export_dir |> Path.join(Integer.to_string(ctx.workspace.id)) |> File.write!("")

      assert {:error, :storage_unavailable} =
               Writer.write_archive(ctx.workspace, 3, ctx.export_dir)

      assert tmp_entries(ctx.export_dir) == []
    end

    test "a process killed while it holds a write_archive scratch directory leaves no directory behind",
         ctx do
      use_hook_storage()
      ctx = seed_workspace(ctx)

      stored_attachment_fixture(ctx.first, "held", %{
        filename: "a.txt",
        content_type: "text/plain"
      })

      test_pid = self()

      # The blob copy runs after the snapshot transaction has ended, with the
      # entity files already in the scratch directory; the writer stops there.
      writer =
        spawn(fn ->
          Process.put(:on_stream, fn _key ->
            send(test_pid, :copying)
            Process.sleep(:infinity)
          end)

          Writer.write_archive(ctx.workspace, 5, ctx.export_dir)
        end)

      assert_receive :copying, 5_000
      assert [_one] = tmp_entries(ctx.export_dir)

      Process.exit(writer, :kill)

      assert eventually_no_tmp_entries(ctx.export_dir) == []
    end

    test "returns :export_failed and leaves nothing when the guard cannot start", ctx do
      supervisor = start_supervised!({Task.Supervisor, max_children: 0})

      assert {:error, :export_failed} =
               Writer.write_archive(ctx.workspace, 4, ctx.export_dir, supervisor: supervisor)

      assert tmp_entries(ctx.export_dir) == []
    end
  end
end
