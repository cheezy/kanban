defmodule Kanban.Organizations do
  @moduledoc """
  Paying Organizations and their members.

  An Organization is created and edited only by an enabled site admin
  (`User.type` `:admin` with no `disabled_at`). That check runs here, inside
  the context, against both the actor struct and the actor's current database
  row, so a LiveView or controller that forgets it cannot let anyone else
  through, and an admin disabled mid-session is refused.

  A user belongs to at most one Organization, as an `:org_admin` or a
  `:member`. This module reads memberships; writing them belongs to the
  membership functions that build on it. There is deliberately no function to
  delete an Organization or to downgrade it.

  Creating and editing an Organization emits `[:kanban, :organization,
  :created]` and `:updated` and records the `:organization_created` and
  `:organization_updated` audit events, through
  `Kanban.Organizations.OrganizationTelemetry`, once the write has saved.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.OrganizationTelemetry
  alias Kanban.Repo

  @doc """
  Creates an Organization.

  `actor` must be an enabled site admin; anyone else gets
  `{:error, :unauthorized}` and nothing is written.

  ## Examples

      iex> create_organization(%{name: "Acme", contact_name: "Ada", contact_email: "ada@acme.test"}, admin)
      {:ok, %Organization{}}

      iex> create_organization(%{name: "Acme"}, user)
      {:error, :unauthorized}

  """
  @spec create_organization(map(), User.t()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def create_organization(attrs, %User{} = actor) do
    if site_admin?(actor) do
      %Organization{}
      |> Organization.changeset(attrs)
      |> Repo.insert()
      |> OrganizationTelemetry.created(actor)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Updates an Organization's details.

  `actor` must be an enabled site admin; anyone else gets
  `{:error, :unauthorized}` and nothing is written.

  ## Examples

      iex> update_organization(organization, %{city: "Toronto"}, admin)
      {:ok, %Organization{}}

      iex> update_organization(organization, %{city: "Toronto"}, user)
      {:error, :unauthorized}

  """
  @spec update_organization(Organization.t(), map(), User.t()) ::
          {:ok, Organization.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def update_organization(%Organization{} = organization, attrs, %User{} = actor) do
    if site_admin?(actor) do
      changeset = Organization.changeset(organization, attrs)

      changeset
      |> Repo.update()
      |> OrganizationTelemetry.updated(changeset, actor)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns every Organization, ordered by name, with `org_admin_count` and
  `member_count` filled in.

  `org_admin_count` counts members with role `:org_admin` and `member_count`
  those with role `:member`. Both come from the same single query.

  Organizations are listed only to an enabled site admin; anyone else gets
  `{:error, :unauthorized}`.

  ## Examples

      iex> list_organizations(admin)
      {:ok, [%Organization{org_admin_count: 1, member_count: 4}]}

  """
  @spec list_organizations(User.t()) :: {:ok, [Organization.t()]} | {:error, :unauthorized}
  def list_organizations(%User{} = actor) do
    if site_admin?(actor) do
      organizations =
        from(o in Organization,
          left_join: m in assoc(o, :members),
          group_by: o.id,
          order_by: [asc: o.name, asc: o.id],
          select_merge: %{
            org_admin_count: filter(count(m.id), m.role == ^:org_admin),
            member_count: filter(count(m.id), m.role == ^:member)
          }
        )
        |> Repo.all()

      {:ok, organizations}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns the Organization with `id`, or `nil`.

  The result includes the Organization's contact details, so it is returned
  only to an enabled site admin or to one of that Organization's org-admins.
  Anyone else gets `nil`, the same as for an id that does not exist.

  ## Examples

      iex> get_organization(organization.id, admin)
      %Organization{}

      iex> get_organization(organization.id, user)
      nil

  """
  @spec get_organization(integer() | String.t(), User.t()) :: Organization.t() | nil
  def get_organization(id, %User{} = actor) do
    case Repo.get(Organization, id) do
      %Organization{} = organization ->
        if site_admin?(actor) or org_admin?(actor, organization), do: organization

      nil ->
        nil
    end
  end

  @doc """
  Returns `user`'s membership with its Organization preloaded, or `nil` when
  the user belongs to no Organization.

  Any member, not only an org-admin, can reach this, so the preloaded
  Organization leaves out the contact name, phone and email (they are `nil`).
  Contact details come only from `get_organization/2`, which shows them to
  site admins and to that Organization's org-admins.

  ## Examples

      iex> get_membership(member)
      %OrganizationMember{organization: %Organization{}}

      iex> get_membership(free_user)
      nil

  """
  @spec get_membership(User.t()) :: OrganizationMember.t() | nil
  def get_membership(%User{id: user_id}) do
    OrganizationMember
    |> where([m], m.user_id == ^user_id)
    |> preload(organization: ^without_contact_query())
    |> Repo.one()
  end

  @doc """
  Returns true when `user` is an org-admin of `organization`.

  `organization` is an `%Organization{}` or its id.
  """
  @spec org_admin?(User.t(), Organization.t() | integer()) :: boolean()
  def org_admin?(%User{} = user, organization) do
    user
    |> membership_query(organization)
    |> where([m], m.role == ^:org_admin)
    |> Repo.exists?()
  end

  @doc """
  Returns true when `user` belongs to `organization` in either role.

  `organization` is an `%Organization{}` or its id.
  """
  @spec member?(User.t(), Organization.t() | integer()) :: boolean()
  def member?(%User{} = user, organization) do
    user
    |> membership_query(organization)
    |> Repo.exists?()
  end

  @doc """
  Returns `organization`'s memberships with each member's user preloaded,
  org-admins first and then by email.

  `organization` is an `%Organization{}` or its id. The caller decides who may
  see the list.
  """
  @spec list_members(Organization.t() | integer()) :: [OrganizationMember.t()]
  def list_members(organization) do
    organization_id = organization_id(organization)

    from(m in OrganizationMember,
      join: u in assoc(m, :user),
      where: m.organization_id == ^organization_id,
      # role is stored as a string, and "org_admin" sorts after "member".
      order_by: [
        desc: m.role,
        asc: u.email,
        asc: m.id
      ],
      preload: [user: u]
    )
    |> Repo.all()
  end

  defp membership_query(%User{id: user_id}, organization) do
    organization_id = organization_id(organization)

    where(
      OrganizationMember,
      [m],
      m.user_id == ^user_id and m.organization_id == ^organization_id
    )
  end

  defp without_contact_query do
    fields = Organization.__schema__(:fields) -- Organization.contact_fields()
    from(o in Organization, select: struct(o, ^fields))
  end

  defp organization_id(%Organization{id: id}), do: id
  defp organization_id(id) when is_integer(id), do: id

  # The struct the caller holds is checked first, then the database row, so an
  # admin who was disabled or demoted after their session or LiveView loaded
  # them is refused too.
  defp site_admin?(%User{disabled_at: nil} = user) do
    Accounts.admin?(user) and enabled_admin_row?(user.id)
  end

  defp site_admin?(%User{}), do: false

  defp enabled_admin_row?(user_id) do
    User
    |> where([u], u.id == ^user_id and u.type == ^:admin and is_nil(u.disabled_at))
    |> Repo.exists?()
  end
end
