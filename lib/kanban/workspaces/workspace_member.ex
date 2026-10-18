defmodule Kanban.Workspaces.WorkspaceMember do
  @moduledoc """
  A user's membership of one workspace, with their role in it.

  `role` is `:owner`, `:member` or `:guest`. An owner row exists only on a
  personal workspace, and member and guest rows only on an org workspace. There
  is no admin role: an Organization's org-admins manage its workspaces.

  Every field here decides who can reach a workspace, so none of them is cast
  from caller params. `changeset/3` takes the workspace id, user id and role as
  arguments the calling context has already decided on.

  The database enforces the owner rules as well (see the `create_workspaces`
  migration), and each rejection comes back as a changeset error:

    * a second owner on a workspace → error on `:workspace_id`
    * a second owned workspace for a user → error on `:user_id`
    * a second row for the same workspace and user → error on `:user_id`
    * an owner row on an org workspace, or a member or guest row on a personal
      workspace → error on `:role`
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.Workspaces.Workspace

  @roles [:owner, :member, :guest]

  @type role :: :owner | :member | :guest
  @type t :: %__MODULE__{}

  schema "workspace_members" do
    field :role, Ecto.Enum, values: @roles

    belongs_to :workspace, Workspace
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the roles a workspace member can hold.
  """
  @spec roles() :: [role()]
  def roles, do: @roles

  @doc """
  Builds a changeset for a new membership from values the context has set.

  Nothing is cast. Constraint violations come back as changeset errors rather
  than raising.
  """
  @spec changeset(integer(), integer(), atom()) :: Ecto.Changeset.t()
  def changeset(workspace_id, user_id, role) do
    %__MODULE__{}
    |> change(workspace_id: workspace_id, user_id: user_id)
    |> put_role(role)
    |> validate_required([:workspace_id, :user_id])
    |> unique_constraint([:workspace_id, :user_id],
      error_key: :user_id,
      message: "is already a member of this workspace"
    )
    |> unique_constraint(:workspace_id,
      name: :workspace_members_one_owner_per_workspace,
      message: "workspace already has an owner"
    )
    |> unique_constraint(:user_id,
      name: :workspace_members_one_owned_workspace_per_user,
      message: "already owns a workspace"
    )
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Builds a changeset that sets an existing membership's role to `role`, a value
  the calling context has decided on. Nothing is cast.
  """
  @spec role_changeset(t(), atom()) :: Ecto.Changeset.t()
  def role_changeset(%__MODULE__{} = membership, role) do
    put_role(membership, role)
  end

  # `role` must be an atom from `roles/0`; anything else, including the string
  # "owner", is refused before it reaches the database.
  defp put_role(membership_or_changeset, role) when role in @roles do
    membership_or_changeset
    |> change(role: role)
    |> role_constraints()
  end

  defp put_role(membership_or_changeset, _role) do
    membership_or_changeset
    |> change()
    |> add_error(:role, "is invalid", validation: :inclusion, enum: @roles)
  end

  defp role_constraints(changeset) do
    changeset
    |> validate_required([:role])
    |> check_constraint(:role, name: :workspace_members_role_check)
    |> check_constraint(:role,
      name: :workspace_members_no_owner_on_org_workspace,
      message: "owner is only allowed on a personal workspace"
    )
    |> check_constraint(:role,
      name: :workspace_members_no_member_on_personal_workspace,
      message: "a personal workspace has only its owner"
    )
  end
end
