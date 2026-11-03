defmodule Kanban.Workspaces.Export.Importer.Archive do
  @moduledoc """
  Reads and checks a workspace export archive before anything is written
  (W2222).

  The archive is untrusted. Its JSON entries must be exactly the manifest and
  one file per entity of its format version
  (`Kanban.Workspaces.Export.Serializer.file_names/1`) — no directories, no
  other names, no duplicates — whose uncompressed size stays under a fixed
  limit (1 GiB by default, `:max_uncompressed`). The sizes the archive declares are checked first, but
  they are not trusted: every entry is inflated in bounded chunks against a
  running byte budget (`:zlib.safeInflate/2`), and the read stops with
  `:archive_too_large` the moment the real output passes the limit, so a zip
  bomb with false size headers is never inflated in full. The
  manifest is decoded first, so an unknown `format_version` is refused before
  any entity file is parsed, and every entity file must hold exactly the
  number of rows the manifest counts.

  No two rows of an entity that other rows refer to by id — boards, columns,
  labels, tasks and users — may share an id: the importer remaps references
  by source id, so a repeated one would link rows to the wrong board, column,
  task or user. Such an archive is refused with `{:duplicate_id, entity}`.
  Comments may still repeat an id; an attachment that names a repeated
  comment id is refused when it is imported.

  ## Attachment blobs (version 2)

  Every other entry must be a blob named `attachments/<positive integer>`
  with no leading zero (`Serializer.parse_blob_entry_name/1`), exactly one
  per `attachments.json` row with that id; a version 1 archive has none.
  Anything else under `attachments/` — a directory entry, a nested or
  traversing name, a duplicate — or a row without a blob, a blob without a
  row, or two rows with one id, is `:invalid_archive`.

  `read/1` never inflates a blob. It returns an index of where each blob
  lies, and the importer extracts them one at a time with `extract_blob/4`
  (`Kanban.Workspaces.Export.Importer.ArchiveBlob`). Blobs have their own
  budget, separate from the JSON limit so neither starves the other: each
  is at most `Kanban.Attachments.Limits.max_file_bytes/0`, and all of them
  together at most `max_attachment_bytes/0` (10 GiB by default,
  `:max_attachment_bytes`). Declared sizes past either are refused here;
  the real bytes are held to the same limits while a blob is extracted.
  """

  alias Kanban.Attachments.Limits
  alias Kanban.Workspaces.Export.Importer.ArchiveBlob
  alias Kanban.Workspaces.Export.Serializer

  @default_max_uncompressed 1_073_741_824
  @default_max_attachment_bytes 10_737_418_240

  @typedoc "Where one blob lies in the archive, as its central directory declares."
  @type blob_entry :: %{
          offset: non_neg_integer(),
          comp_size: non_neg_integer(),
          size: non_neg_integer() | :infinity
        }

  @type t :: %{
          manifest: map(),
          version: pos_integer(),
          rows: %{atom() => [map()]},
          path: String.t(),
          blobs: %{pos_integer() => blob_entry()}
        }
  @type error ::
          :invalid_archive
          | :invalid_manifest
          | :archive_too_large
          | :counts_mismatch
          | {:unsupported_format_version, term()}
          | {:invalid_file, atom()}
          | {:duplicate_id, atom()}

  @doc """
  Reads the archive at `path`, or explains why it cannot be imported. The
  result carries the decoded rows and the index of the blobs, which stay in
  the archive until `extract_blob/4`.
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, error()}
  def read(path) when is_binary(path) do
    with :ok <- regular_file(path),
         {:ok, json, blobs} <- split_entries(path),
         {:ok, archive} <- read_json(path, json) do
      index_archive_blobs(Map.put(archive, :path, path), blobs)
    end
  end

  @doc """
  Extracts the blob at `entry` of the archive at `path` into a new
  owner-only file `dest`, inflating at most `max_bytes` bytes, and returns
  its real size and sha256. See `Kanban.Workspaces.Export.Importer.ArchiveBlob`.
  """
  @spec extract_blob(String.t(), blob_entry(), String.t(), non_neg_integer()) ::
          {:ok, %{byte_size: non_neg_integer(), sha256: String.t()}}
          | {:error, :archive_too_large | :invalid_archive | :storage_unavailable}
  defdelegate extract_blob(path, entry, dest, max_bytes), to: ArchiveBlob, as: :extract

  @doc """
  The most bytes all of an archive's blobs may inflate to together:
  `config :kanban, #{inspect(__MODULE__)}, max_attachment_bytes:`, 10 GiB by
  default.
  """
  @spec max_attachment_bytes() :: non_neg_integer()
  def max_attachment_bytes, do: setting(:max_attachment_bytes, @default_max_attachment_bytes)

  # Blob entries are set aside here, so only the JSON entries are inflated.
  defp split_entries(path) do
    with {:ok, entries} <- list_entries(path) do
      {json, blobs} = Enum.split_with(entries, &(not blob_entry?(&1)))
      {:ok, json, blobs}
    end
  end

  defp read_json(path, json) do
    limit = max_uncompressed()

    with :ok <- check_entries(json, limit),
         {:ok, files} <- inflate_entries(path, json, limit) do
      decode_files(files, json)
    end
  end

  # The manifest first, so an unknown format_version is refused before any
  # entity file is parsed; then the JSON names that version must hold.
  defp decode_files(files, json) do
    with {:ok, manifest} <- decode_manifest(files),
         version = manifest["format_version"],
         :ok <- check_names(json, Serializer.file_names(version)),
         {:ok, rows} <- decode_checked_rows(files, manifest, version) do
      {:ok, %{manifest: manifest, version: version, rows: rows}}
    end
  end

  defp decode_checked_rows(files, manifest, version) do
    with {:ok, rows} <- decode_entities(files, version),
         :ok <- check_counts(manifest, rows),
         :ok <- check_unique_ids(rows),
         do: {:ok, rows}
  end

  defp index_archive_blobs(archive, blobs) do
    with {:ok, index} <- index_blobs(blobs, archive.version),
         :ok <- check_blob_sizes(index),
         :ok <- check_blob_rows(archive.rows, index) do
      {:ok, Map.put(archive, :blobs, index)}
    end
  end

  defp blob_entry?({name, _info, _offset, _comp}),
    do: name |> List.to_string() |> Serializer.blob_entry?()

  defp decode_manifest(files) do
    files
    |> Map.fetch!("manifest.json")
    |> Serializer.decode_manifest()
  end

  # Overridable only so tests can reach the limit with a small archive.
  defp max_uncompressed, do: setting(:max_uncompressed, @default_max_uncompressed)

  defp setting(key, default) do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  defp regular_file(path) do
    if File.regular?(path), do: :ok, else: {:error, :invalid_archive}
  end

  defp list_entries(path) do
    case path |> String.to_charlist() |> :zip.list_dir() do
      {:ok, [_comment | entries]} ->
        {:ok,
         for(
           {:zip_file, name, info, _comment, offset, comp_size} <- entries,
           do: {name, info, offset, comp_size}
         )}

      _error ->
        {:error, :invalid_archive}
    end
  end

  # Before anything is inflated: the JSON names must be those of a version
  # this code reads, and their declared sizes within the JSON limit. Once
  # the manifest names its version, check_names/2 pins the set to it.
  defp check_entries(entries, limit) do
    cond do
      not known_names?(entries) -> {:error, :invalid_archive}
      declared_total(entries) > limit -> {:error, :archive_too_large}
      true -> :ok
    end
  end

  defp known_names?(entries) do
    Serializer.format_versions()
    |> Enum.map(&Serializer.file_names/1)
    |> Enum.any?(&(check_names(entries, &1) == :ok))
  end

  defp declared_total(entries) do
    Enum.reduce(entries, 0, fn {_name, info, _offset, _comp}, acc ->
      add_size(acc, entry_size(info))
    end)
  end

  defp check_names(entries, expected) do
    names = Enum.map(entries, fn {name, _info, _offset, _comp} -> List.to_string(name) end)
    if Enum.sort(names) == Enum.sort(expected), do: :ok, else: {:error, :invalid_archive}
  end

  # A version 1 archive holds no blobs. Each name must be a valid blob name,
  # and no two may name the same attachment.
  defp index_blobs([], _version), do: {:ok, %{}}
  defp index_blobs(_blobs, 1), do: {:error, :invalid_archive}

  defp index_blobs(blobs, _version), do: Enum.reduce_while(blobs, {:ok, %{}}, &index_blob/2)

  defp index_blob({name, info, offset, comp_size}, {:ok, index}) do
    with {:ok, id} <- name |> List.to_string() |> Serializer.parse_blob_entry_name(),
         false <- Map.has_key?(index, id) do
      entry = %{offset: offset, comp_size: comp_size, size: entry_size(info)}
      {:cont, {:ok, Map.put(index, id, entry)}}
    else
      _invalid -> {:halt, {:error, :invalid_archive}}
    end
  end

  # Declared sizes only, so a too-large archive is refused before any work;
  # ArchiveBlob holds the real bytes to the same limits.
  defp check_blob_sizes(index) do
    per_file = Limits.max_file_bytes()

    total =
      Enum.reduce(index, 0, fn {_id, %{size: size}}, acc -> add_size(acc, size) end)

    if total > max_attachment_bytes() or
         Enum.any?(index, fn {_id, %{size: size}} -> size > per_file end),
       do: {:error, :archive_too_large},
       else: :ok
  end

  # One blob per row and one row per blob, each row id a positive integer.
  defp check_blob_rows(%{attachments: rows}, index) do
    ids = Enum.map(rows, & &1["id"])

    if Enum.all?(ids, &(is_integer(&1) and &1 > 0)) and length(Enum.uniq(ids)) == length(ids) and
         MapSet.new(ids) == index |> Map.keys() |> MapSet.new(),
       do: :ok,
       else: {:error, :invalid_archive}
  end

  defp check_blob_rows(_rows, _index), do: :ok

  # A #file_info{} record; its size is the uncompressed size.
  defp entry_size(info) when is_tuple(info) and elem(info, 0) == :file_info do
    case elem(info, 1) do
      size when is_integer(size) and size >= 0 -> size
      _unknown -> :infinity
    end
  end

  defp entry_size(_info), do: :infinity

  # An unknown size makes the total :infinity, which exceeds any limit.
  defp add_size(total, size) when is_integer(total) and is_integer(size), do: total + size
  defp add_size(_total, _size), do: :infinity

  # Inflates every entry from its local header with a running budget, never
  # trusting the declared sizes: :zip.unzip/2 would inflate an entry in full
  # whatever its header claims.
  defp inflate_entries(path, entries, limit) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          inflate_all(io, entries, limit)
        after
          File.close(io)
        end

      {:error, _reason} ->
        {:error, :invalid_archive}
    end
  end

  defp inflate_all(io, entries, limit) do
    entries
    |> Enum.reduce_while({:ok, %{}, limit}, &inflate_next(io, &1, &2))
    |> inflated_files()
  end

  # Each entry is inflated against what is left of the budget, and the budget
  # shrinks by the bytes it really produced.
  defp inflate_next(io, {name, _info, offset, comp_size}, {:ok, files, budget}) do
    case read_entry(io, offset, comp_size, budget) do
      {:ok, data} ->
        {:cont, {:ok, Map.put(files, List.to_string(name), data), budget - byte_size(data)}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp inflated_files({:ok, files, _budget}), do: {:ok, files}
  defp inflated_files({:error, reason}), do: {:error, reason}

  defp read_entry(io, offset, comp_size, budget) do
    with {:ok, header} <- read_local_header(io, offset),
         {:ok, compressed} <- read_data(io, header.data_offset, comp_size),
         {:ok, data} <- decompress(header.method, compressed, budget),
         true <- crc_ok?(header, data) do
      {:ok, data}
    else
      {:error, :archive_too_large} -> {:error, :archive_too_large}
      _invalid -> {:error, :invalid_archive}
    end
  end

  @doc false
  # A local file header is 30 bytes followed by the name and the extra field.
  # Public for ArchiveBlob, which reads a blob from the same header.
  @spec read_local_header(:file.io_device(), non_neg_integer()) ::
          {:ok, %{flags: integer(), method: integer(), crc: integer(), data_offset: integer()}}
          | {:error, :invalid_archive}
  def read_local_header(io, offset) do
    case :file.pread(io, offset, 30) do
      {:ok,
       <<0x04034B50::little-32, _version::16, flags::little-16, method::little-16, _time::16,
         _date::16, crc::little-32, _comp::32, _size::32, name_length::little-16,
         extra_length::little-16>>} ->
        {:ok,
         %{
           flags: flags,
           method: method,
           crc: crc,
           data_offset: offset + 30 + name_length + extra_length
         }}

      _invalid ->
        {:error, :invalid_archive}
    end
  end

  # With a trailing data descriptor (flag bit 3) the local header's CRC is
  # zero; the inflate budget still applies, and the JSON decode catches a
  # corrupt entry.
  defp crc_ok?(%{flags: flags}, _data) when Bitwise.band(flags, 8) == 8, do: true
  defp crc_ok?(%{crc: crc}, data), do: :erlang.crc32(data) == crc

  defp read_data(_io, _position, 0), do: {:ok, <<>>}

  defp read_data(io, position, comp_size) do
    case :file.pread(io, position, comp_size) do
      {:ok, data} when byte_size(data) == comp_size -> {:ok, data}
      _short_or_error -> {:error, :invalid_archive}
    end
  end

  defp decompress(0, data, budget) when byte_size(data) > budget,
    do: {:error, :archive_too_large}

  defp decompress(0, data, _budget), do: {:ok, data}

  defp decompress(8, data, budget) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      inflate_chunks(z, :zlib.safeInflate(z, data), [], budget)
    rescue
      ErlangError -> {:error, :invalid_archive}
    after
      :zlib.close(z)
    end
  end

  defp decompress(_method, _data, _budget), do: {:error, :invalid_archive}

  defp inflate_chunks(z, {status, output}, acc, budget) do
    remaining = budget - IO.iodata_length(output)
    acc = [acc | output]

    cond do
      remaining < 0 -> {:error, :archive_too_large}
      status == :finished -> {:ok, IO.iodata_to_binary(acc)}
      true -> inflate_chunks(z, :zlib.safeInflate(z, []), acc, remaining)
    end
  end

  defp decode_entities(files, version) do
    version
    |> Serializer.entities()
    |> Enum.reduce_while({:ok, %{}}, fn entity, {:ok, acc} ->
      case Serializer.decode_rows(entity, Map.fetch!(files, Serializer.file_name(entity))) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, entity, rows)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @referenced_entities [:boards, :columns, :labels, :tasks, :users]

  defp check_unique_ids(rows) do
    case Enum.find(@referenced_entities, &repeats_id?(Map.fetch!(rows, &1))) do
      nil -> :ok
      entity -> {:error, {:duplicate_id, entity}}
    end
  end

  defp repeats_id?(list) do
    ids = Enum.map(list, & &1["id"])
    length(Enum.uniq(ids)) != length(ids)
  end

  defp check_counts(%{"counts" => counts}, rows) do
    if Enum.all?(rows, fn {entity, list} -> counts[Atom.to_string(entity)] == length(list) end),
      do: :ok,
      else: {:error, :counts_mismatch}
  end
end
