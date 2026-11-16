defmodule Kanban.Organizations.Memberships do
  @moduledoc """
  Reads Organization memberships, for `Kanban.Organizations.get_membership/1`,
  `org_admin?/2`, `member?/2` and `list_members/1`.

  It checks no actor: `Kanban.Organizations` documents who may see each
  result, and every caller goes through it. `get_membership/1` is one join
  query, because UserAuth runs it on every request, and it leaves the
  Organization's contact name, phone and email out, because any member reaches
  it. `org_admin?/2` reads the account's enabled status from the database, the
  rule `Kanban.Organizations.OrgAdmins` applies too.
  """

  import Ecto.Query, only: [from: 2, join: 5, where: 3]

  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @doc """
  `user`'s membership with its Organization's non-contact fields, or `nil`.
  See `Kanban.Organizations.get_membership/1`.
  """
  @spec get_membership(User.t()) :: OrganizationMember.t() | nil
  def get_membership(%User{id: user_id}) do
    # One query (a join, not a preload): UserAuth runs this on every request.
    from(m in OrganizationMember,
      join: o in assoc(m, :organization),
      where: m.user_id == ^user_id,
      select: {m, struct(o, ^fields_without_contact())}
    )
    |> Repo.one()
    |> put_membership_organization()
  end

  @doc """
  True when `user` is an enabled org-admin of `organization`. See
  `Kanban.Organizations.org_admin?/2`.
  """
  @spec org_admin?(User.t(), Organization.t() | integer()) :: boolean()
  def org_admin?(%User{} = user, organization) do
    user
    |> membership_query(organization)
    |> join(:inner, [m], u in assoc(m, :user), on: is_nil(u.disabled_at))
    |> where([m], m.role == ^:org_admin)
    |> Repo.exists?()
  end

  @doc """
  True when `user` belongs to `organization` in either role. See
  `Kanban.Organizations.member?/2`.
  """
  @spec member?(User.t(), Organization.t() | integer()) :: boolean()
  def member?(%User{} = user, organization) do
    user
    |> membership_query(organization)
    |> Repo.exists?()
  end

  @doc """
  `organization`'s memberships with users preloaded, org-admins first and then
  by email. See `Kanban.Organizations.list_members/1`.
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

  defp put_membership_organization(nil), do: nil

  defp put_membership_organization({%OrganizationMember{} = membership, organization}),
    do: %{membership | organization: organization}

  defp membership_query(%User{id: user_id}, organization) do
    organization_id = organization_id(organization)

    where(
      OrganizationMember,
      [m],
      m.user_id == ^user_id and m.organization_id == ^organization_id
    )
  end

  defp fields_without_contact do
    Organization.__schema__(:fields) -- Organization.contact_fields()
  end

  defp organization_id(%Organization{id: id}), do: id
  defp organization_id(id) when is_integer(id), do: id
end
