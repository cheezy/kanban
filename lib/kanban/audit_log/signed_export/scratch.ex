defmodule Kanban.AuditLog.SignedExport.Scratch do
  @moduledoc """
  The temporary directory a signed audit export is built in
  (`Kanban.AuditLog.SignedExport`), and what removes it.

  The directory briefly holds audit data, with actor emails and IP addresses.
  It is owner-only with an unpredictable name
  (`Kanban.Workspaces.Export.Writer.create_tmp_dir/1`).

  ## Who removes it

    * **The building process.** `release/1` removes the directory. The
      builder calls it in an `after` clause, so it runs when the build
      returns, raises or throws.
    * **A guard process.** An `after` clause does not run when the building
      process is ended by an exit signal: a request process killed because
      its connection closed, or at shutdown. So `checkout/0` starts a guard
      under `Kanban.TaskSupervisor`. The guard creates the directory, monitors
      the building process and removes the directory when that process goes
      down, however it ends. The guard also removes it when the supervisor
      stops the guard itself.
    * **A sweep at boot and every 15 minutes.** A killed VM runs neither of
      the above. `sweep/0` removes the directories of this module's root
      that are more than an hour old.
      `Kanban.AuditLog.SignedExport.Sweeper` runs it, so what a killed VM
      left is gone within an hour and a quarter, whether or not the VM that
      replaces it is ever restarted.

  The operating system can refuse a removal, for example when the root has
  lost its write permission. Each refusal is logged as a warning, and the
  sweep tries again once the directory is an hour old.

  ## The root

  Directories are created in `System.tmp_dir/0`'s `stride-signed-exports`,
  which this module creates owner-only on first use. Other operating-system
  users can write to the system temporary directory, so both `checkout/0` and
  `sweep/0` use that root only when it is a real directory that this VM's
  user owns: a symlink planted under the name, or a directory another user
  made, is refused.
  `config :kanban, Kanban.AuditLog.SignedExport, tmp_root: path` names another
  root instead. That one must exist already, and it must hold nothing else:
  the sweep removes any stale entry in it that is named like one of these
  directories.

  Nothing here logs a path.
  """

  alias Kanban.AuditLog.SignedExport
  alias Kanban.Workspaces.Export.Writer

  require Logger

  @default_dir "stride-signed-exports"
  @stale_after_seconds 3600

  @typedoc "A checked-out directory: its path and the guard that watches it."
  @type t :: %{path: String.t(), guard: pid()}

  @doc """
  Creates a new temporary directory and starts the guard that removes it if
  the calling process dies. Returns `{:error, reason}` when there is no
  usable root or the directory cannot be created; nothing is left behind.
  """
  @spec checkout() :: {:ok, t()} | {:error, atom()}
  def checkout do
    owner = self()
    tag = make_ref()

    case Task.Supervisor.start_child(Kanban.TaskSupervisor, fn -> guard(owner, tag) end) do
      {:ok, guard} -> await(guard, tag)
      _not_started -> {:error, :no_guard}
    end
  end

  @doc """
  Removes the directory and stops its guard. The directory is gone when this
  returns, unless the operating system refuses the removal, which is logged.
  """
  @spec release(t()) :: :ok
  def release(%{path: path, guard: guard}) do
    remove(path)
    send(guard, :released)
    :ok
  end

  @doc """
  Removes the directories left in the root by a VM that was killed during a
  signed export: those named like one of this module's directories whose
  last change is more than an hour old. Returns how many it removed; one the
  operating system refuses to remove is logged and not counted. Never raises;
  a root that does not exist yet holds nothing to remove.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    with {:ok, root} <- existing_root(),
         {:ok, names} <- File.ls(root) do
      names |> Enum.count(&remove_if_stale(root, &1)) |> report()
    else
      _no_root_or_unreadable -> 0
    end
  end

  defp report(0), do: 0

  # A count only: a killed VM left audit data on disk, which an operator
  # should hear about, without a path.
  defp report(removed) do
    Logger.warning("signed audit export: removed #{removed} stale temporary directories")
    removed
  end

  # The guard creates the directory itself, after it has started to monitor
  # the owner, so there is no moment when a directory exists unwatched.
  # sobelow_skip ["Traversal.FileModule"]
  defp guard(owner, tag) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)

    case create() do
      {:ok, path} ->
        send(owner, {tag, {:ok, path}})
        if wait(monitor) == :remove, do: remove(path)

      {:error, reason} ->
        send(owner, {tag, {:error, reason}})
    end
  end

  # The owner released the directory, and so has removed it already; or the
  # owner went down, or the supervisor is stopping this guard, and the guard
  # removes it.
  defp wait(monitor) do
    receive do
      :released -> :released
      {:DOWN, ^monitor, :process, _pid, _reason} -> :remove
      {:EXIT, _from, _reason} -> :remove
    end
  end

  # The reason is an operating-system error name. No path is logged.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, _file} ->
        Logger.warning(
          "signed audit export: a temporary directory could not be removed: #{inspect(reason)}"
        )

        :error
    end
  end

  defp await(guard, tag) do
    monitor = Process.monitor(guard)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        with {:ok, path} <- result, do: {:ok, %{path: path, guard: guard}}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, :no_guard}
    end
  end

  defp create do
    with {:ok, root} <- prepared_root(), do: Writer.create_tmp_dir(root)
  end

  # The root to create a directory in. The default one is made when missing.
  defp prepared_root do
    case root() do
      {:configured, root} -> {:ok, root}
      {:default, root} -> prepare_default(root)
      nil -> {:error, :no_root}
    end
  end

  # The root to sweep. The sweep never makes one.
  defp existing_root do
    case root() do
      {:configured, root} -> {:ok, root}
      {:default, root} -> with :ok <- own_directory(root), do: {:ok, root}
      nil -> {:error, :no_root}
    end
  end

  # The root comes from the application config or the operating system, never
  # from a request.
  defp root do
    case :kanban |> Application.get_env(SignedExport, []) |> Keyword.get(:tmp_root) do
      root when is_binary(root) -> {:configured, root}
      _unset -> default_root(System.tmp_dir())
    end
  end

  defp default_root(nil), do: nil
  defp default_root(tmp_dir), do: {:default, Path.join(tmp_dir, @default_dir)}

  # The mode is set only once the root is known to be this user's own
  # directory, so chmod never follows a symlink another user planted.
  # sobelow_skip ["Traversal.FileModule"]
  defp prepare_default(root) do
    with :ok <- mkdir(root),
         :ok <- own_directory(root),
         :ok <- File.chmod(root, 0o700) do
      {:ok, root}
    else
      _not_ours -> {:error, :no_root}
    end
  end

  defp own_directory(path) do
    with {:ok, uid} <- own_uid(),
         true <- owned_directory?(path, uid) do
      :ok
    else
      _not_ours -> {:error, :no_root}
    end
  end

  @doc false
  # Whether `path` is a real directory owned by the operating-system user
  # `uid`. lstat does not follow a symlink planted under the name, and in a
  # sticky directory nobody else can replace an entry this user owns.
  @spec owned_directory?(String.t(), non_neg_integer()) :: boolean()
  # sobelow_skip ["Traversal.FileModule"]
  def owned_directory?(path, uid) do
    match?({:ok, %File.Stat{type: :directory, uid: ^uid}}, File.lstat(path))
  end

  # The operating-system user this VM runs as: the owner of a directory it
  # has just created. Erlang has no call that returns it.
  # sobelow_skip ["Traversal.FileModule"]
  defp own_uid do
    with {:ok, probe} <- Writer.create_tmp_dir(System.tmp_dir()) do
      stat = File.lstat(probe)
      File.rmdir(probe)

      with {:ok, %File.Stat{uid: uid}} <- stat, do: {:ok, uid}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir(root) do
    case File.mkdir(root) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The shape Writer.create_tmp_dir/1 gives a name.
  defp dir_name?(name), do: Regex.match?(~r/\A\.tmp-[A-Za-z0-9_-]{22}\z/, name)

  # sobelow_skip ["Traversal.FileModule"]
  defp remove_if_stale(root, name) do
    path = Path.join(root, name)

    with true <- dir_name?(name),
         {:ok, %File.Stat{type: :directory, mtime: changed}} <- File.lstat(path, time: :posix),
         true <- System.os_time(:second) - changed > @stale_after_seconds do
      remove(path) == :ok
    else
      _keep -> false
    end
  end
end
