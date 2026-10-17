defmodule Kanban.Organizations do
  @moduledoc """
  Paying Organizations and their members.

  An Organization is created and edited only by an enabled site admin
  (`User.type` `:admin` with no `disabled_at`). That check runs here, inside
  the context, against both the actor struct and the actor's current database
  row, so a LiveView or controller that forgets it cannot let anyone else
  through, and an admin disabled mid-session is refused.

  A user belongs to at most one Organization, as an `:org_admin` or a
  `:member`. There is deliberately no function to delete an Organization or to
  downgrade it.

  ## Membership rules

    * `add_member/3` adds a user with role `:member`. It is the internal
      function invitation acceptance calls, so it takes no actor.
    * Only an enabled site admin appoints or removes an org-admin
      (`appoint_org_admin/3`, `remove_org_admin/3`). No function lets an
      org-admin grant or remove the role.
    * A user in another Organization is refused with
      `{:error, :already_in_another_organization}`. The unique index on
      `organization_members.user_id` backs this, so a concurrent write that
      wins the race produces the same error.
    * An Organization keeps an org-admin while it has other members:
      `remove_org_admin/3` refuses with `{:error, :last_org_admin}`. Every
      membership write first takes a row lock on the organization, so two
      concurrent removals cannot both pass that check.
    * Removing an org-admin deletes the membership; it never demotes.
    * `appoint_org_admin_by_email/4` appoints by email. An unknown email gets
      a new account in the same transaction as the membership, and the
      confirmation and password-reset emails after it commits; a disabled
      account is refused with `{:error, :user_disabled}`.

  ## Telemetry and audit events

  Creating and editing an Organization emits `[:kanban, :organization,
  :created]` and `:updated` and records the `:organization_created` and
  `:organization_updated` audit events. A new membership emits
  `[:kanban, :organization, :member_added]` and a removed org-admin emits
  `:member_removed`. Appointing and removing an org-admin also record the
  `:org_admin_appointed` and `:org_admin_removed` audit events. All of them go
  through `Kanban.Organizations.OrganizationTelemetry`, and only after the
  write has committed, so a refusal emits and records nothing.

  The membership functions check the actor here and leave the locked
  transaction to `Kanban.Organizations.MembershipWrites`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations.MembershipWrites
  alias Kanban.Organizations.OrgAdminProvisioning
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
  Returns a changeset for tracking `organization` changes in a form. It
  writes nothing, so it takes no actor.
  """
  @spec change_organization(Organization.t(), map()) :: Ecto.Changeset.t()
  def change_organization(%Organization{} = organization, attrs \\ %{}) do
    Organization.changeset(organization, attrs)
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

  @doc """
  Adds `user` to `organization` with role `:member`.

  This is the internal function invitation acceptance calls, so it takes no
  actor: the caller has already decided that `user` may join. A user who is
  already in this Organization, in either role, is left as they are and their
  membership is returned; an existing org-admin is never downgraded. A user in
  another Organization is refused.

  Emits `[:kanban, :organization, :member_added]` only when a membership was
  created. `actor_user_id` in it is the joining user.

  ## Examples

      iex> add_member(organization, user, :member)
      {:ok, %OrganizationMember{role: :member}}

      iex> add_member(organization, user_in_other_organization, :member)
      {:error, :already_in_another_organization}

  """
  @spec add_member(Organization.t() | integer(), User.t(), :member) ::
          {:ok, OrganizationMember.t()}
          | {:error, :already_in_another_organization | :not_found | Ecto.Changeset.t()}
  def add_member(organization, %User{} = user, :member) do
    organization
    |> organization_id()
    |> MembershipWrites.add_member(user)
  end

  @doc """
  Makes `user` an org-admin of `organization`.

  `actor` must be an enabled site admin; anyone else, including an org-admin of
  this Organization, gets `{:error, :unauthorized}` and nothing is written. A
  user with no Organization gets a new `:org_admin` membership, a member of
  this Organization is promoted, and an existing org-admin of it is left as
  they are. A user in another Organization is refused.

  Records the `:org_admin_appointed` audit event for a new or promoted
  org-admin, and emits `[:kanban, :organization, :member_added]` when the
  membership is new.

  ## Examples

      iex> appoint_org_admin(admin, organization, user)
      {:ok, %OrganizationMember{role: :org_admin}}

      iex> appoint_org_admin(org_admin, organization, user)
      {:error, :unauthorized}

  """
  @spec appoint_org_admin(User.t(), Organization.t() | integer(), User.t()) ::
          {:ok, OrganizationMember.t()}
          | {:error,
             :unauthorized | :already_in_another_organization | :not_found | Ecto.Changeset.t()}
  def appoint_org_admin(%User{} = actor, organization, %User{} = user) do
    if site_admin?(actor) do
      MembershipWrites.appoint_org_admin(actor, organization_id(organization), user)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Makes the user with `email` an org-admin of `organization`, creating their
  account when there is none.

  `actor` must be an enabled site admin; anyone else gets
  `{:error, :unauthorized}` before the email is looked up. Surrounding
  whitespace is trimmed, and the lookup ignores case.

    * An enabled account is appointed through `appoint_org_admin/3`, with the
      same results. No account is created and no email is sent.
    * A disabled account is refused with `{:error, :user_disabled}`.
    * An unknown email gets a new, unconfirmed account with a random password
      that is never shown, created in one transaction with its `:org_admin`
      membership (`Kanban.Organizations.OrgAdminProvisioning`). Once that has
      committed, the confirmation email and the password-reset email are sent,
      so the appointee confirms their address and sets their own password. An
      invalid email returns the registration changeset, and a failed
      membership write rolls the new account back; neither sends an email.

  `urls` holds the links for the two emails, as functions of the encoded
  token: `confirmation_url:` and `reset_password_url:`. Both are required, and
  a missing one raises `ArgumentError`.

  `[:kanban, :organization, :member_added]` and the `:org_admin_appointed`
  audit event carry `account_created`, which is `true` only when the account
  was created here.

  ## Examples

      iex> appoint_org_admin_by_email(admin, organization, "ada@acme.test",
      ...>   confirmation_url: &url(~p"/users/confirm/\#{&1}"),
      ...>   reset_password_url: &url(~p"/users/reset-password/\#{&1}")
      ...> )
      {:ok, %OrganizationMember{role: :org_admin}}

      iex> appoint_org_admin_by_email(admin, organization, "disabled@acme.test", urls)
      {:error, :user_disabled}

  """
  @spec appoint_org_admin_by_email(
          User.t(),
          Organization.t() | integer(),
          String.t(),
          OrgAdminProvisioning.urls()
        ) ::
          {:ok, OrganizationMember.t()}
          | {:error,
             :unauthorized
             | :user_disabled
             | :already_in_another_organization
             | :not_found
             | Ecto.Changeset.t()}
  def appoint_org_admin_by_email(%User{} = actor, organization, email, urls)
      when is_binary(email) do
    urls = OrgAdminProvisioning.validate_urls!(urls)

    if site_admin?(actor) do
      appoint_by_email(actor, organization, String.trim(email), urls)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Removes `user`'s org-admin membership of `organization`.

  `actor` must be an enabled site admin; anyone else gets
  `{:error, :unauthorized}`. The membership is deleted, never demoted. When
  `user` is the last org-admin and the Organization has other members, the
  removal is refused with `{:error, :last_org_admin}`; the last org-admin of an
  Organization with no other members can be removed. A user who is not an
  org-admin of `organization` gets `{:error, :not_found}`.

  The check runs under a row lock on the organization, so two concurrent
  removals of its last two org-admins leave one of them in place.

  Emits `[:kanban, :organization, :member_removed]` and records the
  `:org_admin_removed` audit event once the removal has committed.

  ## Examples

      iex> remove_org_admin(admin, organization, org_admin)
      {:ok, %OrganizationMember{}}

      iex> remove_org_admin(admin, organization, last_org_admin)
      {:error, :last_org_admin}

  """
  @spec remove_org_admin(User.t(), Organization.t() | integer(), User.t()) ::
          {:ok, OrganizationMember.t()}
          | {:error, :unauthorized | :last_org_admin | :not_found}
  def remove_org_admin(%User{} = actor, organization, %User{} = user) do
    if site_admin?(actor) do
      MembershipWrites.remove_org_admin(actor, organization_id(organization), user)
    else
      {:error, :unauthorized}
    end
  end

  defp appoint_by_email(actor, organization, email, urls) do
    case Accounts.get_user_by_email(email) do
      %User{} = user ->
        appoint_existing_account(actor, organization, user)

      nil ->
        actor
        |> OrgAdminProvisioning.provision(organization_id(organization), email, urls)
        |> appoint_if_registered_meanwhile(actor, organization, email)
    end
  end

  defp appoint_existing_account(_actor, _organization, %User{disabled_at: %DateTime{}}),
    do: {:error, :user_disabled}

  defp appoint_existing_account(actor, organization, %User{} = user),
    do: appoint_org_admin(actor, organization, user)

  # Another write registered the email between the lookup and the insert, so
  # that account is appointed instead of creating a second one.
  defp appoint_if_registered_meanwhile({:error, :email_taken}, actor, organization, email) do
    case Accounts.get_user_by_email(email) do
      %User{} = user -> appoint_existing_account(actor, organization, user)
      nil -> {:error, :not_found}
    end
  end

  defp appoint_if_registered_meanwhile(result, _actor, _organization, _email), do: result

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
