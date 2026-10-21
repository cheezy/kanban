defmodule Kanban.Organizations.SecurityPolicy do
  @moduledoc """
  One Organization's security policy (W2244).

  * `require_two_factor` — every member must use two-factor authentication.
  * `two_factor_grace_days` — days (1 to 30, default 7) a member without
    two-factor has before every authenticated browser request is redirected
    to the two-factor section of their settings.
  * `two_factor_enforced_at` — when `require_two_factor` was last turned on;
    each member's grace deadline counts from the later of this and the moment
    they first joined under it, recorded once per member
    (`Kanban.Organizations.TwoFactorGrace`). Set by `changeset/3`, never cast.
  * `audit_retention_days` — days (90 to 3650) to keep the Organization's
    audit events, or `nil` to keep them forever. The 90-day floor is also
    enforced by the database purge function.

  An Organization with no row has the defaults: no two-factor requirement and
  audit events kept forever (`Kanban.Organizations.SecurityPolicies`).

  `organization_id` and `updated_by_id` are set by the context from the
  acting org-admin's own membership, never cast from params.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.AuditLog.Hardening.Purge
  alias Kanban.Organizations.Organization

  @min_grace_days 1
  @max_grace_days 30
  @max_retention_days 3650

  @type t :: %__MODULE__{}

  schema "organization_security_policies" do
    field :require_two_factor, :boolean, default: false
    field :two_factor_grace_days, :integer, default: 7
    field :two_factor_enforced_at, :utc_datetime
    field :audit_retention_days, :integer

    belongs_to :organization, Organization
    belongs_to :updated_by, User

    timestamps(type: :utc_datetime)
  end

  @doc "The fields an org-admin may change, which are also the fields audited."
  @spec editable_fields() :: [atom()]
  def editable_fields, do: [:require_two_factor, :two_factor_grace_days, :audit_retention_days]

  @doc "The allowed range of grace days."
  @spec grace_days_range() :: Range.t()
  def grace_days_range, do: @min_grace_days..@max_grace_days

  @doc "The allowed range of audit retention days."
  @spec retention_days_range() :: Range.t()
  def retention_days_range, do: Purge.retention_floor_days()..@max_retention_days

  @doc """
  Casts the editable fields and validates their ranges.

  `two_factor_enforced_at` follows `require_two_factor`: turning it on stamps
  `now` (so turning it off and on again starts a new grace period), turning it
  off clears it. Shortening the grace days while it stays on also restamps
  `now`, so a shorter grace period never puts members past their deadline the
  moment it is saved. A blank retention means keep forever.
  """
  @spec changeset(t(), map(), DateTime.t()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = policy, attrs, %DateTime{} = now) do
    policy
    |> cast(attrs, editable_fields(), empty_values: [""])
    |> validate_required([:require_two_factor, :two_factor_grace_days])
    |> validate_number(:two_factor_grace_days,
      greater_than_or_equal_to: @min_grace_days,
      less_than_or_equal_to: @max_grace_days
    )
    |> validate_number(:audit_retention_days,
      greater_than_or_equal_to: Purge.retention_floor_days(),
      less_than_or_equal_to: @max_retention_days
    )
    |> put_enforced_at(policy, DateTime.truncate(now, :second))
    |> unique_constraint(:organization_id)
    |> check_constraint(:two_factor_grace_days, name: :two_factor_grace_days_range)
    |> check_constraint(:audit_retention_days, name: :audit_retention_days_range)
    |> check_constraint(:require_two_factor, name: :two_factor_enforced_at_when_required)
  end

  defp put_enforced_at(changeset, policy, now) do
    required? = get_field(changeset, :require_two_factor)

    cond do
      required? != true -> put_change(changeset, :two_factor_enforced_at, nil)
      policy.require_two_factor != true -> put_change(changeset, :two_factor_enforced_at, now)
      grace_shortened?(changeset, policy) -> put_change(changeset, :two_factor_enforced_at, now)
      true -> changeset
    end
  end

  defp grace_shortened?(changeset, policy) do
    case get_change(changeset, :two_factor_grace_days) do
      days when is_integer(days) -> days < policy.two_factor_grace_days
      _unchanged -> false
    end
  end
end
