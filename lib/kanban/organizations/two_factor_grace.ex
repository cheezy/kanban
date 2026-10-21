defmodule Kanban.Organizations.TwoFactorGrace do
  @moduledoc """
  When one member's two-factor grace period started under their
  Organization's current requirement (decided 2026-10-21).

  Grace counts once per user per Organization: leaving and re-joining (a
  SCIM deactivate and re-activate, an org-admin removing and re-adding
  someone, a single sign-on rejoin) keeps the start recorded here instead of
  starting again from the new membership. `enforced_at` is the policy's
  `two_factor_enforced_at` the row belongs to, so turning the requirement off
  and on again (or shortening the grace days, which restamps it) starts a new
  grace period for everyone, as before.

  Written by `Kanban.Organizations.SecurityPolicies`, never from params.
  """
  use Ecto.Schema

  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization

  @type t :: %__MODULE__{}

  schema "organization_two_factor_grace" do
    field :enforced_at, :utc_datetime
    field :started_at, :utc_datetime

    belongs_to :organization, Organization
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end
end
