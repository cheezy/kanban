defmodule Kanban.Attachments.Storage.Local.Tree do
  @moduledoc """
  The directories of `Kanban.Attachments.Storage.Local`: which ones it
  trusts, how it creates them, and whether a path stays inside the root.

    * A trusted directory is a real directory, never a symlink, owned by the
      app's own user, that no group or other user can write.
    * The root may be a symlink only when an operator configured it (to a
      mounted volume, say), so callers pass `follow?` true for a configured
      root and false for the default one, a fixed name under a temp
      directory other users may share.
    * Every directory it creates is `0o700`, the root's missing ancestors
      included, whatever the umask.
    * The `.staging` directory, where temp files wait for their rename, must
      deny group and other every access, not only writes.
    * `file_identity/1` gives a file's device and inode, so a put can tell,
      just before its rename, that the temp file's path still names the
      file it wrote.

  Functions return `:ok` or `{:ok, value}`, or `{:error, reason}` with a
  POSIX code or one of `:symlink`, `:not_a_directory`, `:not_a_regular_file`,
  `:untrusted_directory` and `:outside_root`. Nothing here logs; the caller
  decides what a reason means.
  """

  alias Kanban.Workspaces.Export

  @group_or_other_write 0o022
  @group_or_other_any 0o077
  @staging ".staging"

  @typedoc "A file system entry's device and inode, as `File.lstat/1` reports them."
  @type identity :: {non_neg_integer(), non_neg_integer()}

  @doc "The staging directory under `root`. Keys never hold a dot, so no key can name it."
  @spec staging(Path.t()) :: Path.t()
  def staging(root), do: Path.join(root, @staging)

  @doc """
  Checks that `root` is a trusted directory. With `follow?` a symlinked root
  is followed; without, a symlink is `{:error, :symlink}`.
  """
  @spec check_root(Path.t(), boolean()) :: :ok | {:error, atom()}
  def check_root(root, follow?) do
    stat = if follow?, do: File.stat(root), else: File.lstat(root)
    check_dir(stat)
  end

  @doc """
  Creates `root` when it is missing, each missing ancestor `0o700` from the
  top down, then checks it like an existing one. A root another user
  created in the gap is refused: `File.mkdir/1` reports it exists and the
  check finds someone else owns it.
  """
  @spec ensure_root(Path.t(), boolean()) :: :ok | {:error, atom()}
  def ensure_root(root, follow?) do
    with {:error, :enoent} <- check_root(root, follow?),
         :ok <- make_dirs(root) do
      check_root(root, follow?)
    end
  end

  # An ancestor that already exists is left as it is, as mkdir_p would; only
  # the directories made here get 0o700.
  defp make_dirs(root) do
    root
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.reduce_while(:ok, fn dir, :ok -> make_dir(dir) end)
  end

  defp make_dir(dir) do
    if File.dir?(dir), do: {:cont, :ok}, else: dir |> File.mkdir() |> made(dir)
  end

  defp made(:ok, dir), do: dir |> File.chmod(0o700) |> continue()
  defp made({:error, :eexist}, _dir), do: {:cont, :ok}
  defp made(error, _dir), do: {:halt, error}

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}

  @doc """
  Checks the root and every directory from it down to the directory that
  holds `key`.
  """
  @spec trusted_tree(Path.t(), String.t(), boolean()) :: :ok | {:error, atom()}
  def trusted_tree(root, key, follow?) do
    with :ok <- check_root(root, follow?) do
      key |> Path.dirname() |> Path.split() |> check_segments(root)
    end
  end

  defp check_segments(["."], _parent), do: :ok
  defp check_segments([], _parent), do: :ok

  defp check_segments([segment | rest], parent) do
    dir = Path.join(parent, segment)

    with :ok <- check_dir(File.lstat(dir)), do: check_segments(rest, dir)
  end

  @doc """
  Creates or checks the root and every directory down to the one that holds
  `key`, then checks that directory's real path is inside the real root.
  `File.mkdir/1`, unlike `mkdir_p`, never reuses a path silently: an
  existing entry is accepted only when it is a trusted directory.
  """
  @spec ensure_key_dir(Path.t(), String.t(), boolean()) :: :ok | {:error, atom()}
  def ensure_key_dir(root, key, follow?) do
    with :ok <- ensure_root(root, follow?),
         :ok <- ensure_dirs(root, key |> Path.dirname() |> Path.split()) do
      dir = root |> Path.join(key) |> Path.dirname()
      if confined?(dir, root, :dir), do: :ok, else: {:error, :outside_root}
    end
  end

  defp ensure_dirs(_parent, ["."]), do: :ok
  defp ensure_dirs(_parent, []), do: :ok

  defp ensure_dirs(parent, [segment | rest]) do
    dir = Path.join(parent, segment)

    with :ok <- ensure_dir(dir), do: ensure_dirs(dir, rest)
  end

  defp ensure_dir(dir) do
    case File.mkdir(dir) do
      :ok -> File.chmod(dir, 0o700)
      {:error, :eexist} -> check_dir(File.lstat(dir))
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Creates the staging directory under `root` when it is missing, `0o700`,
  then checks it with `private_dir/1` and returns its path.
  """
  @spec ensure_staging(Path.t()) :: {:ok, Path.t()} | {:error, atom()}
  def ensure_staging(root) do
    staging = staging(root)

    created =
      case File.mkdir(staging) do
        :ok -> File.chmod(staging, 0o700)
        {:error, :eexist} -> :ok
        {:error, _reason} = error -> error
      end

    with :ok <- created, :ok <- private_dir(staging), do: {:ok, staging}
  end

  @doc """
  Checks that `dir` is a real directory the app's own user owns and that
  group and other users cannot open at all.
  """
  @spec private_dir(Path.t()) :: :ok | {:error, atom()}
  def private_dir(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory} = stat} -> owned(stat, @group_or_other_any)
      other -> check_dir(other)
    end
  end

  @doc """
  The identity of the regular file at `path`, without following a link:
  `{:error, :not_a_regular_file}` for a link, a directory or anything else.
  """
  @spec file_identity(Path.t()) :: {:ok, identity()} | {:error, atom()}
  def file_identity(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, major_device: device, inode: inode}} ->
        {:ok, {device, inode}}

      {:ok, %File.Stat{}} ->
        {:error, :not_a_regular_file}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  True when the real path of `path`, every symlink resolved, stays inside
  the real root: strictly beneath it for a `:file`, the root itself allowed
  for a `:dir`.
  """
  @spec confined?(Path.t(), Path.t(), :file | :dir) :: boolean()
  def confined?(path, root, kind) do
    with {:ok, real} <- Export.real_path(path),
         {:ok, real_root} <- Export.real_path(root) do
      String.starts_with?(real, real_root <> "/") or (kind == :dir and real == real_root)
    else
      _error -> false
    end
  end

  defp check_dir({:ok, %File.Stat{type: :directory} = stat}),
    do: owned(stat, @group_or_other_write)

  defp check_dir({:ok, %File.Stat{type: :symlink}}), do: {:error, :symlink}
  defp check_dir({:ok, %File.Stat{}}), do: {:error, :not_a_directory}
  defp check_dir({:error, _reason} = error), do: error

  defp owned(%File.Stat{uid: uid, mode: mode}, forbidden_bits) do
    with {:ok, own_uid} <- own_uid() do
      if uid == own_uid and Bitwise.band(mode, forbidden_bits) == 0,
        do: :ok,
        else: {:error, :untrusted_directory}
    end
  end

  @doc """
  The VM's effective uid, which Elixir does not expose: the owner of a file
  this process has just created. Learned once, then cached.
  """
  @spec own_uid() :: {:ok, non_neg_integer()} | {:error, atom()}
  def own_uid do
    case :persistent_term.get({__MODULE__, :uid}, nil) do
      nil -> probe_uid()
      uid -> {:ok, uid}
    end
  end

  defp probe_uid do
    probe = Path.join(System.tmp_dir!(), probe_name())

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

  defp probe_name do
    ".uid-probe-" <> (16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))
  end
end
