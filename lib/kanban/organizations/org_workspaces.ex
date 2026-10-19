defmodule Kanban.Organizations.OrgWorkspaces do
  @moduledoc """
  The org-admin's management of their Organization's workspaces, behind the
  Workspaces section of the org console at `/org`.

  An org workspace has `personal` false, an `organization_id` and no owner row:
  the Organization owns it (D3). The schema and its changesets live in
  `Kanban.Workspaces.Workspace`; this module only decides who may create,
  rename and archive one, and reports each change.

  Every function reads the actor's org-admin role from the database on each
  call, never from a scope loaded earlier, so an org-admin removed while the
  console is open is refused on their next action.

  A workspace id is always looked up inside the actor's own Organization. An id
  that does not exist, belongs to another Organization, names a personal
  workspace or names an archived one all return `{:error, :not_found}` and
  change nothing, so ids cannot be probed. A caller who is not an org-admin at
  all gets `{:error, :unauthorized}`.

  Within one Organization no two unarchived workspaces share a name, compared
  ignoring case; a database index decides (see `Kanban.Workspaces.Workspace`).
  A clash on `create_workspace/3` or `rename_workspace/3` returns
  `{:error, changeset}` with "has already been taken" on `:name`, and emits and
  records nothing. Archiving a workspace frees its name, and a rename changes
  the name only, never the slug.

  Every successful change emits a `[:kanban, :organization, :workspace_*]`
  telemetry event and records the matching audit event through
  `Kanban.Organizations.OrganizationTelemetry`; a refused or invalid one emits
  and records nothing.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.OrganizationTelemetry
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace

  @max_bigint 9_223_372_036_854_775_807

  @type error :: :unauthorized | :not_found | :workspace_has_boards

  @doc """
  Returns the unarchived workspaces of `organization_id`, by name ignoring
  case, when `actor` is one of its org-admins; otherwise `[]`. Personal and archived workspaces are
  never returned.
  """
  @spec list_workspaces(User.t(), integer()) :: [Workspace.t()]
  def list_workspaces(%User{} = actor, organization_id) when is_integer(organization_id) do
    if Organizations.org_admin?(actor, organization_id) do
      from(w in Workspace,
        where:
          w.organization_id == ^organization_id and w.personal == false and
            is_nil(w.archived_at),
        order_by: [asc: fragment("lower(?)", w.name), asc: w.id]
      )
      |> Repo.all()
    else
      []
    end
  end

  @doc """
  Returns a changeset for the create and rename forms. It is never saved.
  """
  @spec change_workspace(Workspace.t(), map()) :: Changeset.t()
  def change_workspace(%Workspace{} = workspace \\ %Workspace{}, attrs \\ %{}) do
    Workspace.changeset(workspace, attrs)
  end

  @doc """
  Creates a workspace owned by `organization_id`, with `personal` false and no
  owner row. Only `:name` is read from `attrs`.

  `actor` must be an org-admin of that Organization.

  ## Examples

      iex> create_workspace(org_admin, organization.id, %{"name" => "Design"})
      {:ok, %Workspace{personal: false}}

      iex> create_workspace(member, organization.id, %{"name" => "Design"})
      {:error, :unauthorized}

  """
  @spec create_workspace(User.t(), integer(), map()) ::
          {:ok, Workspace.t()} | {:error, :unauthorized | Changeset.t()}
  def create_workspace(%User{} = actor, organization_id, attrs)
      when is_integer(organization_id) and is_map(attrs) do
    if Organizations.org_admin?(actor, organization_id) do
      attrs
      |> name_attrs()
      |> Workspace.create_changeset(false, organization_id)
      |> Repo.insert()
      |> OrganizationTelemetry.workspace_created(actor)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Renames the unarchived workspace `workspace_id` of `actor`'s Organization.
  Only `:name` is read from `attrs`. A rename to the same name saves nothing and
  reports nothing.

  ## Examples

      iex> rename_workspace(org_admin, workspace.id, %{"name" => "Research"})
      {:ok, %Workspace{name: "Research"}}

      iex> rename_workspace(org_admin, other_orgs_workspace.id, %{"name" => "Mine"})
      {:error, :not_found}

  """
  @spec rename_workspace(User.t(), integer() | String.t(), map()) ::
          {:ok, Workspace.t()} | {:error, :unauthorized | :not_found | Changeset.t()}
  def rename_workspace(%User{} = actor, workspace_id, attrs) when is_map(attrs) do
    with {:ok, organization_id} <- org_admin_organization_id(actor),
         {:ok, workspace} <- fetch_workspace(workspace_id, organization_id) do
      changeset = Workspace.changeset(workspace, name_attrs(attrs))

      changeset
      |> Repo.update()
      |> OrganizationTelemetry.workspace_renamed(changeset, actor)
    end
  end

  @doc """
  Archives the unarchived workspace `workspace_id` of `actor`'s Organization by
  setting `archived_at`.

  It is refused with `{:error, :workspace_has_boards}` while any board still
  belongs to the workspace. The workspace row is locked while boards are
  counted, so a board cannot be moved into it between the check and the
  archive.

  ## Examples

      iex> archive_workspace(org_admin, empty_workspace.id)
      {:ok, %Workspace{archived_at: %DateTime{}}}

      iex> archive_workspace(org_admin, workspace_with_boards.id)
      {:error, :workspace_has_boards}

  """
  @spec archive_workspace(User.t(), integer() | String.t()) ::
          {:ok, Workspace.t()} | {:error, error() | Changeset.t()}
  def archive_workspace(%User{} = actor, workspace_id) do
    with {:ok, organization_id} <- org_admin_organization_id(actor) do
      fn -> archive_locked(workspace_id, organization_id) end
      |> Repo.transaction()
      |> OrganizationTelemetry.workspace_archived(actor)
    end
  end

  # Only the name is ever read from caller params, under a string key, so a map
  # mixing atom and string keys cannot make the cast raise.
  defp name_attrs(%{"name" => name}), do: %{"name" => name}
  defp name_attrs(%{name: name}), do: %{"name" => name}
  defp name_attrs(_attrs), do: %{}

  defp archive_locked(workspace_id, organization_id) do
    with {:ok, workspace} <- fetch_workspace(workspace_id, organization_id, lock: true),
         :ok <- check_no_boards(workspace),
         {:ok, archived} <- workspace |> archive_changeset() |> Repo.update() do
      archived
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp archive_changeset(workspace) do
    Changeset.change(workspace, archived_at: DateTime.utc_now(:second))
  end

  defp check_no_boards(%Workspace{id: workspace_id}) do
    if Board |> where([b], b.workspace_id == ^workspace_id) |> Repo.exists?(),
      do: {:error, :workspace_has_boards},
      else: :ok
  end

  # The actor's Organization comes from their own membership, read from the
  # database on every call.
  defp org_admin_organization_id(actor) do
    case Organizations.get_membership(actor) do
      %OrganizationMember{role: :org_admin, organization_id: organization_id} ->
        {:ok, organization_id}

      _not_an_org_admin ->
        {:error, :unauthorized}
    end
  end

  # A malformed, out-of-range, unknown, foreign, personal or archived id all
  # give the same answer.
  defp fetch_workspace(workspace_id, organization_id, opts \\ []) do
    with id when is_integer(id) <- parse_id(workspace_id),
         %Workspace{} = workspace <- workspace_query(id, organization_id, opts) |> Repo.one() do
      {:ok, workspace}
    else
      _ -> {:error, :not_found}
    end
  end

  defp workspace_query(id, organization_id, opts) do
    query =
      from(w in Workspace,
        where:
          w.id == ^id and w.organization_id == ^organization_id and w.personal == false and
            is_nil(w.archived_at)
      )

    if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query
  end

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
