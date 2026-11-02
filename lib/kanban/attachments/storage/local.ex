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
      `0o600`. Just before the rename, the temp file's path must still name
      the file the put wrote (the same device and inode, taken when it was
      created); a put that finds it swapped, or `.staging` swapped for a
      link, fails with a logged `:staging_replaced` and renames nothing. A failed
      write removes its temp file, and an unknown source shape is a failed
      write (`:badarg`), and so is a `{:file, path}` that is not a regular
      file (`:source_unreadable`), as in `Kanban.Attachments.Storage.S3`. A process or VM that dies mid-write can leave a
      `.tmp-` file in `.staging`, which no valid key can name, so it is never
      served; `sweep/1`, run by the cleanup worker, removes it once it is an
      hour old.
    * Directories it creates are `0o700`, a missing root's missing ancestors
      included, and files `0o600`. A delete removes
      the key's directories again once they are empty, so a board whose last
      file is gone leaves no directory named after it.
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
    * A hard link is not caught: its real path is inside the root, so a hard
      link planted under a key serves the bytes of the file it shares with
      elsewhere on the same filesystem, and a delete removes only the link.
      Files are not refused for having more than one link, because a backup
      that hard-links the store on the same filesystem would then make every
      file unservable. Only the app's own user can plant one.
    * `sweep/1` checks the root as every other call does, so it never sweeps
      through a symlinked default root or one others can write.

  The directory checks and creation live in
  `Kanban.Attachments.Storage.Local.Tree`; this module writes, serves and
  removes the files.

  The swap check guards against a race only the app's own user (or root)
  could start, since no one else can write under a trusted root: it
  narrows it to the instant between the check and the rename, which no
  call this VM exposes can close. A delete has the same kind of window: a
  key's directory swapped for a link after its checks and before the
  remove would have the remove follow that link, since this VM exposes no
  `unlinkat` on a directory handle. That too needs the app's own user.

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

  alias Kanban.Attachments.Storage.Local.Tree

  require Logger

  @chunk_bytes 65_536

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

  # A configured root may be a symlink an operator chose (to a mounted
  # volume, say) and is followed; the default root never is.
  defp follow_root?, do: configured_root() != nil

  @impl true
  def put(key, source, _opts) do
    case write_and_place(root(), key, source) do
      :ok -> :ok
      {:error, reason} -> unavailable(:put, reason)
    end
  end

  defp write_and_place(root, key, source) do
    with :ok <- check_source(source),
         :ok <- Tree.ensure_root(root, follow_root?()),
         {:ok, staging} <- Tree.ensure_staging(root),
         {:ok, tmp} <- write_tmp(staging, source),
         do: place(tmp, Path.join(root, key), root, key)
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

    case Tree.trusted_tree(root, key, follow_root?()) do
      :ok ->
        if path |> Path.dirname() |> Tree.confined?(root, :dir),
          do: remove(path, root, key),
          else: unavailable(:delete, :outside_root)

      # Nothing can be stored beneath a missing directory or a plain file.
      {:error, reason} when reason in [:enoent, :enotdir, :not_a_directory] ->
        :ok

      {:error, reason} ->
        unavailable(:delete, reason)
    end
  end

  @doc """
  Removes temp files older than `older_than_seconds` from the `.staging`
  directory: writes that never reached their rename because the process or
  the VM died mid-write. A live write's temp file exists only for as long as
  the write takes, so the cleanup worker's one-hour age never touches one.

  The root is checked first, as every other call checks it, and only regular
  `.tmp-` files are removed, only from a `.staging` the app's own user owns
  and no one else can open. A missing root or `.staging` is `:ok`; a root or
  `.staging` that is not trusted, or a temp file that cannot be removed, is
  logged with its reason and returns `{:error, :storage_unavailable}`, after
  every other stale file has still been removed.
  """
  @impl true
  def sweep(older_than_seconds) when is_integer(older_than_seconds) and older_than_seconds > 0 do
    case staged_names(root()) do
      {:ok, staging, names} ->
        staging
        |> sweep_names(names, System.os_time(:second) - older_than_seconds)
        |> swept()

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        unavailable(:sweep, reason)
    end
  end

  defp staged_names(root) do
    staging = Tree.staging(root)

    with :ok <- Tree.check_root(root, follow_root?()),
         :ok <- Tree.private_dir(staging),
         {:ok, names} <- File.ls(staging),
         do: {:ok, staging, names}
  end

  defp sweep_names(staging, names, cutoff) do
    for ".tmp-" <> _ = name <- names,
        {:error, reason} <- [remove_stale(Path.join(staging, name), cutoff)],
        do: reason
  end

  defp swept([]), do: :ok
  defp swept([reason | _more]), do: unavailable(:sweep, reason)

  # A file another sweep removed first is gone, as wanted.
  defp remove_stale(path, cutoff) do
    with {:ok, %File.Stat{type: :regular, mtime: mtime}} when mtime < cutoff <-
           File.lstat(path, time: :posix),
         {:error, reason} when reason != :enoent <- File.rm(path) do
      {:error, reason}
    else
      _removed_young_or_other -> :ok
    end
  end

  # File.rm/1 unlinks a symlink itself and never follows it.
  defp remove(path, root, key) do
    case File.rm(path) do
      :ok -> prune_dirs(root, key)
      {:error, reason} when reason in [:enoent, :enotdir] -> prune_dirs(root, key)
      {:error, reason} -> unavailable(:delete, reason)
    end
  end

  # The key's directories, deepest first, are removed while they are empty,
  # so a board whose last file is gone leaves no `boards/<id>/` directory
  # naming it. rmdir removes only an empty real directory (never a link or
  # anything it points at) and the root itself is never a candidate. A put
  # that loses its directory to this before its rename creates it again
  # (see place/5).
  defp prune_dirs(root, key) do
    key
    |> Path.dirname()
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reverse()
    |> Enum.reduce_while(:ok, fn dir, :ok ->
      case root |> Path.join(dir) |> File.rmdir() do
        :ok -> {:cont, :ok}
        {:error, _not_empty_or_gone} -> {:halt, :ok}
      end
    end)
  end

  # A read through a missing or non-directory segment finds nothing; a
  # directory someone else owns or can write fails loudly.
  defp readable_tree(root, key) do
    case Tree.trusted_tree(root, key, follow_root?()) do
      :ok ->
        :ok

      {:error, reason} when reason in [:enoent, :enotdir, :not_a_directory, :symlink] ->
        {:error, :not_found}

      {:error, reason} ->
        unavailable(:read, reason)
    end
  end

  # A file source must be a regular file, as Storage.S3 requires too: a
  # device such as /dev/null once stored an empty blob here while S3
  # refused it, and a FIFO or /dev/zero could hold or fill the copy.
  defp check_source({:file, path}) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      _missing_or_other -> {:error, :source_unreadable}
    end
  end

  defp check_source(_binary_or_unknown), do: :ok

  # The temp file's identity (device and inode) is taken the moment the
  # exclusive open has created it, and checked again before the rename (see
  # place/5).
  #
  # Both the temp file and the source are opened raw, in this process. A
  # file opened any other way is opened by the VM's one file server, so a
  # source whose open stalls (a FIFO, a hung network mount) would stall
  # every other file call in the VM behind it.
  defp write_tmp(dir, source) do
    tmp = Path.join(dir, tmp_name())

    with {:ok, device} <- File.open(tmp, [:write, :exclusive, :binary, :raw]) do
      tmp |> Tree.file_identity() |> fill_identified(device, tmp, source)
    end
  end

  defp fill_identified({:ok, identity}, device, tmp, source) do
    written = fill(device, tmp, source)
    settle({tmp, identity}, written, File.close(device))
  end

  defp fill_identified({:error, reason}, device, _tmp, _source) do
    _ = File.close(device)
    {:error, replaced(reason)}
  end

  defp fill(device, tmp, source) do
    with :ok <- File.chmod(tmp, 0o600),
         :ok <- write_source(device, source),
         do: :file.sync(device)
  end

  defp settle(tmp, :ok, :ok), do: {:ok, tmp}
  defp settle({tmp, _identity}, :ok, close_error), do: discard(tmp, close_error)
  defp settle({tmp, _identity}, write_error, _closed), do: discard(tmp, write_error)

  # Keys never hold a dot, so a temp name can never be a live key.
  defp tmp_name do
    ".tmp-" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end

  defp write_source(device, {:binary, data}), do: :file.write(device, data)

  defp write_source(device, {:file, source_path}) when is_binary(source_path) do
    case :file.copy({source_path, [:read, :binary, :raw]}, device) do
      {:ok, _bytes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp write_source(_device, _unknown_source), do: {:error, :badarg}

  # The key's directories are created or checked, then the temp file is
  # renamed over the key. A delete of a directory's last other file removes
  # the emptied directories (prune_dirs/2), which can happen between those
  # two steps or between two of the directories, so a missing directory is
  # created and checked again, a bounded number of times.
  #
  # Just before the rename, the temp file's path must still name the file
  # this put wrote. If it was swapped (for a link, for another file under
  # the same name, or because `.staging` itself was swapped for a link to a
  # directory holding one), the rename would place whatever now sits at that
  # path under the live key, so the put is refused with `:staging_replaced`
  # instead, and nothing is removed: a remove through the swapped path would
  # delete what was planted there, not the file this put wrote.
  defp place({tmp_path, _identity} = tmp, path, root, key, retries \\ 3) do
    case rename_into(tmp, path, root, key) do
      :ok -> :ok
      {:error, :staging_replaced} = error -> error
      {:error, :enoent} when retries > 0 -> place(tmp, path, root, key, retries - 1)
      {:error, _reason} = error -> discard(tmp_path, error)
    end
  end

  defp rename_into({tmp_path, _identity} = tmp, path, root, key) do
    with :ok <- Tree.ensure_key_dir(root, key, follow_root?()),
         :ok <- unchanged(tmp),
         do: File.rename(tmp_path, path)
  end

  defp unchanged({tmp_path, identity}) do
    case Tree.file_identity(tmp_path) do
      {:ok, ^identity} -> :ok
      _swapped_or_gone -> {:error, :staging_replaced}
    end
  end

  defp replaced(:enoent), do: :staging_replaced
  defp replaced(:not_a_regular_file), do: :staging_replaced
  defp replaced(reason), do: reason

  defp discard(tmp, error) do
    _ = File.rm(tmp)
    error
  end

  defp servable(path, root) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        if Tree.confined?(path, root, :file), do: :ok, else: {:error, :not_found}

      {:ok, %File.Stat{}} ->
        {:error, :not_found}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:error, :not_found}

      {:error, reason} ->
        unavailable(:read, reason)
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
