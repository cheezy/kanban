defmodule Kanban.Workspaces.Export.Importer.ArchiveBlob do
  @moduledoc """
  Extracts one attachment blob from a workspace export archive to a file,
  for `Kanban.Workspaces.Export.Importer.Attachments` (through
  `Kanban.Workspaces.Export.Importer.Archive.extract_blob/4`).

  The archive is untrusted, so nothing it declares is believed:

    * the compressed size is capped before anything is read, so a huge
      declared entry is refused without a read;
    * the entry is read in 64 KiB chunks and inflated with
      `:zlib.safeInflate/2`, whose output comes in bounded pieces; the
      extraction stops with `:archive_too_large` as soon as the real output
      passes `max_bytes`, so a zip bomb with false size headers is never
      inflated in full and memory holds one chunk at a time;
    * the size and sha256 returned are recomputed from the bytes written,
      for the caller to compare with the row, and the CRC is checked against
      the local header unless the entry has a trailing data descriptor;
    * a truncated or corrupt stream is `:invalid_archive`.

  `dest` is created exclusively and owner-only, so nothing planted at its
  path is written through. The caller owns `dest` and deletes it. A failure
  to create or write it is `:storage_unavailable`.
  """

  alias Kanban.Workspaces.Export.Importer.Archive

  @chunk_bytes 65_536

  @type result :: %{byte_size: non_neg_integer(), sha256: String.t()}
  @type error :: :archive_too_large | :invalid_archive | :storage_unavailable

  @doc """
  Inflates the blob at `entry` (`Archive.blob_entry()`) of the archive at
  `archive_path` into `dest`, producing at most `max_bytes` bytes.
  """
  @spec extract(String.t(), Archive.blob_entry(), String.t(), non_neg_integer()) ::
          {:ok, result()} | {:error, error()}
  def extract(archive_path, %{offset: offset, comp_size: comp_size}, dest, max_bytes)
      when is_binary(archive_path) and is_binary(dest) and is_integer(max_bytes) do
    case File.open(archive_path, [:read, :binary, :raw]) do
      {:ok, io} ->
        try do
          extract_from(io, offset, comp_size, dest, max_bytes)
        after
          File.close(io)
        end

      {:error, _reason} ->
        {:error, :invalid_archive}
    end
  end

  defp extract_from(io, offset, comp_size, dest, max_bytes) do
    with {:ok, header} <- Archive.read_local_header(io, offset),
         :ok <- check_comp_size(header.method, comp_size, max_bytes),
         {:ok, out} <- open_dest(dest) do
      try do
        source = %{io: io, position: header.data_offset, remaining: comp_size}
        header |> inflate_to(source, out, max_bytes) |> finish(header)
      after
        File.close(out)
      end
    end
  end

  # Stored data is never larger than its output; deflate grows incompressible
  # data by at most a few bytes per 16 KiB block.
  defp check_comp_size(0, comp_size, max_bytes) when comp_size > max_bytes,
    do: {:error, :archive_too_large}

  defp check_comp_size(8, comp_size, max_bytes)
       when comp_size > max_bytes + div(max_bytes, 1000) + 1024,
       do: {:error, :archive_too_large}

  defp check_comp_size(method, _comp_size, _max_bytes) when method in [0, 8], do: :ok
  defp check_comp_size(_method, _comp_size, _max_bytes), do: {:error, :invalid_archive}

  defp open_dest(dest) do
    case File.open(dest, [:write, :exclusive, :binary, :raw]) do
      {:ok, out} ->
        _ = File.chmod(dest, 0o600)
        {:ok, out}

      {:error, _reason} ->
        {:error, :storage_unavailable}
    end
  end

  defp inflate_to(%{method: 0}, source, out, max_bytes),
    do: each_chunk(source, initial(out, max_bytes), &emit(&1, &2))

  defp inflate_to(%{method: 8}, source, out, max_bytes) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      state = each_chunk(source, initial(out, max_bytes), &pump(z, :zlib.safeInflate(z, &1), &2))
      end_stream(z, state)
    rescue
      ErlangError -> {:error, :invalid_archive}
    after
      :zlib.close(z)
    end
  end

  # :zlib.inflateEnd/1 raises data_error unless the whole stream was seen.
  defp end_stream(z, {:ok, _state} = ok) do
    :zlib.inflateEnd(z)
    ok
  end

  defp end_stream(_z, error), do: error

  defp initial(out, max_bytes),
    do: {:ok, %{out: out, max: max_bytes, bytes: 0, hash: :crypto.hash_init(:sha256), crc: 0}}

  # Reads the compressed data in chunks and folds each through `fun`.
  defp each_chunk(%{remaining: 0}, acc, _fun), do: acc

  defp each_chunk(%{remaining: remaining} = source, {:ok, _} = acc, fun) do
    size = min(remaining, @chunk_bytes)

    case read_chunk(source, size) do
      {:ok, chunk} -> each_chunk(advance(source, size), fun.(chunk, acc), fun)
      :error -> {:error, :invalid_archive}
    end
  end

  defp each_chunk(_source, error, _fun), do: error

  # A short read means the archive ends inside the entry.
  defp read_chunk(%{io: io, position: position}, size) do
    case :file.pread(io, position, size) do
      {:ok, chunk} when byte_size(chunk) == size -> {:ok, chunk}
      _short_or_error -> :error
    end
  end

  defp advance(%{position: position, remaining: remaining} = source, size),
    do: %{source | position: position + size, remaining: remaining - size}

  # {:finished, _} means this input is used up, not that the stream ended.
  # An error stops the pump at once, so a bomb is never inflated further.
  defp pump(_z, _result, {:error, _reason} = error), do: error
  defp pump(z, {:continue, output}, acc), do: pump(z, :zlib.safeInflate(z, []), emit(output, acc))
  defp pump(_z, {:finished, output}, acc), do: emit(output, acc)
  defp pump(_z, _other, _acc), do: {:error, :invalid_archive}

  defp emit(_output, {:error, _reason} = error), do: error

  defp emit(output, {:ok, state}) do
    data = IO.iodata_to_binary(output)
    bytes = state.bytes + byte_size(data)

    cond do
      bytes > state.max ->
        {:error, :archive_too_large}

      :file.write(state.out, data) != :ok ->
        {:error, :storage_unavailable}

      true ->
        {:ok,
         %{
           state
           | bytes: bytes,
             hash: :crypto.hash_update(state.hash, data),
             crc: :erlang.crc32(state.crc, data)
         }}
    end
  end

  defp finish({:ok, state}, header) do
    if crc_ok?(header, state.crc),
      do: {:ok, %{byte_size: state.bytes, sha256: digest(state.hash)}},
      else: {:error, :invalid_archive}
  end

  defp finish(error, _header), do: error

  # With a trailing data descriptor (flag bit 3) the local header's CRC is
  # zero; the caller's sha256 comparison still catches a corrupt blob.
  defp crc_ok?(%{flags: flags}, _crc) when Bitwise.band(flags, 8) == 8, do: true
  defp crc_ok?(%{crc: crc}, actual), do: crc == actual

  defp digest(hash), do: hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
end
