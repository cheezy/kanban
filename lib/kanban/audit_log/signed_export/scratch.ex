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

  The guard and the sweep are `Kanban.TmpDirGuard`'s, shared with the
  workspace export. Nothing here logs a path.
  """

  alias Kanban.AuditLog.SignedExport
  alias Kanban.TmpDirGuard
  alias Kanban.Workspaces.Export.Writer

  @default_dir "stride-signed-exports"
  @stale_after_seconds 3600
  @label "signed audit export"

  @typedoc "A checked-out directory: its path and the guard that watches it."
  @type t :: TmpDirGuard.t()

  @doc """
  Creates a new temporary directory and starts the guard that removes it if
  the calling process dies. Returns `{:error, reason}` when there is no
  usable root or the directory cannot be created; nothing is left behind.
  """
  @spec checkout() :: {:ok, t()} | {:error, atom()}
  def checkout, do: TmpDirGuard.checkout(&create/0, @label)

  @doc """
  Removes the directory and stops its guard. The directory is gone when this
  returns, unless the operating system refuses the removal, which is logged.
  """
  @spec release(t()) :: :ok
  def release(scratch), do: TmpDirGuard.release(scratch, @label)

  @doc """
  Removes the directories left in the root by a VM that was killed during a
  signed export: those named like one of this module's directories whose
  last change is more than an hour old. Returns how many it removed; one the
  operating system refuses to remove is logged and not counted. Never raises;
  a root that does not exist yet holds nothing to remove.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    case existing_root() do
      {:ok, root} -> TmpDirGuard.sweep(root, @stale_after_seconds, @label)
      _no_root -> 0
    end
  end

  # Runs in the guard process, which creates the directory once it is
  # monitoring the owner.
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
    with {:ok, uid} <- TmpDirGuard.own_uid(),
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

  # sobelow_skip ["Traversal.FileModule"]
  defp mkdir(root) do
    case File.mkdir(root) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
