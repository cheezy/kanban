defmodule Kanban.Organizations.OrgAdmins do
  @moduledoc """
  Reads the enabled org-admins of an Organization, for
  `Kanban.Organizations.list_enabled_org_admins/1`.

  An org-admin is enabled when their account has no `disabled_at`, the same
  rule `Kanban.Organizations.org_admin?/2` and
  `Kanban.Organizations.count_enabled_org_admins/1` apply.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  @doc """
  The enabled org-admins of `organization`, as users ordered by id. An
  Organization with none gets `[]`.

  `organization` is an `%Organization{}` or its id.
  """
  @spec list_enabled_org_admins(Organization.t() | integer()) :: [User.t()]
  def list_enabled_org_admins(%Organization{id: id}), do: list_enabled_org_admins(id)

  def list_enabled_org_admins(organization_id) when is_integer(organization_id) do
    from(u in User,
      join: m in OrganizationMember,
      on: m.user_id == u.id,
      where:
        m.organization_id == ^organization_id and m.role == ^:org_admin and
          is_nil(u.disabled_at),
      order_by: u.id
    )
    |> Repo.all()
  end
end
