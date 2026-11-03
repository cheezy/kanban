defmodule Kanban.Workspaces.Export.ImporterArchiveAttachmentsTest do
  # async: false — points the process-wide :export_dir, the storage adapter
  # and the archive and attachment limits at values of its own.
  use Kanban.DataCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AttachmentHookStorage, only: [use_hook_storage: 0]
  import Kanban.AttachmentsFixtures
  import Kanban.WorkspaceExportFixtures

  alias Kanban.Attachments.Limits
  alias Kanban.Attachments.TaskAttachment
  alias Kanban.Tasks.TaskComment
  alias Kanban.Workspaces.Export
  alias Kanban.Workspaces.Export.Importer
  alias Kanban.Workspaces.Export.Importer.Archive
  alias Kanban.Workspaces.Export.Importer.ArchiveBlob
  alias Kanban.Workspaces.Export.Serializer
  alias Kanban.Workspaces.Export.WorkspaceExport

  @text String.duplicate("plain text line\n", 64)

  setup do
    ctx = seed_workspace(export_org_fixture())

    notes =
      stored_attachment_fixture(ctx.first, @text, %{
        filename: "notes.txt",
        content_type: "text/plain"
      })

    Map.merge(ctx, %{dir: tmp_export_dir(), notes: notes})
  end

  defp export_files(ctx) do
    {:ok, export} = Export.request_export(ctx.org_admin, ctx.workspace)
    Oban.drain_queue(queue: :workspace_exports)
    %WorkspaceExport{status: "succeeded", file_path: path} = Repo.get!(WorkspaceExport, export.id)
    raw_archive(path)
  end

  defp put_env(module, settings) do
    previous = Application.get_env(:kanban, module)
    Application.put_env(:kanban, module, Keyword.merge(previous || [], settings))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:kanban, module, previous),
        else: Application.delete_env(:kanban, module)
    end)
  end

  defp rows(files, entity),
    do: files |> Map.fetch!(Serializer.file_name(entity)) |> Jason.decode!()

  # Replaces an entity's rows and recounts the manifest to match them.
  defp put_rows(files, entity, rows) do
    manifest =
      files["manifest.json"]
      |> Jason.decode!()
      |> put_in(["counts", Atom.to_string(entity)], length(rows))

    files
    |> Map.put(Serializer.file_name(entity), Jason.encode!(rows))
    |> Map.put("manifest.json", Jason.encode!(manifest))
  end

  defp update_attachment(files, changes) do
    updated = files |> rows(:attachments) |> Enum.map(&Map.merge(&1, changes))
    put_rows(files, :attachments, updated)
  end

  defp blob_name(ctx), do: Serializer.blob_entry_name(ctx.notes.id)

  defp zip_entries(ctx, entries, opts \\ []) do
    path = Path.join(ctx.dir, "entries-#{System.unique_integer([:positive])}.zip")
    entries = Enum.map(entries, fn {name, data} -> {String.to_charlist(name), data} end)
    {:ok, _} = path |> String.to_charlist() |> :zip.create(entries, opts)
    path
  end

  defp read(ctx, files), do: ctx.dir |> write_raw_archive(files) |> Archive.read()

  defp import_files(ctx, files, opts \\ []),
    do: ctx.dir |> write_raw_archive(files, opts) |> Importer.import_archive(ctx.org_admin.email)

  defp attachment_count, do: Repo.aggregate(TaskAttachment, :count)

  # Sets every uncompressed size the zip declares to 1 byte, in the local
  # headers and the central directory alike.
  defp declare_tiny_sizes(zip) do
    zip
    |> patch_field(<<"PK", 3, 4>>, 22, <<1::little-32>>)
    |> patch_field(<<"PK", 1, 2>>, 24, <<1::little-32>>)
  end

  defp patch_field(zip, signature, field_offset, value) do
    zip
    |> :binary.matches(signature)
    |> Enum.reduce(zip, fn {at, _length}, acc ->
      position = at + field_offset
      size = byte_size(value)
      <<head::binary-size(^position), _old::binary-size(^size), rest::binary>> = acc
      head <> value <> rest
    end)
  end

  defp lying_archive(ctx, files) do
    path = write_raw_archive(ctx.dir, files)
    File.write!(path, declare_tiny_sizes(File.read!(path)))
    path
  end

  defp assert_nothing_written(before, fun) do
    use_hook_storage()
    result = fun.()
    refute_received {:storage_put, _key}
    assert attachment_count() == before
    result
  end

  describe "blob entries and rows" do
    test "refuses a blob entry with no attachments.json row and a row with no blob entry", ctx do
      files = export_files(ctx)
      assert {:ok, %{version: 2, blobs: blobs}} = read(ctx, files)
      assert Map.keys(blobs) == [ctx.notes.id]

      extra = Map.put(files, Serializer.blob_entry_name(ctx.notes.id + 1), "orphan")
      assert read(ctx, extra) == {:error, :invalid_archive}

      missing = Map.delete(files, blob_name(ctx))
      assert read(ctx, missing) == {:error, :invalid_archive}

      [row] = rows(files, :attachments)
      repeated = put_rows(files, :attachments, [row, row])
      assert read(ctx, repeated) == {:error, :invalid_archive}

      not_integer = update_attachment(files, %{"id" => "#{ctx.notes.id}"})
      assert read(ctx, not_integer) == {:error, :invalid_archive}
    end

    test "refuses blob entry names outside attachments/<positive integer>, including traversal and directories",
         ctx do
      files = export_files(ctx)

      for name <- [
            "attachments/../x",
            "attachments/0#{ctx.notes.id}",
            "attachments/0",
            "attachments/#{ctx.notes.id}/2",
            "attachments/",
            "attachments/x",
            "attachments/-1",
            "../x"
          ] do
        assert read(ctx, Map.put(files, name, "x")) == {:error, :invalid_archive},
               "#{name} was accepted"
      end

      duplicated = Enum.to_list(files) ++ [{blob_name(ctx), @text}]
      assert ctx |> zip_entries(duplicated) |> Archive.read() == {:error, :invalid_archive}
    end

    test "refuses blob entries in a version 1 archive", ctx do
      files = export_files(ctx)

      manifest =
        files["manifest.json"]
        |> Jason.decode!()
        |> Map.put("format_version", 1)
        |> Map.update!("counts", &Map.delete(&1, "attachments"))

      v1 =
        files
        |> Map.delete("attachments.json")
        |> Map.put("manifest.json", Jason.encode!(manifest))

      assert read(ctx, v1) == {:error, :invalid_archive}
      assert {:ok, %{version: 1, blobs: blobs}} = read(ctx, Map.delete(v1, blob_name(ctx)))
      assert blobs == %{}

      # A version 2 manifest must come with the version 2 files.
      assert read(ctx, Map.delete(files, "attachments.json")) == {:error, :invalid_archive}
    end
  end

  describe "limits" do
    test "refuses a blob larger than the per-file limit while inflating, despite a false size header",
         ctx do
      files = export_files(ctx)
      big = String.duplicate("a", 200_000)
      files = files |> Map.put(blob_name(ctx), big) |> update_attachment(%{"byte_size" => 500})
      put_env(Limits, max_file_bytes: 1_000)

      before = attachment_count()

      result =
        assert_nothing_written(before, fn ->
          ctx |> lying_archive(files) |> Importer.import_archive(ctx.org_admin.email)
        end)

      assert result == {:error, :archive_too_large}

      # Honest headers past the limit are refused before anything is inflated.
      assert read(ctx, files) == {:error, :archive_too_large}
    end

    test "never inflates a blob past its limit", ctx do
      path = zip_entries(ctx, [{"attachments/1", :binary.copy(<<0>>, 5_000_000)}])
      dest = Path.join(ctx.dir, "bomb")

      assert ArchiveBlob.extract(path, entry(path, "attachments/1"), dest, 65_536) ==
               {:error, :archive_too_large}

      assert File.stat!(dest).size <= 65_536
    end

    test "refuses an archive whose blobs exceed the attachment byte budget with archive_too_large",
         ctx do
      files = export_files(ctx)
      put_env(Archive, max_attachment_bytes: byte_size(@text) - 1)

      assert read(ctx, files) == {:error, :archive_too_large}

      before = attachment_count()

      result =
        assert_nothing_written(before, fn ->
          ctx |> lying_archive(files) |> Importer.import_archive(ctx.org_admin.email)
        end)

      assert result == {:error, :archive_too_large}

      put_env(Archive, max_attachment_bytes: byte_size(@text))
      assert {:ok, %{counts: %{attachments: 1}}} = import_files(ctx, files)
    end

    test "holds every blob to one running budget, despite false size headers", ctx do
      stored_attachment_fixture(ctx.second, @text, %{
        filename: "more.txt",
        content_type: "text/plain"
      })

      files = export_files(ctx)
      # Each blob fits on its own; together they are one byte over.
      put_env(Archive, max_attachment_bytes: 2 * byte_size(@text) - 1)

      use_hook_storage()
      before = attachment_count()

      assert ctx |> lying_archive(files) |> Importer.import_archive(ctx.org_admin.email) ==
               {:error, :archive_too_large}

      # The first blob was stored before the second ran out of budget; it is
      # deleted again with the rollback.
      assert_received {:storage_put, key}
      assert_received {:storage_deleted, ^key}
      refute_received {:storage_put, _other}
      assert attachment_count() == before

      put_env(Archive, max_attachment_bytes: 2 * byte_size(@text))

      assert {:ok, %{counts: %{attachments: 2}}} =
               ctx |> lying_archive(files) |> Importer.import_archive(ctx.org_admin.email)
    end

    test "keeps the 1 GiB limit for the JSON entity files separate from the blob budget", ctx do
      big = String.duplicate("a large attachment line\n", 20_000)

      stored_attachment_fixture(ctx.second, big, %{
        filename: "big.txt",
        content_type: "text/plain"
      })

      files = export_files(ctx)

      json_total =
        files
        |> Enum.reject(fn {name, _data} -> Serializer.blob_entry?(name) end)
        |> Enum.map(fn {_name, data} -> byte_size(data) end)
        |> Enum.sum()

      assert byte_size(big) > json_total

      # The JSON files alone fit: the larger blob does not count against them.
      put_env(Archive, max_uncompressed: json_total)
      assert {:ok, %{version: 2}} = read(ctx, files)

      # And a generous blob budget does not stretch the JSON limit.
      put_env(Archive,
        max_uncompressed: json_total - 1,
        max_attachment_bytes: 10 * byte_size(big)
      )

      assert read(ctx, files) == {:error, :archive_too_large}
    end
  end

  describe "verifying each blob against its row" do
    test "refuses a blob whose size or sha256 does not match its row", ctx do
      files = export_files(ctx)
      before = attachment_count()

      sized = update_attachment(files, %{"byte_size" => byte_size(@text) + 1})

      assert {:error, {:invalid_row, :attachments, ref, %{byte_size: _}}} =
               assert_nothing_written(before, fn -> import_files(ctx, sized) end)

      assert ref == ~s("notes.txt", id #{ctx.notes.id})

      digest = update_attachment(files, %{"sha256" => String.duplicate("0", 64)})

      assert {:error, {:invalid_row, :attachments, _ref, %{sha256: _}}} =
               assert_nothing_written(before, fn -> import_files(ctx, digest) end)

      zero = update_attachment(files, %{"byte_size" => 0})

      assert {:error, {:invalid_row, :attachments, _ref, %{byte_size: ["is invalid"]}}} =
               import_files(ctx, zero)
    end

    test "refuses a row whose content type is outside the allow-list", ctx do
      files =
        ctx
        |> export_files()
        |> update_attachment(%{
          "filename" => "tool.exe",
          "content_type" => "application/x-msdownload"
        })

      before = attachment_count()

      assert {:error, {:invalid_row, :attachments, _ref, %{content_type: [_ | _]}}} =
               assert_nothing_written(before, fn -> import_files(ctx, files) end)

      # The contents must match the type too.
      png = files |> update_attachment(%{"filename" => "x.png", "content_type" => "image/png"})

      assert {:error, {:invalid_row, :attachments, _ref, %{content_type: [_ | _]}}} =
               import_files(ctx, png)
    end

    test "imports stored (uncompressed) blob entries too", ctx do
      files = export_files(ctx)
      assert {:ok, %{counts: %{attachments: 1}}} = import_files(ctx, files, uncompress: :all)
    end
  end

  describe "links to tasks and comments" do
    test "skips an attachment whose task is not in the archive", ctx do
      files = ctx |> export_files() |> update_attachment(%{"task_id" => 999_999_999})

      assert {:ok, report} = import_files(ctx, files)
      assert report.counts.attachments == 0
      assert {:attachments, "attachment: task not in the archive"} in report.skipped
    end

    test "skips, rather than refuses, a comment attachment whose task was skipped", ctx do
      comment = from(c in TaskComment, where: c.task_id == ^ctx.first.id) |> Repo.one!()
      files = export_files(ctx)

      # The task is gone, so neither the comment it names (imported or not)
      # nor the attachment is imported; the attachment is skipped, not refused.
      for comment_id <- [comment.id, 999_999_999] do
        changed =
          update_attachment(files, %{"task_id" => 999_999_999, "comment_id" => comment_id})

        assert {:ok, report} = import_files(ctx, changed)
        assert report.counts.attachments == 0
        assert {:attachments, "attachment: task not in the archive"} in report.skipped
      end
    end

    test "refuses a comment that is on another task, not in the archive, or repeated", ctx do
      other =
        %TaskComment{task_id: ctx.second.id}
        |> TaskComment.changeset(%{content: "elsewhere"})
        |> Repo.insert!()

      files = export_files(ctx)

      assert {:error, {:invalid_row, :attachments, _, %{comment_id: ["is on another task"]}}} =
               import_files(ctx, update_attachment(files, %{"comment_id" => other.id}))

      assert {:error, {:invalid_row, :attachments, _, %{comment_id: ["is not in the archive"]}}} =
               import_files(ctx, update_attachment(files, %{"comment_id" => 999_999_999}))

      [comment | _] = files |> rows(:comments) |> Enum.filter(&(&1["task_id"] == ctx.first.id))
      repeated = put_rows(files, :comments, rows(files, :comments) ++ [comment])

      assert {:error,
              {:invalid_row, :attachments, _, %{comment_id: ["is repeated in the archive"]}}} =
               import_files(ctx, update_attachment(repeated, %{"comment_id" => comment["id"]}))
    end
  end

  describe "ArchiveBlob.extract/4" do
    setup ctx do
      data = String.duplicate("blob bytes ", 10_000)
      path = zip_entries(ctx, [{"attachments/7", data}])
      Map.merge(ctx, %{data: data, path: path, entry: entry(path, "attachments/7")})
    end

    test "writes the blob to an owner-only file and returns its size and digest", ctx do
      dest = Path.join(ctx.dir, "out")

      assert ArchiveBlob.extract(ctx.path, ctx.entry, dest, byte_size(ctx.data)) ==
               {:ok, %{byte_size: byte_size(ctx.data), sha256: sha256_hex(ctx.data)}}

      assert File.read!(dest) == ctx.data
      assert Bitwise.band(File.stat!(dest).mode, 0o077) == 0

      # dest is never written through.
      assert ArchiveBlob.extract(ctx.path, ctx.entry, dest, byte_size(ctx.data)) ==
               {:error, :storage_unavailable}
    end

    test "refuses a truncated stream, a CRC mismatch and an unknown method", ctx do
      truncated = %{ctx.entry | comp_size: ctx.entry.comp_size - 8}

      assert ArchiveBlob.extract(ctx.path, truncated, Path.join(ctx.dir, "a"), 1_000_000) ==
               {:error, :invalid_archive}

      zip = File.read!(ctx.path)
      bad_crc = Path.join(ctx.dir, "crc.zip")
      File.write!(bad_crc, patch_field(zip, <<"PK", 3, 4>>, 14, <<1::little-32>>))

      assert ArchiveBlob.extract(bad_crc, ctx.entry, Path.join(ctx.dir, "b"), 1_000_000) ==
               {:error, :invalid_archive}

      bad_method = Path.join(ctx.dir, "method.zip")
      File.write!(bad_method, patch_field(zip, <<"PK", 3, 4>>, 8, <<99::little-16>>))

      assert ArchiveBlob.extract(bad_method, ctx.entry, Path.join(ctx.dir, "c"), 1_000_000) ==
               {:error, :invalid_archive}

      assert ctx.dir |> Path.join("none.zip") |> ArchiveBlob.extract(ctx.entry, "x", 1) ==
               {:error, :invalid_archive}
    end

    test "refuses a compressed size past the limit before reading it", ctx do
      # Random bytes do not compress, so the deflated entry is larger than
      # any output 10 bytes could come from.
      noise = zip_entries(ctx, [{"attachments/8", :crypto.strong_rand_bytes(4_096)}])

      assert ArchiveBlob.extract(
               noise,
               entry(noise, "attachments/8"),
               Path.join(ctx.dir, "d"),
               10
             ) ==
               {:error, :archive_too_large}

      refute ctx.dir |> Path.join("d") |> File.exists?()

      stored = zip_entries(ctx, [{"attachments/7", ctx.data}], uncompress: :all)

      assert ArchiveBlob.extract(
               stored,
               entry(stored, "attachments/7"),
               Path.join(ctx.dir, "e"),
               10
             ) ==
               {:error, :archive_too_large}

      refute ctx.dir |> Path.join("e") |> File.exists?()

      assert {:ok, %{byte_size: size}} =
               ArchiveBlob.extract(
                 stored,
                 entry(stored, "attachments/7"),
                 Path.join(ctx.dir, "f"),
                 byte_size(ctx.data)
               )

      assert size == byte_size(ctx.data)
    end
  end

  describe "Serializer blob entry names" do
    test "names and parses attachments/<positive integer> only" do
      assert Serializer.blob_entry_name(42) == "attachments/42"
      assert Serializer.parse_blob_entry_name("attachments/42") == {:ok, 42}

      for name <-
            [
              "attachments/042",
              "attachments/0",
              "attachments/",
              "/attachments/1",
              "attachments/1/2"
            ] ++
              ["attachments/../1", "attachments/1 ", "Attachments/1", "attachments/1.png"] do
        assert Serializer.parse_blob_entry_name(name) == :error, "#{name} parsed"
      end

      assert Serializer.blob_entry?("attachments/anything")
      refute Serializer.blob_entry?("attachments.json")
    end

    test "knows each version's entities and files" do
      assert Serializer.format_versions() == [1, 2]
      refute :attachments in Serializer.entities(1)
      assert :attachments in Serializer.entities(2)
      assert Serializer.entities(2) == Serializer.entities()
      assert Serializer.file_names(2) == Serializer.file_names()
      assert Serializer.file_names(1) == Serializer.file_names() -- ["attachments.json"]
    end

    test "decodes a version 1 manifest without an attachments count" do
      manifest =
        "W"
        |> Serializer.encode_manifest(%{}, DateTime.utc_now())
        |> IO.iodata_to_binary()
        |> Jason.decode!()

      v1 =
        manifest
        |> Map.put("format_version", 1)
        |> Map.update!("counts", &Map.delete(&1, "attachments"))

      assert {:ok, %{"format_version" => 1}} =
               v1 |> Jason.encode!() |> Serializer.decode_manifest()

      v2 = Map.update!(manifest, "counts", &Map.delete(&1, "attachments"))
      assert v2 |> Jason.encode!() |> Serializer.decode_manifest() == {:error, :invalid_manifest}
    end
  end

  # The central directory's view of `name` in the zip at `path`.
  defp entry(path, name) do
    {:ok, [_comment | entries]} = path |> String.to_charlist() |> :zip.list_dir()
    target = String.to_charlist(name)

    Enum.find_value(entries, fn
      {:zip_file, ^target, info, _comment, offset, comp_size} ->
        %{offset: offset, comp_size: comp_size, size: elem(info, 1)}

      _other ->
        nil
    end)
  end
end
