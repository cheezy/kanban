defmodule Kanban.TmpDirGuard do
  @moduledoc """
  A temporary directory that is removed however the process using it ends,
  and a sweep of the ones a killed VM left behind.

  Used by `Kanban.AuditLog.SignedExport.Scratch` and
  `Kanban.Workspaces.Export.Writer`, whose directories hold exported data.

  ## Who removes a directory

    * **The owner.** `release/2` removes the directory. Callers run it in an
      `after` clause, so it runs when their work returns, raises or throws.
    * **A guard process.** An `after` clause does not run when the owner is
      ended by an exit signal: a request process killed because its
      connection closed, an Oban job killed at shutdown. So `checkout/3`
      starts a guard under a task supervisor (`Kanban.TaskSupervisor` by
      default). The guard monitors the owner first and only then creates the
      directory, through the function it is given, so no directory ever
      exists unwatched. It removes the directory when the owner goes down,
      however it ends, and when the supervisor stops the guard itself.
    * **A sweep.** A killed VM runs neither of the above. `sweep/4` removes
      the directories of a root that are named like one made by
      `Kanban.Workspaces.Export.Writer.create_tmp_dir/1` and older than a
      threshold. It reads each entry with lstat, so it never follows a
      symlink. Given an `:owner`, it sweeps only a root that is a real
      directory of that user with no group or other write permission, and
      only entries that user owns: in a root another user can write to, that
      user could plant a tree and swap a symlink into it while it is removed.

  The operating system can refuse a removal, for example when the root has
  lost its write permission. Each refusal is logged as a warning, with the
  caller's label and the error name.

  Nothing here logs a path.
  """

  alias Kanban.Workspaces.Export.Writer

  require Logger

  @typedoc "A checked-out directory: its path and the guard that watches it."
  @type t :: %{path: String.t(), guard: pid()}

  @typedoc "Creates the directory and returns its path."
  @type create_fun :: (-> {:ok, String.t()} | {:error, term()})

  @doc """
  Starts a guard that creates a directory with `create` and removes it when
  the calling process dies. `label` starts every log line about it.

  Returns the error `create` gives when it fails, and `{:error, :no_guard}`
  when the guard cannot be started or dies before answering; nothing is left
  behind either way. `:supervisor` names the task supervisor to start the
  guard under (default `Kanban.TaskSupervisor`).
  """
  @spec checkout(create_fun(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def checkout(create, label, opts \\ []) when is_function(create, 0) and is_binary(label) do
    supervisor = Keyword.get(opts, :supervisor, Kanban.TaskSupervisor)
    owner = self()
    tag = make_ref()

    case Task.Supervisor.start_child(supervisor, fn -> guard(owner, tag, create, label) end) do
      {:ok, guard} -> await(guard, tag)
      _not_started -> {:error, :no_guard}
    end
  end

  @doc """
  Removes the directory and stops its guard. The directory is gone when this
  returns, unless the operating system refuses the removal, which is logged.
  """
  @spec release(t(), String.t()) :: :ok
  def release(%{path: path, guard: guard}, label) when is_binary(label) do
    remove(path, label)
    send(guard, :released)
    :ok
  end

  @doc """
  Removes the entries of `root` named like a directory made by
  `Kanban.Workspaces.Export.Writer.create_tmp_dir/1` that are real
  directories, not symlinks, last changed more than `threshold_seconds` ago.
  Returns how many it removed and logs that count when it is not zero; one
  the operating system refuses to remove is logged and not counted. Never
  raises; a root that does not exist holds nothing to remove.

  With `owner: uid` (see `own_uid/0`) the root must be a real directory that
  `uid` owns with no group or other write permission, or nothing is swept
  and a warning is logged; and only entries `uid` owns are removed.
  """
  @spec sweep(String.t(), non_neg_integer(), String.t(), keyword()) :: non_neg_integer()
  # sobelow_skip ["Traversal.FileModule"]
  def sweep(root, threshold_seconds, label, opts \\ [])
      when is_binary(root) and is_integer(threshold_seconds) and threshold_seconds >= 0 and
             is_binary(label) do
    sweep_root(root, threshold_seconds, label, Keyword.get(opts, :owner))
  end

  @doc """
  The operating-system user this VM runs as: the owner of a directory it has
  just created in `System.tmp_dir/0` and removed again. Erlang has no call
  that returns it.
  """
  @spec own_uid() :: {:ok, non_neg_integer()} | {:error, term()}
  def own_uid, do: own_uid(System.tmp_dir())

  defp own_uid(nil), do: {:error, :no_tmp_dir}

  # sobelow_skip ["Traversal.FileModule"]
  defp own_uid(tmp_dir) do
    with {:ok, probe} <- Writer.create_tmp_dir(tmp_dir) do
      stat = File.lstat(probe)
      File.rmdir(probe)

      with {:ok, %File.Stat{uid: uid}} <- stat, do: {:ok, uid}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sweep_root(root, threshold_seconds, label, owner) do
    with :ok <- sweepable_root(root, owner, label),
         {:ok, names} <- File.ls(root) do
      names
      |> Enum.count(&remove_if_stale(root, &1, threshold_seconds, owner, label))
      |> report(label)
    else
      _nothing_to_sweep -> 0
    end
  end

  defp sweepable_root(_root, nil, _label), do: :ok

  # lstat, so a symlink planted under the root's name is refused, not
  # followed.
  # sobelow_skip ["Traversal.FileModule"]
  defp sweepable_root(root, owner, label) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, uid: ^owner, mode: mode}}
      when Bitwise.band(mode, 0o022) == 0 ->
        :ok

      {:error, :enoent} ->
        :missing

      _not_owner_only ->
        Logger.warning(
          "#{label}: the temporary directory root is not an owner-only directory " <>
            "of this user, so nothing was swept"
        )

        :refused
    end
  end

  defp report(0, _label), do: 0

  # A count only: a killed VM left exported data on disk, which an operator
  # should hear about, without a path.
  defp report(removed, label) do
    Logger.warning("#{label}: removed #{removed} stale temporary directories")
    removed
  end

  # The guard creates the directory itself, after it has started to monitor
  # the owner, so there is no moment when a directory exists unwatched.
  # sobelow_skip ["Traversal.FileModule"]
  defp guard(owner, tag, create, label) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)

    case create.() do
      {:ok, path} ->
        send(owner, {tag, {:ok, path}})
        if wait(monitor) == :remove, do: remove(path, label)

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
  defp remove(path, label) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        :ok

      {:error, reason, _file} ->
        Logger.warning("#{label}: a temporary directory could not be removed: #{inspect(reason)}")

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

  # The shape Writer.create_tmp_dir/1 gives a name. It holds no "/" and is
  # never "." or "..", so Path.join(root, name) stays inside root.
  defp dir_name?(name), do: Regex.match?(~r/\A\.tmp-[A-Za-z0-9_-]{22}\z/, name)

  # lstat reports a symlink as a symlink, so one named like a scratch
  # directory is kept, and nothing it points at is touched. With an owner, a
  # directory another user made is kept too.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_if_stale(root, name, threshold_seconds, owner, label) do
    path = Path.join(root, name)

    with true <- dir_name?(name),
         {:ok, %File.Stat{type: :directory, mtime: changed, uid: uid}} <-
           File.lstat(path, time: :posix),
         true <- owner in [nil, uid],
         true <- System.os_time(:second) - changed > threshold_seconds do
      remove(path, label) == :ok
    else
      _keep -> false
    end
  end
end
