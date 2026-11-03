defmodule Kanban.Workspaces.Export.AttachmentBlobs do
  @moduledoc """
  Copies the blobs of an export's attachments from
  `Kanban.Attachments.Storage` into the export's scratch directory, for
  `Kanban.Workspaces.Export.Writer` to zip as `attachments/<id>` entries.

  It runs after the snapshot transaction has ended, so slow storage never
  holds a read transaction open. Each blob is streamed chunk by chunk into
  its own owner-only file under an owner-only `attachments` directory, so a
  large file is never held in memory, and its size and sha256 are recomputed
  on the way.

  A blob that cannot be exported as its row describes is left out, and the
  rest of the export goes on (decided 2026-11-03): one lost file must not
  stop a workspace's tasks and comments from being exported. It is returned
  in `skipped` with a reason, for the writer to drop its row and list it in
  the manifest:

    * `:missing` — the blob is not in storage: the attachment was deleted
      after the snapshot and its blob cleaned up, or the blob was lost;
    * `:changed` — the blob's size or digest differs from its row, which the
      importer would refuse.

  Errors stop the export, and are reasons for the writer to map to an
  export error code, never a message, a path or a storage key:

    * `:storage_unavailable` — storage refused or failed the read, so a
      retry may get every file;
    * a `File.posix()` reason — the scratch disk refused a write.
  """

  alias Kanban.Attachments.Storage
  alias Kanban.Workspaces.Export.Serializer
  alias Kanban.Workspaces.Export.Writer

  require Logger

  @type blob :: %{
          id: pos_integer(),
          storage_key: String.t(),
          byte_size: non_neg_integer(),
          sha256: String.t()
        }

  @type error :: :storage_unavailable | File.posix()

  @type skip_reason :: :missing | :changed

  @type copied :: %{
          names: [String.t()],
          skipped: [%{id: pos_integer(), reason: skip_reason()}]
        }

  @doc """
  Copies every blob in `blobs` into `tmp_dir/attachments/<id>` and returns
  the zip entry names of those copied and the blobs left out, both in
  order. With no blobs nothing is created.
  """
  @spec copy([blob()], String.t()) :: {:ok, copied()} | {:error, error()}
  def copy([], _tmp_dir), do: {:ok, %{names: [], skipped: []}}

  def copy(blobs, tmp_dir) when is_list(blobs) and is_binary(tmp_dir) do
    dir = Path.join(tmp_dir, "attachments")

    with :ok <- Writer.mkdir_exclusive(dir) do
      blobs
      |> Enum.reduce_while({:ok, %{names: [], skipped: []}}, &copy_next(&1, &2, dir))
      |> in_order()
    end
  end

  defp copy_next(blob, {:ok, acc}, dir) do
    case copy_one(blob, dir) do
      {:ok, name} -> {:cont, {:ok, %{acc | names: [name | acc.names]}}}
      {:skip, reason} -> {:cont, {:ok, %{acc | skipped: [skipped(blob, reason) | acc.skipped]}}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp skipped(%{id: id}, reason) do
    Logger.warning("workspace export: left out attachment #{id}: #{reason}")
    %{id: id, reason: reason}
  end

  defp in_order({:ok, %{names: names, skipped: skipped}}),
    do: {:ok, %{names: Enum.reverse(names), skipped: Enum.reverse(skipped)}}

  defp in_order(error), do: error

  defp copy_one(%{id: id} = blob, dir) do
    path = Path.join(dir, Integer.to_string(id))

    with {:ok, stream} <- open(blob),
         {:ok, written} <- write_stream(path, stream),
         :ok <- check_matches(blob, written, path) do
      {:ok, Serializer.blob_entry_name(id)}
    end
  end

  # An unusable key names no blob, exactly as a missing one.
  defp open(blob) do
    case Storage.stream(blob.storage_key) do
      {:ok, stream} -> {:ok, stream}
      {:error, reason} when reason in [:not_found, :invalid_key] -> {:skip, :missing}
      {:error, _reason} -> {:error, :storage_unavailable}
    end
  end

  # :exclusive, so nothing planted at the path is written through.
  defp write_stream(path, stream) do
    with {:ok, io} <- File.open(path, [:write, :exclusive, :binary, :raw]) do
      _ = File.chmod(path, 0o600)
      io |> copy_into(stream) |> written()
    end
  end

  # An adapter can fail mid-stream (the local one raises File.Error).
  defp copy_into(io, stream) do
    Enum.reduce_while(stream, {:ok, {0, :crypto.hash_init(:sha256)}}, &write_chunk(io, &1, &2))
  rescue
    _error -> {:error, :storage_unavailable}
  after
    File.close(io)
  end

  defp write_chunk(io, chunk, {:ok, {size, hash}}) do
    case :file.write(io, chunk) do
      :ok -> {:cont, {:ok, {size + byte_size(chunk), :crypto.hash_update(hash, chunk)}}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp written({:ok, {size, hash}}),
    do:
      {:ok,
       %{byte_size: size, sha256: hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}}

  defp written(error), do: error

  defp check_matches(
         %{byte_size: size, sha256: sha256},
         %{byte_size: size, sha256: sha256},
         _path
       ),
       do: :ok

  # The copy is removed, so the zip never holds a blob without its row.
  defp check_matches(_blob, _written, path) do
    _ = File.rm(path)
    {:skip, :changed}
  end
end
