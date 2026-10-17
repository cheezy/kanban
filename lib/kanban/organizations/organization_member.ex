defmodule Kanban.Organizations.OrganizationMember do
  @moduledoc """
  A user's membership of one Organization, with their role in it.

  `role` is `:org_admin` or `:member`. A user belongs to at most one
  Organization, which the unique index on `user_id` enforces.

  Every field here decides who can act for an Organization, so none of them is
  cast from caller params. `changeset/3` takes the organization id, user id and
  role as arguments that the calling context has already decided on, which
  means a form field can never attach a user to an Organization or grant
  `:org_admin`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization

  @roles [:org_admin, :member]

  @type role :: :org_admin | :member
  @type t :: %__MODULE__{}

  schema "organization_members" do
    field :role, Ecto.Enum, values: @roles

    belongs_to :organization, Organization
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the roles a member can hold.
  """
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  Builds a changeset for a new membership from values the context has set.

  Nothing is cast. A second membership for the same user, an organization or
  user that does not exist, and a role outside `roles/0` all come back as
  changeset errors rather than raising.
  """
  @spec changeset(integer(), integer(), atom()) :: Ecto.Changeset.t()
  def changeset(organization_id, user_id, role) do
    %__MODULE__{}
    |> change(organization_id: organization_id, user_id: user_id, role: role)
    |> validate_required([:organization_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:role, name: :organization_members_role_check)
  end

  @doc """
  Builds a changeset that sets an existing membership's role to `role`, a value
  the calling context has decided on. Nothing is cast, and a role outside
  `roles/0` comes back as a changeset error.
  """
  @spec role_changeset(t(), atom()) :: Ecto.Changeset.t()
  def role_changeset(%__MODULE__{} = membership, role) do
    membership
    |> change(role: role)
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
    |> check_constraint(:role, name: :organization_members_role_check)
  end
end
