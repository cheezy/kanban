defmodule Kanban.Workspaces do
  @moduledoc """
  Workspaces and their members.

  A workspace is either personal or owned by an Organization:

    * **Personal** — `personal` true, no Organization, exactly one `:owner`
      row. Every user can have one; it is never listed in the UI.
    * **Org workspace** — `personal` false, owned by an Organization, no owner
      row. The Organization's org-admins manage it; other people reach it
      through a `:member` or `:guest` row.

  Who belongs to which Organization, and who is its org-admin, is read only
  through `Kanban.Organizations`, never from `User.type` (which marks a site
  admin, a different thing). The role is checked on every call, not only in
  the UI.

  This module changes no board authorization; `Kanban.Boards.get_user_access/2`
  is untouched.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Kanban.Accounts.User
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @personal_workspace_name "Personal"
  @assignable_roles [:member, :guest]

  @type member_error :: :unauthorized | :invalid_role | :not_in_organization | :not_found

  @doc """
  Creates `user`'s personal workspace and its single owner row in one
  transaction.

  A user who already owns a workspace gets `{:error, changeset}` with an error
  on `:user_id`, and nothing is left behind — including when two calls race.

  ## Examples

      iex> create_personal_workspace(user)
      {:ok, %Workspace{personal: true}}

      iex> create_personal_workspace(user_with_a_personal_workspace)
      {:error, %Ecto.Changeset{}}

  """
  @spec create_personal_workspace(User.t()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def create_personal_workspace(%User{id: user_id}) do
    Multi.new()
    |> Multi.insert(
      :workspace,
      Workspace.create_changeset(%{name: @personal_workspace_name}, true, nil)
    )
    |> Multi.insert(:owner, fn %{workspace: workspace} ->
      WorkspaceMember.changeset(workspace.id, user_id, :owner)
    end)
    |> Repo.transaction()
    |> handle_personal_workspace_result()
  end

  defp handle_personal_workspace_result({:ok, %{workspace: workspace}}), do: {:ok, workspace}

  defp handle_personal_workspace_result({:error, _step, changeset, _changes}),
    do: {:error, changeset}

  @doc """
  Returns `user`'s personal workspace, or `nil` when they have none yet.
  """
  @spec get_personal_workspace(User.t()) :: Workspace.t() | nil
  def get_personal_workspace(%User{id: user_id}) do
    from(w in Workspace,
      join: m in assoc(w, :members),
      where: w.personal == true and m.user_id == ^user_id and m.role == ^:owner
    )
    |> Repo.one()
  end

  @doc """
  Creates a workspace for `actor`'s Organization.

  Only an org-admin may do this. The Organization comes from `actor`'s own
  membership; only `:name` is read from `attrs`, so an `organization_id`,
  `personal` or slug in them is ignored. No owner row is created.

  ## Examples

      iex> create_org_workspace(%{name: "Design"}, org_admin)
      {:ok, %Workspace{personal: false}}

      iex> create_org_workspace(%{name: "Design"}, member)
      {:error, :unauthorized}

  """
  @spec create_org_workspace(map(), User.t()) ::
          {:ok, Workspace.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_org_workspace(attrs, %User{} = actor) do
    case Organizations.get_membership(actor) do
      %OrganizationMember{role: :org_admin, organization_id: organization_id} ->
        attrs
        |> Workspace.create_changeset(false, organization_id)
        |> Repo.insert()

      _not_an_org_admin ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Returns the workspace with `id` when `actor` can reach it, else `nil`.

  `actor` reaches a personal workspace only as its owner, and an org workspace
  as an org-admin of its Organization or through a member or guest row. A
  workspace `actor` cannot reach looks exactly like one that does not exist.
  Archived workspaces are returned.
  """
  @spec get_workspace(integer() | String.t(), User.t()) :: Workspace.t() | nil
  def get_workspace(id, %User{} = actor) do
    with {:ok, id} <- Ecto.Type.cast(:id, id),
         %Workspace{} = workspace <- Repo.get(Workspace, id),
         true <- reachable?(workspace, actor) do
      workspace
    else
      _ -> nil
    end
  end

  defp reachable?(%Workspace{personal: true} = workspace, actor),
    do: get_member_role(workspace, actor) == :owner

  defp reachable?(%Workspace{organization_id: organization_id} = workspace, actor) do
    case Organizations.get_membership(actor) do
      %OrganizationMember{organization_id: ^organization_id, role: :org_admin} -> true
      %OrganizationMember{organization_id: ^organization_id} -> member_row?(workspace, actor)
      _other -> false
    end
  end

  defp member_row?(workspace, actor), do: get_member_role(workspace, actor) != nil

  @doc """
  Returns the org workspaces `user` can reach, unarchived, by name.

  An org-admin gets every unarchived workspace of their Organization; anyone
  else gets the ones they have a member or guest row on. A personal workspace is
  never returned, not even the user's own.
  """
  @spec list_workspaces_for_user(User.t()) :: [Workspace.t()]
  def list_workspaces_for_user(%User{} = user) do
    case Organizations.get_membership(user) do
      %OrganizationMember{role: :org_admin, organization_id: organization_id} ->
        organization_id |> org_workspaces_query() |> Repo.all()

      %OrganizationMember{organization_id: organization_id} ->
        organization_id
        |> org_workspaces_query()
        |> join(:inner, [w], m in assoc(w, :members), on: m.user_id == ^user.id)
        |> Repo.all()

      nil ->
        []
    end
  end

  defp org_workspaces_query(organization_id) do
    from(w in Workspace,
      where:
        w.organization_id == ^organization_id and w.personal == false and is_nil(w.archived_at),
      order_by: [asc: w.name, asc: w.id]
    )
  end

  @doc """
  Returns `user`'s role on `workspace` from their member row — `:owner`,
  `:member` or `:guest` — or `nil` when they have no row. An org-admin's
  standing is not a row and is not reported here.

  `workspace` is a `%Workspace{}` or its id.
  """
  @spec get_member_role(Workspace.t() | integer(), User.t()) :: WorkspaceMember.role() | nil
  def get_member_role(workspace, %User{id: user_id}) do
    workspace_id = workspace_id(workspace)

    from(m in WorkspaceMember,
      where: m.workspace_id == ^workspace_id and m.user_id == ^user_id,
      select: m.role
    )
    |> Repo.one()
  end

  @doc """
  Adds `user` to the org workspace `workspace` as a `:member` or `:guest`.

  `actor` must be an org-admin of the workspace's Organization, and `user` must
  belong to that Organization. The owner role is refused: org workspaces have
  no owner row. A personal workspace takes no members, and looks the same as
  one `actor` may not manage.

  `workspace` is a `%Workspace{}` or its id; it is re-read from the database.

  ## Examples

      iex> add_member(org_admin, workspace, colleague, :member)
      {:ok, %WorkspaceMember{role: :member}}

      iex> add_member(org_admin, workspace, outsider, :guest)
      {:error, :not_in_organization}

  """
  @spec add_member(User.t(), Workspace.t() | integer(), User.t(), atom()) ::
          {:ok, WorkspaceMember.t()} | {:error, member_error() | Ecto.Changeset.t()}
  def add_member(%User{} = actor, workspace, %User{} = user, role) do
    with :ok <- check_assignable_role(role),
         {:ok, workspace} <- fetch_managed_workspace(actor, workspace),
         :ok <- check_in_organization(user, workspace) do
      workspace.id
      |> WorkspaceMember.changeset(user.id, role)
      |> Repo.insert()
    end
  end

  @doc """
  Changes `user`'s role on the org workspace `workspace` to `:member` or
  `:guest`. `actor` must be an org-admin of its Organization.

  `workspace` is a `%Workspace{}` or its id; it is re-read from the database.
  """
  @spec update_member_role(User.t(), Workspace.t() | integer(), User.t(), atom()) ::
          {:ok, WorkspaceMember.t()} | {:error, member_error() | Ecto.Changeset.t()}
  def update_member_role(%User{} = actor, workspace, %User{} = user, role) do
    with :ok <- check_assignable_role(role),
         {:ok, workspace} <- fetch_managed_workspace(actor, workspace),
         {:ok, membership} <- fetch_membership(workspace, user) do
      membership
      |> WorkspaceMember.role_changeset(role)
      |> Repo.update()
    end
  end

  @doc """
  Removes `user` from the org workspace `workspace`. `actor` must be an
  org-admin of its Organization. A user who has since left the Organization can
  still be removed.

  `workspace` is a `%Workspace{}` or its id; it is re-read from the database.
  """
  @spec remove_member(User.t(), Workspace.t() | integer(), User.t()) ::
          {:ok, WorkspaceMember.t()} | {:error, member_error() | Ecto.Changeset.t()}
  def remove_member(%User{} = actor, workspace, %User{} = user) do
    with {:ok, workspace} <- fetch_managed_workspace(actor, workspace),
         {:ok, membership} <- fetch_membership(workspace, user) do
      Repo.delete(membership)
    end
  end

  defp check_assignable_role(role) when role in @assignable_roles, do: :ok
  defp check_assignable_role(_role), do: {:error, :invalid_role}

  # The workspace is re-read so a stale or hand-built struct cannot point the
  # check at another Organization. A missing workspace, a personal one, and one
  # whose Organization `actor` is not an org-admin of all give the same error.
  defp fetch_managed_workspace(actor, workspace) do
    case Repo.get(Workspace, workspace_id(workspace)) do
      %Workspace{personal: false, organization_id: organization_id} = workspace ->
        if Organizations.org_admin?(actor, organization_id),
          do: {:ok, workspace},
          else: {:error, :unauthorized}

      _missing_or_personal ->
        {:error, :unauthorized}
    end
  end

  defp check_in_organization(user, %Workspace{organization_id: organization_id}) do
    if Organizations.member?(user, organization_id),
      do: :ok,
      else: {:error, :not_in_organization}
  end

  defp fetch_membership(%Workspace{id: workspace_id}, %User{id: user_id}) do
    case Repo.get_by(WorkspaceMember, workspace_id: workspace_id, user_id: user_id) do
      %WorkspaceMember{} = membership -> {:ok, membership}
      nil -> {:error, :not_found}
    end
  end

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(id) when is_integer(id), do: id
end
