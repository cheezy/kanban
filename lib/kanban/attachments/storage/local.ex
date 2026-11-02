defmodule Kanban.Attachments.Storage.Local do
  @moduledoc """
  Stores attachment bytes as files under a root directory on this machine's
  own disk. The default adapter of `Kanban.Attachments.Storage`, for dev,
  test and single-machine self-hosting.

  The root is `config :kanban, Kanban.Attachments.Storage.Local, root:`
  (`ATTACHMENTS_DIR` in `config/runtime.exs`), or a `stride_attachments`
  directory under the system temp directory when unset.

  > #### Single-machine storage {: .warning}
  >
  > Files live on the disk of the machine that wrote them. With more than one
  > app machine, a file written on one is invisible to the others, and on a
  > host with no persistent volume (a Fly machine without `[mounts]`, for
  > example) every file disappears on redeploy. Use
  > `Kanban.Attachments.Storage.S3` there, or point the root at storage every
  > machine shares and that survives a redeploy.

  How files are written and served:

    * A put writes a temp file with an unguessable name in a `.staging`
      directory under the root, opened exclusively so it never follows a
      planted link, syncs it to disk, then renames it over the key, so a
      crash or a failed copy never leaves a half-written file under a live
      key. `.staging` must be `0o700` or stricter whoever created it, so no
      other user can open a temp file in the moment before it is made
      `0o600`. A failed write removes its temp file; a VM that dies
      mid-write can leave a `.tmp-` file in `.staging`, which no valid key
      can name, so it is never served and can be deleted.
    * Directories it creates are `0o700` and files `0o600`.
    * The root and every directory on the way to a key must be owned by the
      app's own user and writable by no one else (no group or other write
      bit), or the call fails with `:storage_unavailable` and a logged
      `:untrusted_directory`. So a root another local user created first,
      under a shared `/tmp` say, is refused rather than written into.
    * A directory on the way to a key must be a real directory, not a
      symlink, and the real path of every file served must stay inside the
      real root. A symlink planted under the root therefore never serves, and
      never receives, a file from elsewhere. The root itself may be a symlink
      only when it is configured explicitly; the default root never is.

  Keys arrive already validated by `Kanban.Attachments.Storage`, so they
  hold no `..`, no leading slash and no empty segment.

  `stream/1` checks the file and opens it before it returns, so a file that
  is gone or unreadable is an error the caller can still answer with a 404,
  and the stream reads the file it opened even if the path is replaced or
  removed afterwards. Enumerate it once, in the calling process: the file is
  closed when the stream ends or that process exits. A file swapped for a
  link between the check and the open would be read, but only the app's own
  user can write under the checked root to do that.
  """

  @behaviour Kanban.Attachments.Storage

  alias Kanban.Workspaces.Export

  require Logger

  @chunk_bytes 65_536
  @group_or_other_write 0o022
  @group_or_other_any 0o077
  @staging ".staging"

  @doc """
  The root directory: `config :kanban, Kanban.Attachments.Storage.Local,
  root:`, or a `stride_attachments` directory under the system temp
  directory. Expanded.
  """
  @spec root() :: String.t()
  def root do
    case configured_root() do
      nil -> System.tmp_dir!() |> Path.join("stride_attachments") |> Path.expand()
      dir -> Path.expand(dir)
    end
  end

  defp configured_root do
    case :kanban |> Application.get_env(__MODULE__, []) |> Keyword.get(:root) do
      dir when is_binary(dir) and dir != "" -> dir
      _unset -> nil
    end
  end

  @impl true
  def put(key, source, _opts) do
    root = root()
    path = Path.join(root, key)

    with :ok <- ensure_key_dir(root, key),
         {:ok, staging} <- ensure_staging(root),
         {:ok, tmp} <- write_tmp(staging, source),
         :ok <- commit(tmp, path) do
      :ok
    else
      {:error, reason} -> unavailable(:put, reason)
    end
  end

  @impl true
  def stream(key) do
    root = root()
    path = Path.join(root, key)

    with :ok <- readable_tree(root, key),
         :ok <- servable(path, root),
         {:ok, device} <- open_for_read(path),
         do: {:ok, chunks(device)}
  end

  # Opened here, before stream/1 returns, so a file that is gone or that the
  # app may not read is refused while the caller can still answer 404. The
  # stream then reads the file it opened, whatever happens to the path.
  defp open_for_read(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, device} -> {:ok, device}
      {:error, reason} when reason in [:enoent, :enotdir, :eisdir] -> {:error, :not_found}
      {:error, reason} -> unavailable(:read, reason)
    end
  end

  # A read error mid-stream raises a File.Error, as File.stream!/2 does,
  # whose path is the storage key: callers keep only its reason.
  defp chunks(device) do
    Stream.resource(
      fn -> device end,
      fn device ->
        case :file.read(device, @chunk_bytes) do
          {:ok, data} ->
            {[data], device}

          :eof ->
            {:halt, device}

          {:error, reason} ->
            raise File.Error, reason: reason, action: "stream", path: "attachment"
        end
      end,
      &File.close/1
    )
  end

  @impl true
  def exists(key) do
    root = root()

    with :ok <- readable_tree(root, key),
         :ok <- servable(Path.join(root, key), root) do
      {:ok, true}
    else
      {:error, :not_found} -> {:ok, false}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def delete(key) do
    root = root()
    path = Path.join(root, key)

    case trusted_tree(root, key) do
      :ok ->
        if confined?(Path.dirname(path), root, :dir),
          do: remove(path),
          else: unavailable(:delete, :outside_root)

      # Nothing can be stored beneath a missing directory or a plain file.
      {:error, reason} when reason in [:enoent, :enotdir, :not_a_directory] ->
        :ok

      {:error, reason} ->
        unavailable(:delete, reason)
    end
  end

  # File.rm/1 unlinks a symlink itself and never follows it.
  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, reason} when reason in [:enoent, :enotdir] -> :ok
      {:error, reason} -> unavailable(:delete, reason)
    end
  end

  # A missing root is created, then checked like an existing one, so a root
  # another user created in the gap is refused too: mkdir_p accepts it and
  # the chmod of a directory someone else owns fails.
  defp ensure_root(root) do
    with {:error, :enoent} <- check_root(root),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      check_root(root)
    end
  end

  # The root may itself be a symlink an operator configured (to a mounted
  # volume, say), so a configured root is followed; the default root, a
  # fixed name under a temp directory other users may share, never is.
  defp check_root(root) do
    stat = if configured_root(), do: File.stat(root), else: File.lstat(root)
    check_dir(stat)
  end

  # Every directory from the root down to the key's own.
  defp trusted_tree(root, key) do
    with :ok <- check_root(root) do
      key |> Path.dirname() |> Path.split() |> check_segments(root)
    end
  end

  defp check_segments(["."], _parent), do: :ok
  defp check_segments([], _parent), do: :ok

  defp check_segments([segment | rest], parent) do
    dir = Path.join(parent, segment)

    with :ok <- check_dir(File.lstat(dir)), do: check_segments(rest, dir)
  end

  # A read through a missing or non-directory segment finds nothing; a
  # directory someone else owns or can write fails loudly.
  defp readable_tree(root, key) do
    case trusted_tree(root, key) do
      :ok ->
        :ok

      {:error, reason} when reason in [:enoent, :enotdir, :not_a_directory, :symlink] ->
        {:error, :not_found}

      {:error, reason} ->
        unavailable(:read, reason)
    end
  end

  defp check_dir({:ok, %File.Stat{type: :directory} = stat}), do: owned(stat)
  defp check_dir({:ok, %File.Stat{type: :symlink}}), do: {:error, :symlink}
  defp check_dir({:ok, %File.Stat{}}), do: {:error, :not_a_directory}
  defp check_dir({:error, _reason} = error), do: error

  defp owned(stat, forbidden_bits \\ @group_or_other_write)

  defp owned(%File.Stat{uid: uid, mode: mode}, forbidden_bits) do
    with {:ok, own_uid} <- own_uid() do
      if uid == own_uid and Bitwise.band(mode, forbidden_bits) == 0,
        do: :ok,
        else: {:error, :untrusted_directory}
    end
  end

  # Temp files live here until renamed into place. Unlike the directories
  # on the way to a key, it must deny group and other every access, not
  # only writes, because a temp file is briefly readable under the umask.
  # Keys never hold a dot, so no key can name it.
  defp ensure_staging(root) do
    staging = Path.join(root, @staging)

    result =
      case File.mkdir(staging) do
        :ok -> File.chmod(staging, 0o700)
        {:error, :eexist} -> private_dir(File.lstat(staging))
        {:error, _reason} = error -> error
      end

    with :ok <- result, do: {:ok, staging}
  end

  defp private_dir({:ok, %File.Stat{type: :directory} = stat}),
    do: owned(stat, @group_or_other_any)

  defp private_dir(stat), do: check_dir(stat)

  # The VM's effective uid, which Elixir does not expose: the owner of a
  # file this process has just created. Learned once, then cached.
  defp own_uid do
    case :persistent_term.get({__MODULE__, :uid}, nil) do
      nil -> probe_uid()
      uid -> {:ok, uid}
    end
  end

  defp probe_uid do
    probe = Path.join(System.tmp_dir!(), tmp_name())

    with {:ok, device} <- File.open(probe, [:write, :exclusive]) do
      _ = File.close(device)
      stat = File.lstat(probe)
      _ = File.rm(probe)

      with {:ok, %File.Stat{uid: uid}} <- stat do
        :persistent_term.put({__MODULE__, :uid}, uid)
        {:ok, uid}
      end
    end
  end

  defp ensure_dirs(_parent, ["."]), do: :ok
  defp ensure_dirs(_parent, []), do: :ok

  defp ensure_dirs(parent, [segment | rest]) do
    dir = Path.join(parent, segment)

    with :ok <- ensure_dir(dir), do: ensure_dirs(dir, rest)
  end

  # File.mkdir/1, unlike mkdir_p, never reuses a path silently: an existing
  # entry is accepted only when lstat shows a real directory, not a link,
  # that this app's user owns and no one else can write.
  defp ensure_dir(dir) do
    case File.mkdir(dir) do
      :ok -> File.chmod(dir, 0o700)
      {:error, :eexist} -> check_dir(File.lstat(dir))
      {:error, _reason} = error -> error
    end
  end

  defp confined_dir(dir, root) do
    if confined?(dir, root, :dir), do: :ok, else: {:error, :outside_root}
  end

  # The root, then every directory down to the key's own, created or
  # checked, and the key's directory confined to the root.
  defp ensure_key_dir(root, key) do
    with :ok <- ensure_root(root),
         :ok <- ensure_dirs(root, key |> Path.dirname() |> Path.split()) do
      root |> Path.join(key) |> Path.dirname() |> confined_dir(root)
    end
  end

  defp write_tmp(dir, source) do
    tmp = Path.join(dir, tmp_name())

    with {:ok, device} <- File.open(tmp, [:write, :exclusive, :binary]) do
      written = fill(device, tmp, source)
      settle(tmp, written, File.close(device))
    end
  end

  defp fill(device, tmp, source) do
    with :ok <- File.chmod(tmp, 0o600),
         :ok <- write_source(device, source),
         do: :file.sync(device)
  end

  defp settle(tmp, :ok, :ok), do: {:ok, tmp}
  defp settle(tmp, :ok, close_error), do: discard(tmp, close_error)
  defp settle(tmp, write_error, _closed), do: discard(tmp, write_error)

  # Keys never hold a dot, so a temp name can never be a live key.
  defp tmp_name do
    ".tmp-" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp write_source(device, {:binary, data}), do: :file.write(device, data)

  defp write_source(device, {:file, source_path}) do
    case :file.copy(source_path, device) do
      {:ok, _bytes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp commit(tmp, path) do
    case File.rename(tmp, path) do
      :ok -> :ok
      {:error, _reason} = error -> discard(tmp, error)
    end
  end

  defp discard(tmp, error) do
    _ = File.rm(tmp)
    error
  end

  defp servable(path, root) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        if confined?(path, root, :file), do: :ok, else: {:error, :not_found}

      {:ok, %File.Stat{}} ->
        {:error, :not_found}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:error, :not_found}

      {:error, reason} ->
        unavailable(:read, reason)
    end
  end

  # The real path, every symlink resolved, must stay inside the real root.
  # A file must lie strictly beneath it; a directory may be the root itself.
  defp confined?(path, root, kind) do
    with {:ok, real} <- Export.real_path(path),
         {:ok, real_root} <- Export.real_path(root) do
      String.starts_with?(real, real_root <> "/") or (kind == :dir and real == real_root)
    else
      _error -> false
    end
  end

  # Only the operation and a POSIX code or atom are logged, never a path.
  defp unavailable(operation, reason) do
    Logger.warning("attachment storage #{operation} failed: #{inspect(reason_code(reason))}")
    {:error, :storage_unavailable}
  end

  defp reason_code(reason) when is_atom(reason), do: reason
  defp reason_code(_reason), do: :unknown
end
