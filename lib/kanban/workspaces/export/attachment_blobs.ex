defmodule Kanban.Workspaces.Export.AttachmentBlobs do
  @moduledoc """
  Copies the blobs of an export's attachments from
  `Kanban.Attachments.Storage` into the export's scratch directory, for
  `Kanban.Workspaces.Export.Writer` to zip as `attachments/<id>` entries.

  It runs after the snapshot transaction has ended, so slow storage never
  holds a read transaction open. Each blob is streamed chunk by chunk into
  its own owner-only file under an owner-only `attachments` directory, so a
  large file is never held in memory, and its size and sha256 are recomputed
  on the way: a blob that no longer matches its row fails the export rather
  than shipping an archive the importer would refuse.

  Errors are reasons for the writer to map to an export error code, never a
  message, a path or a storage key:

    * `:not_found` — a blob is missing from storage;
    * `:blob_mismatch` — a blob's size or digest differs from its row;
    * `:storage_unavailable` — storage refused or failed the read;
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

  @type error :: :not_found | :blob_mismatch | :storage_unavailable | File.posix()

  @doc """
  Copies every blob in `blobs` into `tmp_dir/attachments/<id>` and returns
  their zip entry names, in order. With no blobs nothing is created.
  """
  @spec copy([blob()], String.t()) :: {:ok, [String.t()]} | {:error, error()}
  def copy([], _tmp_dir), do: {:ok, []}

  def copy(blobs, tmp_dir) when is_list(blobs) and is_binary(tmp_dir) do
    dir = Path.join(tmp_dir, "attachments")

    with :ok <- Writer.mkdir_exclusive(dir) do
      blobs
      |> Enum.reduce_while({:ok, []}, fn blob, {:ok, names} ->
        case copy_one(blob, dir) do
          {:ok, name} -> {:cont, {:ok, [name | names]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> reverse_names()
    end
  end

  defp reverse_names({:ok, names}), do: {:ok, Enum.reverse(names)}
  defp reverse_names(error), do: error

  defp copy_one(%{id: id} = blob, dir) do
    path = Path.join(dir, Integer.to_string(id))

    with {:ok, stream} <- Storage.stream(blob.storage_key),
         {:ok, written} <- write_stream(path, stream),
         :ok <- check_matches(blob, written) do
      {:ok, Serializer.blob_entry_name(id)}
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

  defp check_matches(%{byte_size: size, sha256: sha256}, %{byte_size: size, sha256: sha256}),
    do: :ok

  defp check_matches(%{id: id}, _written) do
    Logger.warning("workspace export: attachment #{id} does not match its stored blob")
    {:error, :blob_mismatch}
  end
end
