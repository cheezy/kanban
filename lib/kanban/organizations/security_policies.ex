defmodule Kanban.Organizations.SecurityPolicies do
  @moduledoc """
  Reads and changes Organization security policies
  (`Kanban.Organizations.SecurityPolicy`) and answers what the two-factor
  requirement means for one user.

  Only an enabled org-admin changes a policy, and only their own
  Organization's: `update_policy/2` takes the Organization from the actor's
  membership, never from params, and re-reads the role from the database on
  every call. Each saved change records an `organization_policy_updated` audit
  event with the old and new values of the fields that changed.

  ## Two-factor grace deadlines

  A member's deadline is the later of the moment the requirement was turned on
  (`two_factor_enforced_at`) and the moment they joined (their membership's
  `inserted_at`), plus `two_factor_grace_days`. Existing members are therefore
  never locked out the moment the policy is enabled, and someone who joins
  later gets their own grace period. Nothing is stored per member, so turning
  the policy off, or leaving the Organization, takes effect on the next
  request.
  """
  import Ecto.Query, warn: false

  alias Kanban.Accounts.TwoFactor
  alias Kanban.Accounts.User
  alias Kanban.AuditLog
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.SecurityPolicy
  alias Kanban.Repo

  @seconds_per_day 24 * 60 * 60

  @type two_factor_status ::
          :not_required | :enrolled | {:grace, DateTime.t()} | {:overdue, DateTime.t()}

  @doc """
  Returns the Organization's stored policy, or an unsaved one with the
  defaults (no two-factor requirement, audit events kept forever).
  """
  @spec policy_for_organization(pos_integer()) :: SecurityPolicy.t()
  def policy_for_organization(organization_id) when is_integer(organization_id) do
    Repo.get_by(SecurityPolicy, organization_id: organization_id) ||
      %SecurityPolicy{organization_id: organization_id}
  end

  @doc "Returns a changeset for the policy form."
  @spec change_policy(SecurityPolicy.t(), map()) :: Ecto.Changeset.t()
  def change_policy(%SecurityPolicy{} = policy, attrs \\ %{}) do
    SecurityPolicy.changeset(policy, attrs, DateTime.utc_now())
  end

  @doc """
  Saves `attrs` onto the actor's own Organization's policy.

  Returns `{:error, :unauthorized}`, writing nothing, unless `actor` is an
  enabled org-admin, read from the database. A save that changes no field
  records no audit event.
  """
  @spec update_policy(User.t(), map()) ::
          {:ok, SecurityPolicy.t()} | {:error, :unauthorized} | {:error, Ecto.Changeset.t()}
  def update_policy(%User{} = actor, attrs) when is_map(attrs) do
    with {:ok, organization_id} <- org_admin_organization_id(actor),
         {:ok, {policy, old}} <- save_policy(organization_id, actor, attrs) do
      record_update(policy, old, actor)
      {:ok, policy}
    end
  end

  defp save_policy(organization_id, actor, attrs) do
    Repo.transact(fn ->
      policy = locked_policy(organization_id)
      old = Map.take(policy, SecurityPolicy.editable_fields())

      policy
      |> SecurityPolicy.changeset(attrs, DateTime.utc_now())
      |> Ecto.Changeset.put_change(:updated_by_id, actor.id)
      |> Repo.insert_or_update()
      |> case do
        {:ok, saved} -> {:ok, {saved, old}}
        {:error, changeset} -> {:error, changeset}
      end
    end)
  end

  defp locked_policy(organization_id) do
    query =
      from(p in SecurityPolicy, where: p.organization_id == ^organization_id, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil -> %SecurityPolicy{organization_id: organization_id}
      policy -> policy
    end
  end

  defp record_update(policy, old, actor) do
    new = Map.take(policy, SecurityPolicy.editable_fields())
    changed = for {field, value} <- new, Map.fetch!(old, field) != value, do: field

    if changed != [] do
      AuditLog.event(:organization_policy_updated,
        user_id: actor.id,
        organization_id: policy.organization_id,
        old_values: Map.take(old, changed),
        new_values: Map.take(new, changed)
      )
    end
  end

  # The actor's Organization comes from their own membership, and their
  # org-admin role and enabled account from org_admin?/2, both read from the
  # database on every call.
  defp org_admin_organization_id(actor) do
    with %OrganizationMember{role: :org_admin, organization_id: organization_id} <-
           Organizations.get_membership(actor),
         true <- Organizations.org_admin?(actor, organization_id) do
      {:ok, organization_id}
    else
      _not_an_enabled_org_admin -> {:error, :unauthorized}
    end
  end

  @doc """
  Returns the member's two-factor grace deadline under `policy`: the later of
  `two_factor_enforced_at` and the membership's `inserted_at`, plus the grace
  days.
  """
  @spec grace_deadline(SecurityPolicy.t(), OrganizationMember.t()) :: DateTime.t()
  def grace_deadline(
        %SecurityPolicy{two_factor_enforced_at: %DateTime{} = enforced_at} = policy,
        %OrganizationMember{inserted_at: %DateTime{} = joined_at}
      ) do
    start = if DateTime.compare(joined_at, enforced_at) == :gt, do: joined_at, else: enforced_at
    DateTime.add(start, policy.two_factor_grace_days * @seconds_per_day, :second)
  end

  @doc """
  What the user's Organization's two-factor requirement means for them at
  `now`, given their membership (or `nil`):

    * `:not_required` — no membership, no policy, or the requirement is off;
    * `:enrolled` — required, and the user has two-factor on;
    * `{:grace, deadline}` — required, not on, and `now` is before the deadline;
    * `{:overdue, deadline}` — required, not on, and the deadline has passed.
  """
  @spec two_factor_status(User.t(), OrganizationMember.t() | nil, DateTime.t()) ::
          two_factor_status()
  def two_factor_status(user, membership, now \\ DateTime.utc_now())

  def two_factor_status(%User{}, nil, _now), do: :not_required

  def two_factor_status(%User{} = user, %OrganizationMember{} = membership, now) do
    policy = policy_for_organization(membership.organization_id)

    cond do
      policy.require_two_factor != true -> :not_required
      TwoFactor.enabled?(user) -> :enrolled
      true -> deadline_status(grace_deadline(policy, membership), now)
    end
  end

  defp deadline_status(deadline, now) do
    if DateTime.compare(now, deadline) == :lt, do: {:grace, deadline}, else: {:overdue, deadline}
  end

  @doc """
  Like `two_factor_status/3`, reading the user's membership from the database.
  """
  @spec two_factor_status_for_user(User.t(), DateTime.t()) :: two_factor_status()
  def two_factor_status_for_user(%User{} = user, now \\ DateTime.utc_now()) do
    two_factor_status(user, Organizations.get_membership(user), now)
  end

  @doc """
  Returns true while the user's Organization requires two-factor, whether or
  not the user has it on yet.
  """
  @spec two_factor_required?(User.t()) :: boolean()
  def two_factor_required?(%User{id: user_id}) do
    from(p in SecurityPolicy,
      join: m in OrganizationMember,
      on: m.organization_id == p.organization_id,
      where: m.user_id == ^user_id and p.require_two_factor
    )
    |> Repo.exists?()
  end

  @doc """
  Lists the Organizations that set an audit retention period, as
  `%{organization_id: id, audit_retention_days: days}` ordered by id.
  """
  @spec list_audit_retention() :: [
          %{organization_id: pos_integer(), audit_retention_days: pos_integer()}
        ]
  def list_audit_retention do
    from(p in SecurityPolicy,
      where: not is_nil(p.audit_retention_days),
      order_by: p.organization_id,
      select: %{organization_id: p.organization_id, audit_retention_days: p.audit_retention_days}
    )
    |> Repo.all()
  end
end
