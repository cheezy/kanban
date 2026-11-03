defmodule Kanban.Workspaces.Export.AttachmentsRoundtripTest do
  # async: false — points the process-wide :export_dir, the storage adapter
  # and the attachment limits at values of its own.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AttachmentHookStorage, only: [use_hook_storage: 0]
  import Kanban.AttachmentsFixtures
  import Kanban.WorkspaceExportFixtures

  alias Kanban.Attachments.BlobDeletion
  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.Storage
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Attachments.Usage
  alias Kanban.Boards.Board
  alias Kanban.Columns.Column
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.AttachmentBlobs
  alias Kanban.Workspaces.Export.Importer
  alias Kanban.Workspaces.Export.Importer.Attachments
  alias Kanban.Workspaces.Export.Serializer
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Workspace

  @text "Release notes for the importer.\n"

  setup do
    ctx = seed_workspace(export_org_fixture())
    comment = from(c in TaskComment, where: c.task_id == ^ctx.first.id) |> Repo.one!()

    notes =
      stored_attachment_fixture(ctx.first, @text, %{
        filename: "notes.txt",
        content_type: "text/plain",
        uploaded_by: ctx.member
      })

    shot =
      stored_attachment_fixture(ctx.first, tiny_png(), %{
        filename: "screenshot.png",
        content_type: "image/png",
        comment: comment,
        uploaded_by: ctx.member
      })

    Map.merge(ctx, %{dir: tmp_export_dir(), comment: comment, notes: notes, shot: shot})
  end

  defp export_archive(ctx) do
    {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)
    Oban.drain_queue(queue: :workspace_exports)
    Repo.get!(WorkspaceExport, export.id)
  end

  defp archive_path(ctx) do
    %WorkspaceExport{status: "succeeded", file_path: path} = export_archive(ctx)
    path
  end

  defp zip_names(path) do
    {:ok, [_comment | entries]} = path |> String.to_charlist() |> :zip.list_dir()
    for {:zip_file, name, _info, _comment, _offset, _size} <- entries, do: List.to_string(name)
  end

  defp put_env(module, settings) do
    previous = Application.get_env(:kanban, module)
    Application.put_env(:kanban, module, settings)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kanban, module, previous),
        else: Application.delete_env(:kanban, module)
    end)
  end

  defp imported_attachments(workspace_name) do
    workspace = Repo.get_by!(Workspace, name: workspace_name)

    from(a in TaskAttachment,
      join: t in Task,
      on: t.id == a.task_id,
      join: c in Column,
      on: c.id == t.column_id,
      join: b in Board,
      on: b.id == c.board_id,
      where: b.workspace_id == ^workspace.id,
      order_by: a.filename,
      preload: [:task, :comment]
    )
    |> Repo.all()
  end

  defp read_blob(key) do
    {:ok, stream} = Storage.stream(key)
    stream |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp put_keys do
    receive do
      {:storage_put, key} -> [key | put_keys()]
    after
      0 -> []
    end
  end

  defp attachment_count, do: Repo.aggregate(TaskAttachment, :count)

  # Rewrites the archive at `path` with `fun` applied to its decoded
  # attachments.json rows.
  defp with_rows(ctx, path, fun) do
    files = raw_archive(path)
    rows = files["attachments.json"] |> Jason.decode!() |> fun.()
    write_raw_archive(ctx.dir, Map.put(files, "attachments.json", Jason.encode!(rows)))
  end

  describe "the export" do
    test "the manifest reports format_version 2 and the attachments count", ctx do
      path = archive_path(ctx)
      files = read_archive(path)
      manifest = files["manifest.json"]

      assert manifest["format_version"] == 2
      assert manifest["counts"]["attachments"] == 2
      assert "attachments.json" in manifest["files"]

      expected = :attachments |> Serializer.fields() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      for row <- files["attachments.json"] do
        assert row |> Map.keys() |> Enum.sort() == expected
      end

      refute raw_archive(path)["attachments.json"] =~ "storage_key"
      refute raw_archive(path)["attachments.json"] =~ ctx.notes.storage_key

      blob_names =
        Enum.map([ctx.notes, ctx.shot], &Serializer.blob_entry_name(&1.id))

      # Files only: no directory entry for the attachments directory.
      assert path |> zip_names() |> Enum.sort() ==
               Enum.sort(Serializer.file_names() ++ blob_names)

      assert files[Serializer.blob_entry_name(ctx.notes.id)] == @text
      assert files[Serializer.blob_entry_name(ctx.shot.id)] == tiny_png()
    end

    test "a workspace with no attachments exports an empty attachments.json and no blob entries",
         ctx do
      Repo.delete_all(TaskAttachment)
      path = archive_path(ctx)

      assert path |> zip_names() |> Enum.sort() == Enum.sort(Serializer.file_names())
      assert read_archive(path)["attachments.json"] == []
      assert read_archive(path)["manifest.json"]["counts"]["attachments"] == 0
    end

    test "export fails with export_failed when a blob is missing from storage", ctx do
      :ok = Storage.delete(ctx.shot.storage_key)

      export = export_archive(ctx)

      assert export.status == "failed"
      assert export.error == "export_failed"
      assert export.file_path == nil
      assert ctx.dir |> Path.join("*/.tmp-*") |> Path.wildcard() == []
      assert ctx.dir |> Path.join(".tmp-*") |> Path.wildcard() == []
    end

    test "a blob that no longer matches its row fails the export with export_failed", ctx do
      :ok = Storage.put(ctx.notes.storage_key, {:binary, "changed"})

      assert %WorkspaceExport{status: "failed", error: "export_failed"} = export_archive(ctx)
    end

    test "a storage outage while copying blobs fails the export with storage_unavailable",
         ctx do
      blob = %{id: 1, storage_key: "boards/1/x", byte_size: 1, sha256: String.duplicate("0", 64)}
      put_env(Storage, adapter: __MODULE__.DownStorage)
      ctx.dir |> Path.join("copy") |> File.mkdir_p!()

      assert AttachmentBlobs.copy([blob], Path.join(ctx.dir, "copy")) ==
               {:error, :storage_unavailable}

      assert %WorkspaceExport{status: "failed", error: "storage_unavailable"} =
               export_archive(ctx)
    end
  end

  describe "a scratch disk that refuses writes" do
    test "fails the export with storage_unavailable", ctx do
      put_env(Storage, adapter: __MODULE__.FullDiskStorage)

      assert %WorkspaceExport{status: "failed", error: "storage_unavailable", file_path: nil} =
               export_archive(ctx)

      assert ctx.dir |> Path.join("*/.tmp-*") |> Path.wildcard() == []
      assert ctx.dir |> Path.join(".tmp-*") |> Path.wildcard() == []
    end
  end

  describe "AttachmentBlobs.copy/2" do
    setup ctx do
      dir = Path.join(ctx.dir, "scratch")
      File.mkdir_p!(dir)
      Map.put(ctx, :scratch, dir)
    end

    defp blob_of(attachment),
      do: Map.take(attachment, [:id, :storage_key, :byte_size, :sha256])

    test "copies each blob into an owner-only attachments directory", ctx do
      assert {:ok, names} = AttachmentBlobs.copy([blob_of(ctx.notes)], ctx.scratch)
      assert names == [Serializer.blob_entry_name(ctx.notes.id)]

      dir = Path.join(ctx.scratch, "attachments")
      assert dir |> Path.join("#{ctx.notes.id}") |> File.read!() == @text
      assert File.stat!(dir).access == :read_write
      assert Bitwise.band(File.stat!(dir).mode, 0o077) == 0
      assert Bitwise.band(File.stat!(Path.join(dir, "#{ctx.notes.id}")).mode, 0o077) == 0
    end

    test "creates nothing for no blobs", ctx do
      assert AttachmentBlobs.copy([], ctx.scratch) == {:ok, []}
      refute ctx.scratch |> Path.join("attachments") |> File.exists?()
    end

    test "names a missing, a changed or an unwritable blob", ctx do
      missing = %{blob_of(ctx.notes) | storage_key: unique_storage_key(1)}
      assert AttachmentBlobs.copy([missing], ctx.scratch) == {:error, :not_found}

      changed = %{blob_of(ctx.notes) | byte_size: 1}
      other = Path.join(ctx.dir, "other")
      File.mkdir_p!(other)
      assert AttachmentBlobs.copy([changed], other) == {:error, :blob_mismatch}

      # The attachments directory already exists: refused, never reused.
      assert AttachmentBlobs.copy([blob_of(ctx.notes)], ctx.scratch) == {:error, :eexist}
    end
  end

  describe "the import" do
    test "export then import restores attachment rows, remapped task and comment ids, and identical blobs",
         ctx do
      path = archive_path(ctx)

      assert {:ok, report} = Importer.import_archive(path, ctx.org_admin.email)
      assert report.counts.attachments == 2

      [notes, shot] = imported_attachments(report.workspace_name)

      for {imported, source} <- [{notes, ctx.notes}, {shot, ctx.shot}] do
        assert imported.id != source.id
        assert imported.task_id != source.task_id
        assert imported.task.identifier == ctx.first.identifier
        assert imported.filename == source.filename
        assert imported.content_type == source.content_type
        assert imported.byte_size == source.byte_size
        assert imported.sha256 == source.sha256
        assert imported.uploaded_by_id == ctx.member.id
        assert imported.inserted_at == source.inserted_at
        assert imported.storage_key != source.storage_key

        board_id = Repo.get!(Column, imported.task.column_id).board_id
        assert String.starts_with?(imported.storage_key, "boards/#{board_id}/")
        assert read_blob(imported.storage_key) == read_blob(source.storage_key)
      end

      assert notes.comment_id == nil
      assert shot.comment_id != ctx.comment.id
      assert shot.comment.task_id == shot.task_id
      assert shot.comment.content == ctx.comment.content
    end

    test "a dry run verifies blobs but writes none to storage", ctx do
      path = archive_path(ctx)
      use_hook_storage()
      before = attachment_count()

      assert {:ok, %{dry_run: true, counts: %{attachments: 2}}} =
               Importer.import_archive(path, ctx.org_admin.email, dry_run: true)

      refute_received {:storage_put, _key}
      assert attachment_count() == before

      # Verified, not just counted: a blob that does not match fails the dry run.
      tampered =
        with_rows(ctx, path, fn rows ->
          Enum.map(rows, &Map.put(&1, "sha256", String.duplicate("a", 64)))
        end)

      assert {:error, {:invalid_row, :attachments, _ref, %{sha256: _}}} =
               Importer.import_archive(tampered, ctx.org_admin.email, dry_run: true)

      refute_received {:storage_put, _key}
    end

    test "a failure after some blobs were stored deletes every blob this import wrote", ctx do
      path = archive_path(ctx)
      use_hook_storage()

      # The first put stores, the second fails.
      Process.put(:on_put, fn key, source, opts ->
        if Process.get(:stored) do
          {:error, :storage_unavailable}
        else
          Process.put(:stored, true)
          Storage.Local.put(key, source, opts)
        end
      end)

      before = attachment_count()

      assert Importer.import_archive(path, ctx.org_admin.email) == {:error, :storage_unavailable}

      keys = put_keys()
      assert length(keys) == 2

      for key <- keys do
        assert_received {:storage_deleted, ^key}
        assert Storage.exists(key) == {:ok, false}
      end

      assert attachment_count() == before
    end

    test "a refused row after a stored blob deletes the stored blob", ctx do
      path = archive_path(ctx)
      # Rows are imported in id order, so the second one fails after the
      # first one's blob was stored.
      second_id = max(ctx.notes.id, ctx.shot.id)

      tampered =
        with_rows(ctx, path, fn rows ->
          Enum.map(rows, fn
            %{"id" => ^second_id} = row -> Map.put(row, "sha256", String.duplicate("b", 64))
            row -> row
          end)
        end)

      use_hook_storage()

      assert {:error, {:invalid_row, :attachments, _ref, %{sha256: _}}} =
               Importer.import_archive(tampered, ctx.org_admin.email)

      assert [key] = put_keys()
      assert_received {:storage_deleted, ^key}
      assert Storage.exists(key) == {:ok, false}
    end

    test "an import refused for the organization storage quota writes nothing", ctx do
      path = archive_path(ctx)
      used = Usage.bytes_used({:organization, ctx.organization.id})
      needed = ctx.notes.byte_size + ctx.shot.byte_size
      put_env(Limits, organization_quota_bytes: used + needed - 1)
      use_hook_storage()
      workspaces = Repo.aggregate(Workspace, :count)
      before = attachment_count()

      assert Importer.import_archive(path, ctx.org_admin.email) == {:error, :quota_exceeded}

      refute_received {:storage_put, _key}
      assert attachment_count() == before
      assert Repo.aggregate(Workspace, :count) == workspaces

      # Exactly at the quota fits.
      put_env(Limits, organization_quota_bytes: used + needed)
      assert {:ok, _report} = Importer.import_archive(path, ctx.org_admin.email)
    end

    test "a task given more files than the per-task limit is refused", ctx do
      path = archive_path(ctx)
      put_env(Limits, max_files_per_task: 1)

      assert {:error, {:invalid_row, :attachments, ref, %{task_id: _}}} =
               Importer.import_archive(path, ctx.org_admin.email)

      assert ref == ctx.first.identifier
    end

    test "a version 1 archive without attachments still imports", ctx do
      files = raw_archive(archive_path(ctx))
      manifest = Jason.decode!(files["manifest.json"])

      v1_manifest =
        manifest
        |> Map.put("format_version", 1)
        |> Map.update!("counts", &Map.delete(&1, "attachments"))
        |> Map.update!("files", &List.delete(&1, "attachments.json"))

      v1 =
        files
        |> Map.reject(fn {name, _data} -> Serializer.blob_entry?(name) end)
        |> Map.delete("attachments.json")
        |> Map.put("manifest.json", Jason.encode!(v1_manifest))

      before = attachment_count()

      assert {:ok, report} =
               ctx.dir |> write_raw_archive(v1) |> Importer.import_archive(ctx.org_admin.email)

      refute Map.has_key?(report.counts, :attachments)
      assert report.counts.tasks > 0
      assert attachment_count() == before
    end
  end

  describe "Attachments.with_stored_keys/1" do
    setup do
      use_hook_storage()
      key = unique_storage_key(1)
      :ok = Storage.Local.put(key, {:binary, "x"}, [])
      %{key: key}
    end

    defp store_then(key, result) do
      Attachments.with_stored_keys(fn ref ->
        Attachments.track(ref, key)
        result.()
      end)
    end

    test "keeps the stored keys of a committed result", %{key: key} do
      assert store_then(key, fn -> {:ok, :report} end) == {:ok, :report}
      refute_received {:storage_deleted, _key}
      assert Storage.exists(key) == {:ok, true}
    end

    test "deletes them on a rollback or an error result", %{key: key} do
      assert store_then(key, fn -> {:error, :rollback} end) == {:error, :rollback}
      assert_received {:storage_deleted, ^key}
      assert Storage.exists(key) == {:ok, false}
    end

    test "deletes them when the commit raises", %{key: key} do
      assert_raise DBConnection.ConnectionError, fn ->
        store_then(key, fn -> raise DBConnection.ConnectionError, "commit failed" end)
      end

      assert_received {:storage_deleted, ^key}
      assert Storage.exists(key) == {:ok, false}
    end

    test "parks a tombstone for a key it could not delete", %{key: key} do
      Process.put(:delete_result, {:error, :storage_unavailable})

      assert store_then(key, fn -> {:error, :boom} end) == {:error, :boom}
      assert Repo.get_by(BlobDeletion, storage_key: key)
    end
  end

  defmodule FullDiskStorage do
    @moduledoc false
    # Reads like the local adapter, but first makes every export scratch
    # directory's attachments directory read-only, so the blob copy's write
    # into it fails with a posix error, as a full or read-only disk would.
    @behaviour Kanban.Attachments.Storage

    alias Kanban.Attachments.Storage.Local

    @impl true
    def put(key, source, opts), do: Local.put(key, source, opts)

    @impl true
    def stream(key) do
      :kanban
      |> Application.fetch_env!(:export_dir)
      |> Path.join(".tmp-*/attachments")
      |> Path.wildcard(match_dot: true)
      |> Enum.each(&File.chmod!(&1, 0o500))

      Local.stream(key)
    end

    @impl true
    def delete(key), do: Local.delete(key)
    @impl true
    def exists(key), do: Local.exists(key)
  end

  defmodule DownStorage do
    @moduledoc false
    @behaviour Kanban.Attachments.Storage

    @impl true
    def put(_key, _source, _opts), do: {:error, :storage_unavailable}
    @impl true
    def stream(_key), do: {:error, :storage_unavailable}
    @impl true
    def delete(_key), do: {:error, :storage_unavailable}
    @impl true
    def exists(_key), do: {:error, :storage_unavailable}
  end
end
