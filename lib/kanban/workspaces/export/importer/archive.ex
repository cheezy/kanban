defmodule Kanban.Workspaces.Export.Importer.Archive do
  @moduledoc """
  Reads and checks a workspace export archive before anything is written
  (W2222).

  The archive is untrusted. It must be a zip holding exactly the manifest and
  one file per `Kanban.Workspaces.Export.Serializer.entities/0` entity — no
  directories, no other names, no duplicates — whose uncompressed size stays
  under a fixed limit. The sizes the archive declares are checked first, but
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
  """

  alias Kanban.Workspaces.Export.Serializer

  @default_max_uncompressed 1_073_741_824

  @type t :: %{manifest: map(), rows: %{atom() => [map()]}}
  @type error ::
          :invalid_archive
          | :invalid_manifest
          | :archive_too_large
          | :counts_mismatch
          | {:unsupported_format_version, term()}
          | {:invalid_file, atom()}
          | {:duplicate_id, atom()}

  @doc "Reads the archive at `path`, or explains why it cannot be imported."
  @spec read(String.t()) :: {:ok, t()} | {:error, error()}
  def read(path) when is_binary(path) do
    limit = max_uncompressed()

    with :ok <- regular_file(path),
         {:ok, entries} <- list_entries(path),
         :ok <- check_entries(entries, limit),
         {:ok, files} <- inflate_entries(path, entries, limit) do
      decode_files(files)
    end
  end

  # The manifest first, so an unknown format_version is refused before any
  # entity file is parsed.
  defp decode_files(files) do
    with {:ok, manifest} <- decode_manifest(files),
         {:ok, rows} <- decode_entities(files),
         :ok <- check_counts(manifest, rows),
         :ok <- check_unique_ids(rows) do
      {:ok, %{manifest: manifest, rows: rows}}
    end
  end

  defp decode_manifest(files) do
    files
    |> Map.fetch!("manifest.json")
    |> Serializer.decode_manifest()
  end

  # Overridable only so tests can reach the limit with a small archive.
  defp max_uncompressed do
    :kanban
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:max_uncompressed, @default_max_uncompressed)
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

  defp check_entries(entries, limit) do
    names = Enum.map(entries, fn {name, _info, _offset, _comp} -> List.to_string(name) end)

    total =
      Enum.reduce(entries, 0, fn {_name, info, _offset, _comp}, acc ->
        add_size(acc, entry_size(info))
      end)

    cond do
      Enum.sort(names) != Enum.sort(Serializer.file_names()) -> {:error, :invalid_archive}
      total > limit -> {:error, :archive_too_large}
      true -> :ok
    end
  end

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

  # A local file header is 30 bytes followed by the name and the extra field.
  defp read_local_header(io, offset) do
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

  defp decode_entities(files) do
    Enum.reduce_while(Serializer.entities(), {:ok, %{}}, fn entity, {:ok, acc} ->
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
