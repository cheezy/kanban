defmodule Kanban.Workspaces.Export do
  @moduledoc """
  Org-admin exports of an Organization workspace (W2222).

  An export is a zip of the workspace's boards, columns, labels, tasks,
  comments, task history and board and workspace memberships, in the format
  owned by `Kanban.Workspaces.Export.Serializer`. Requesting one records a
  pending `Kanban.Workspaces.Export.WorkspaceExport` row and enqueues
  `Kanban.Workspaces.Export.Worker`, which writes the archive in the
  background, so no request ever waits for it. Status changes are broadcast on
  `topic/1`; the in-app list is the only delivery channel.

  `request_export/2`, `list_exports/2` and `get_export_for_download/2`
  re-read the caller and the workspace from the database and require an
  enabled org-admin of the workspace's Organization
  (`Kanban.Workspaces.Policy.can_manage_workspace?/2`). Personal workspaces
  have no export. `subscribe/1`, `topic/1`, `export_dir/0`, `retention_days/0`
  and `safe_path?/1` check no one: call `subscribe/1` only after that policy
  check has passed, as the settings LiveView does. Its messages carry no export
  details. A download is looked up by export id and re-authorized
  against the export's own workspace on every call, and its file path comes
  only from the row, which only the worker writes; a path outside
  `export_dir/0` is refused as not found.

  Archives are kept for `retention_days/0` days on the disk of the machine
  that wrote them (a deployment with more than one machine shares
  `export_dir/0` between them); the hourly
  `Kanban.Workspaces.Export.CleanupWorker` deletes expired files.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Repo
  alias Kanban.Workspaces.Export.Worker
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Policy
  alias Kanban.Workspaces.Workspace

  @retention_days 7
  @list_limit 10
  @max_bigint 9_223_372_036_854_775_807

  @doc "How many days a finished archive stays downloadable."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc """
  The directory archives are written to: `config :kanban, :export_dir`, or a
  `stride_exports` directory under the system temp directory. Expanded.
  """
  @spec export_dir() :: String.t()
  def export_dir do
    case Application.get_env(:kanban, :export_dir) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _unset -> System.tmp_dir!() |> Path.join("stride_exports") |> Path.expand()
    end
  end

  @doc "The PubSub topic carrying export status changes for a workspace."
  @spec topic(integer()) :: String.t()
  def topic(workspace_id) when is_integer(workspace_id), do: "workspace_exports:#{workspace_id}"

  @doc """
  Subscribes the caller to export status changes of the workspace. Messages
  are `{Kanban.Workspaces.Export, :export_updated, workspace_id}` and carry no
  export details; re-read them with `list_exports/2`. Not authorized: call it
  only after `Kanban.Workspaces.Policy.can_manage_workspace?/2` has passed.
  """
  @spec subscribe(integer()) :: :ok | {:error, term()}
  def subscribe(workspace_id), do: Phoenix.PubSub.subscribe(Kanban.PubSub, topic(workspace_id))

  @doc """
  Requests an export of `workspace` as `actor`: records a pending export and
  enqueues its job, both or neither.

  Returns `{:error, :unauthorized}` unless `actor` is an enabled org-admin of
  the workspace's Organization, and `{:error, :already_running}` while another
  export of the workspace is pending or running.

  ## Examples

      iex> request_export(org_admin, workspace)
      {:ok, %WorkspaceExport{status: "pending"}}

      iex> request_export(member, workspace)
      {:error, :unauthorized}

  """
  @spec request_export(User.t(), Workspace.t()) ::
          {:ok, WorkspaceExport.t()} | {:error, :unauthorized | :already_running | :export_failed}
  def request_export(%User{} = actor, %Workspace{} = workspace) do
    with {:ok, actor, workspace} <- fetch_managed(actor, workspace) do
      actor
      |> insert_export(workspace)
      |> tap(fn
        {:ok, export} -> broadcast(export.workspace_id)
        _error -> :ok
      end)
    end
  end

  defp insert_export(actor, workspace) do
    Repo.transaction(fn ->
      case Repo.insert(WorkspaceExport.create_changeset(workspace.id, actor.id)) do
        {:ok, export} -> enqueue(export)
        {:error, _changeset} -> Repo.rollback(:already_running)
      end
    end)
  end

  defp enqueue(export) do
    %{"export_id" => export.id, "workspace_id" => export.workspace_id}
    |> Worker.new()
    |> Oban.insert()
    |> case do
      {:ok, %Oban.Job{conflict?: true}} -> Repo.rollback(:already_running)
      {:ok, _job} -> export
      {:error, _reason} -> Repo.rollback(:export_failed)
    end
  end

  @doc """
  The workspace's most recent exports, newest first, with the requester
  preloaded — or `[]` unless `actor` is an enabled org-admin of the
  workspace's Organization.
  """
  @spec list_exports(User.t(), Workspace.t()) :: [WorkspaceExport.t()]
  def list_exports(%User{} = actor, %Workspace{} = workspace) do
    case fetch_managed(actor, workspace) do
      {:ok, _actor, workspace} ->
        workspace.id
        |> recent_exports_query()
        |> Repo.all()

      {:error, :unauthorized} ->
        []
    end
  end

  defp recent_exports_query(workspace_id) do
    from e in WorkspaceExport,
      where: e.workspace_id == ^workspace_id,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: @list_limit,
      preload: [:requested_by]
  end

  @doc """
  Returns the export with `id` when `actor` may download it now: `actor` is an
  enabled org-admin of the export's workspace's Organization, the export
  succeeded, has not expired, and its file passes `servable_file?/1`. Everything else — another workspace's export, a member, a
  former org-admin, a pending, failed or expired export, a missing file or a
  malformed id — is `{:error, :not_found}`.
  """
  @spec get_export_for_download(User.t(), term()) ::
          {:ok, WorkspaceExport.t()} | {:error, :not_found}
  def get_export_for_download(%User{} = actor, id) do
    with %WorkspaceExport{} = export <- get_export(id),
         {:ok, _actor, workspace} <- fetch_managed(actor, %Workspace{id: export.workspace_id}),
         true <- downloadable?(export) do
      {:ok, %{export | workspace: workspace}}
    else
      _ -> {:error, :not_found}
    end
  end

  # nil for a malformed id or an unknown export.
  defp get_export(id) do
    case parse_id(id) do
      id when is_integer(id) -> Repo.get(WorkspaceExport, id)
      nil -> nil
    end
  end

  defp downloadable?(
         %WorkspaceExport{status: "succeeded", expires_at: %DateTime{} = expires_at} = export
       ) do
    DateTime.after?(expires_at, DateTime.utc_now()) and servable_file?(export.file_path)
  end

  defp downloadable?(_export), do: false

  @doc """
  True when `path` is a file path inside `export_dir/0`. Anything else,
  including a path that climbs out with `..`, is false.
  """
  @spec safe_path?(term()) :: boolean()
  def safe_path?(path) when is_binary(path) and path != "" do
    path
    |> Path.expand()
    |> String.starts_with?(export_dir() <> "/")
  end

  def safe_path?(_path), do: false

  @max_link_hops 40

  @doc """
  True when `path` may be served as a download: it passes `safe_path?/1`, it
  is itself a regular file and not a symlink, and its real path — every
  symlink along the way resolved — is still inside the real `export_dir/0`.
  A symlink planted inside the export directory, or a symlinked directory
  under it, therefore never serves a file from elsewhere.
  """
  @spec servable_file?(term()) :: boolean()
  def servable_file?(path) do
    with true <- safe_path?(path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, real_file} <- real_path(path),
         {:ok, real_dir} <- real_path(export_dir()) do
      String.starts_with?(real_file, real_dir <> "/")
    else
      _ -> false
    end
  end

  @doc """
  Returns the absolute path `path` names with every symlink resolved, or
  `{:error, :too_many_links}` for a symlink loop. A component that does not
  exist is kept as it is.
  """
  @spec real_path(String.t()) :: {:ok, String.t()} | {:error, :too_many_links}
  def real_path(path) when is_binary(path) do
    [root | parts] = path |> Path.absname() |> Path.split()
    resolve(parts, root, 0)
  end

  defp resolve(_parts, _resolved, hops) when hops > @max_link_hops,
    do: {:error, :too_many_links}

  defp resolve([], resolved, _hops), do: {:ok, resolved}
  defp resolve(["." | rest], resolved, hops), do: resolve(rest, resolved, hops)

  # `resolved` holds no symlink, so its parent is the real parent.
  defp resolve([".." | rest], resolved, hops),
    do: resolve(rest, Path.dirname(resolved), hops)

  defp resolve([part | rest], resolved, hops) do
    candidate = Path.join(resolved, part)

    case :file.read_link_all(candidate) do
      {:ok, target} ->
        [root | target_parts] = target |> to_string() |> Path.absname(resolved) |> Path.split()
        resolve(target_parts ++ rest, root, hops + 1)

      {:error, _not_a_link} ->
        resolve(rest, candidate, hops)
    end
  end

  # Re-reads the actor and the workspace, so a role change, a disabled
  # account or another Organization's workspace is seen at once.
  defp fetch_managed(%User{id: user_id}, %Workspace{id: workspace_id}) do
    with %User{} = actor <- get_enabled_user(user_id),
         %Workspace{} = workspace <- get_organization_workspace(workspace_id),
         true <- Policy.can_manage_workspace?(actor, workspace) do
      {:ok, actor, workspace}
    else
      _ -> {:error, :unauthorized}
    end
  end

  # nil for an unknown or disabled user.
  defp get_enabled_user(user_id) do
    case Accounts.get_user(user_id) do
      %User{disabled_at: nil} = user -> user
      _missing_or_disabled -> nil
    end
  end

  # nil for a malformed id, an unknown workspace or a personal workspace.
  defp get_organization_workspace(workspace_id) do
    case parse_id(workspace_id) do
      id when is_integer(id) -> get_non_personal_workspace(id)
      nil -> nil
    end
  end

  defp get_non_personal_workspace(id) do
    case Repo.get(Workspace, id) do
      %Workspace{personal: false} = workspace -> workspace
      _missing_or_personal -> nil
    end
  end

  @doc false
  # Worker side: pending -> running. :skip when the export already moved on.
  @spec mark_running(WorkspaceExport.t()) :: {:ok, WorkspaceExport.t()} | :skip
  def mark_running(%WorkspaceExport{} = export),
    do: transition(export, ["pending", "running"], status: "running")

  @doc false
  @spec mark_succeeded(WorkspaceExport.t(), String.t(), non_neg_integer()) ::
          {:ok, WorkspaceExport.t()} | :skip
  def mark_succeeded(%WorkspaceExport{} = export, path, byte_size) do
    now = now()

    transition(export, ["running"],
      status: "succeeded",
      file_path: path,
      byte_size: byte_size,
      completed_at: now,
      expires_at: DateTime.add(now, @retention_days, :day),
      error: nil
    )
  end

  @doc false
  @spec mark_failed(WorkspaceExport.t(), String.t()) :: {:ok, WorkspaceExport.t()} | :skip
  def mark_failed(%WorkspaceExport{} = export, code) when is_binary(code) do
    code = if code in WorkspaceExport.error_codes(), do: code, else: "export_failed"

    transition(export, ["pending", "running"],
      status: "failed",
      error: code,
      completed_at: now(),
      file_path: nil
    )
  end

  @doc false
  @spec mark_expired(WorkspaceExport.t()) :: {:ok, WorkspaceExport.t()} | :skip
  def mark_expired(%WorkspaceExport{} = export),
    do: transition(export, ["succeeded"], status: "expired", file_path: nil)

  # A conditional update, so a transition only happens from the states it is
  # allowed from even when the worker and the cleanup race.
  defp transition(%WorkspaceExport{id: id}, from, changes) do
    changes = Keyword.put(changes, :updated_at, now())

    from(e in WorkspaceExport, where: e.id == ^id and e.status in ^from, select: e)
    |> Repo.update_all(set: changes)
    |> case do
      {1, [export]} ->
        broadcast(export.workspace_id)
        {:ok, export}

      {0, _} ->
        :skip
    end
  end

  defp broadcast(workspace_id) do
    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      topic(workspace_id),
      {__MODULE__, :export_updated, workspace_id}
    )
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
