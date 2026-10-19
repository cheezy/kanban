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

  @max_bigint 9_223_372_036_854_775_807

  @personal_workspace_name "Personal"
  @assignable_roles [:member, :guest]

  @typedoc "A workspace, or its id as an integer or a string from a URL or form."
  @type workspace_ref :: Workspace.t() | integer() | String.t()

  @type member_error ::
          :unauthorized | :invalid_role | :not_in_organization | :not_found | :archived

  @doc """
  Creates `user`'s personal workspace and its single owner row in one
  transaction.

  A user who already owns a workspace gets `{:error, changeset}` with an error
  on `:user_id`, and nothing is left behind — including when two calls race.
  Use `ensure_personal_workspace/1` when a concurrent first call is possible.

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
  Returns `user`'s personal workspace, creating it with its owner row when they
  have none yet. Calling it again returns the same workspace and creates
  nothing.

  A user who already has one gets it from a plain read, with no lock. A user
  who has none is serialized per user: the check and the create run in one
  transaction that first locks the user's own `users` row, so two concurrent
  calls cannot both create. The second waits for the first to commit, then
  finds its workspace and returns it. When called inside an enclosing
  transaction, such as a board create, the lock joins it and is held until
  that transaction commits or rolls back; nothing else is locked, so other
  users never wait. Retrying after a failed insert would not work here, since
  that insert would already have aborted the enclosing transaction; taking
  the lock first avoids the failure instead.

  ## Examples

      iex> ensure_personal_workspace(user)
      {:ok, %Workspace{personal: true}}

  """
  @spec ensure_personal_workspace(User.t()) ::
          {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def ensure_personal_workspace(%User{} = user) do
    case get_personal_workspace(user) do
      %Workspace{} = workspace -> {:ok, workspace}
      nil -> lock_and_ensure_personal_workspace(user)
    end
  end

  # Re-reads under the user's row lock, so a caller that waited sees the
  # workspace the winner committed (each statement takes a fresh snapshot
  # under READ COMMITTED). The lock key is the server-side user id.
  defp lock_and_ensure_personal_workspace(%User{} = user) do
    Repo.transaction(fn ->
      lock_user_row(user)

      case get_personal_workspace(user) do
        %Workspace{} = workspace -> workspace
        nil -> create_personal_workspace_or_rollback(user)
      end
    end)
  end

  defp create_personal_workspace_or_rollback(user) do
    case create_personal_workspace(user) do
      {:ok, workspace} -> workspace
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # NO KEY UPDATE conflicts with itself, so concurrent callers for one user
  # queue up, but not with the key-share locks that foreign-key checks take,
  # so inserts elsewhere that reference this user do not wait. A missing user
  # locks nothing; the owner row's foreign key then fails the create.
  defp lock_user_row(%User{id: user_id}) do
    from(u in User, where: u.id == ^user_id, select: u.id, lock: "FOR NO KEY UPDATE")
    |> Repo.one()
  end

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
  Deletes `user`'s personal workspace and its owner row.

  Returns `{:ok, nil}` when `user` has no personal workspace, and
  `{:error, :personal_workspace_has_boards}` when any board still belongs to
  it. The `boards.workspace_id` foreign key makes that refusal, so a board
  placed after a caller's own check is refused too, never stranded.

  Only the workspace `user` owns as personal is ever deleted, never an org
  workspace they are a member or guest of.

  Call it inside the transaction that deletes the user, before the user row
  goes: the owner row is deleted with the user, after which the workspace can
  no longer be found. A refusal leaves an enclosing transaction aborted, so
  roll back on any error.

  ## Examples

      iex> delete_personal_workspace(user)
      {:ok, %Workspace{personal: true}}

      iex> delete_personal_workspace(user_whose_workspace_holds_a_board)
      {:error, :personal_workspace_has_boards}

  """
  @spec delete_personal_workspace(User.t()) ::
          {:ok, Workspace.t() | nil} | {:error, :personal_workspace_has_boards}
  def delete_personal_workspace(%User{} = user) do
    case get_personal_workspace(user) do
      nil -> {:ok, nil}
      %Workspace{} = workspace -> delete_boardless_workspace(workspace)
    end
  end

  defp delete_boardless_workspace(workspace) do
    workspace
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.no_assoc_constraint(:boards)
    |> Repo.delete()
    |> case do
      {:ok, deleted} -> {:ok, deleted}
      {:error, %Ecto.Changeset{}} -> {:error, :personal_workspace_has_boards}
    end
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
  Archived workspaces are returned, and an `id` that is not a positive integer
  that fits the column (`nil`, `"abc"`, `"99999999999999999999"`) is `nil`.
  """
  @spec get_workspace(integer() | String.t() | nil, User.t()) :: Workspace.t() | nil
  def get_workspace(id, %User{} = actor) do
    with id when is_integer(id) <- parse_id(id),
         %Workspace{} = workspace <- Repo.get(Workspace, id),
         true <- reachable?(workspace, actor) do
      workspace
    else
      _ -> nil
    end
  end

  # Ecto.Type.cast(:id, _) accepts nil and integers past bigint, and Repo.get/2
  # raises on both, so a URL-supplied id is bounded here before it is queried.
  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil

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
  Returns the org workspaces `user` can reach, unarchived, by name ignoring case.

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
      order_by: [asc: fragment("lower(?)", w.name), asc: w.id]
    )
  end

  @doc """
  Returns `user`'s role on `workspace` from their member row — `:owner`,
  `:member` or `:guest` — or `nil` when they have no row. An org-admin's
  standing is not a row and is not reported here.

  `workspace` is a `%Workspace{}` or its id; an id that is not a positive
  integer that fits the column gives `nil`, as in `get_workspace/2`.
  """
  @spec get_member_role(workspace_ref() | nil, User.t()) ::
          WorkspaceMember.role() | nil
  def get_member_role(workspace, %User{id: user_id}) do
    case workspace_id(workspace) do
      nil ->
        nil

      workspace_id ->
        from(m in WorkspaceMember,
          where: m.workspace_id == ^workspace_id and m.user_id == ^user_id,
          select: m.role
        )
        |> Repo.one()
    end
  end

  @doc """
  Adds `user` to the org workspace `workspace` as a `:member` or `:guest`.

  `actor` must be an org-admin of the workspace's Organization, and `user` must
  belong to that Organization. The owner role is refused: org workspaces have
  no owner row. A personal workspace takes no members, and looks the same as
  one `actor` may not manage. An archived workspace takes no new members and
  returns `{:error, :archived}`.

  `workspace` is a `%Workspace{}` or its id; it is re-read from the database.
  An id that is not a positive integer that fits the column is refused like a
  missing workspace.

  ## Examples

      iex> add_member(org_admin, workspace, colleague, :member)
      {:ok, %WorkspaceMember{role: :member}}

      iex> add_member(org_admin, workspace, outsider, :guest)
      {:error, :not_in_organization}

  """
  @spec add_member(User.t(), workspace_ref(), User.t(), atom()) ::
          {:ok, WorkspaceMember.t()} | {:error, member_error() | Ecto.Changeset.t()}
  def add_member(%User{} = actor, workspace, %User{} = user, role) do
    with :ok <- check_assignable_role(role),
         {:ok, workspace} <- fetch_managed_workspace(actor, workspace),
         :ok <- check_not_archived(workspace),
         :ok <- check_in_organization(user, workspace) do
      workspace.id
      |> WorkspaceMember.changeset(user.id, role)
      |> Repo.insert()
    end
  end

  @doc """
  Changes `user`'s role on the org workspace `workspace` to `:member` or
  `:guest`. `actor` must be an org-admin of its Organization.

  `workspace` is a `%Workspace{}` or its id; it is re-read from the database,
  and an id that cannot name a row is refused like a missing workspace.
  """
  @spec update_member_role(User.t(), workspace_ref(), User.t(), atom()) ::
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

  `workspace` is a `%Workspace{}` or its id; it is re-read from the database,
  and an id that cannot name a row is refused like a missing workspace.
  """
  @spec remove_member(User.t(), workspace_ref(), User.t()) ::
          {:ok, WorkspaceMember.t()} | {:error, member_error() | Ecto.Changeset.t()}
  def remove_member(%User{} = actor, workspace, %User{} = user) do
    with {:ok, workspace} <- fetch_managed_workspace(actor, workspace),
         {:ok, membership} <- fetch_membership(workspace, user) do
      Repo.delete(membership)
    end
  end

  defp check_assignable_role(role) when role in @assignable_roles, do: :ok
  defp check_assignable_role(_role), do: {:error, :invalid_role}

  # Role changes and removals stay allowed on an archived workspace, so its
  # members can still be tidied up; only new members are refused.
  defp check_not_archived(%Workspace{archived_at: nil}), do: :ok
  defp check_not_archived(%Workspace{}), do: {:error, :archived}

  # The workspace is re-read so a stale or hand-built struct cannot point the
  # check at another Organization. A missing workspace, a personal one, and one
  # whose Organization `actor` is not an org-admin of all give the same error,
  # and so does an id that cannot name a row.
  defp fetch_managed_workspace(actor, workspace) do
    case get_by_id(workspace_id(workspace)) do
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

  defp get_by_id(nil), do: nil
  defp get_by_id(id), do: Repo.get(Workspace, id)

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(id), do: parse_id(id)
end
