defmodule Kanban.SCIM.UserLink do
  @moduledoc """
  Records that an Organization's identity provider provisioned or linked a
  user through SCIM (W2247), with the provider's `externalId`.

  It grants no access: membership stays in `organization_members`. It exists
  so a user SCIM deprovisioned, who no longer has a membership, can still be
  read (`active: false`) and re-activated by the same Organization, and so
  the `externalId` and name parts the provider sent round-trip.
  `deprovisioned_at` is set only when SCIM itself ends the membership, so a
  person the Organization removed some other way is not reachable through
  the link. Joining any Organization clears the mark on every one of the
  user's links (`Kanban.Organizations.MembershipWrites`), so a person who
  regained the membership some other way, or who has since joined another
  Organization, stays unreachable even after that membership ends.
  `scim_disabled_at` is the `disabled_at` SCIM's deprovisioning set on an
  account the Organization manages, so SCIM re-enables only an account it
  disabled itself; a site admin disabling or enabling the account clears it
  (`Kanban.Accounts.AdminManagement`), so that action is never reversed.
  """
  use Ecto.Schema
  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization
  alias Kanban.Repo

  @type t :: %__MODULE__{}

  schema "scim_user_links" do
    field :external_id, :string
    field :deprovisioned_at, :utc_datetime
    field :given_name, :string
    field :family_name, :string
    field :scim_disabled_at, :utc_datetime

    belongs_to :organization, Organization
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates or updates the link between the Organization and the user. Pass
  `:keep` as `external_id` to leave a stored `externalId` as it is.
  """
  @spec upsert(integer(), integer(), String.t() | nil | :keep) :: {:ok, t()}
  def upsert(organization_id, user_id, :keep) do
    case get(organization_id, user_id) do
      %__MODULE__{} = link -> {:ok, link}
      nil -> upsert(organization_id, user_id, nil)
    end
  end

  def upsert(organization_id, user_id, external_id) do
    now = DateTime.utc_now(:second)

    %__MODULE__{
      organization_id: organization_id,
      user_id: user_id,
      external_id: external_id,
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert(
      on_conflict: [set: [external_id: external_id, updated_at: now]],
      conflict_target: [:organization_id, :user_id],
      returning: true
    )
  end

  @doc """
  Records whether SCIM ended the user's membership: `at` is when it did, or
  `nil` once the user is a member again.
  """
  @spec put_deprovisioned(integer(), integer(), DateTime.t() | nil) :: :ok
  def put_deprovisioned(organization_id, user_id, at) do
    set_fields(organization_id, user_id, deprovisioned_at: at)
  end

  @doc """
  Clears the deprovisioned mark on every link the user has, once they join
  an Organization, so no Organization's SCIM reaches them through it.
  """
  @spec clear_deprovisioned_for_user(integer()) :: :ok
  def clear_deprovisioned_for_user(user_id) do
    set_user_fields(user_id, deprovisioned_at: nil)
  end

  @doc """
  Forgets SCIM's disable on every link the user has, once a site admin
  disables or enables the account, so SCIM never reverses that action.
  """
  @spec clear_scim_disabled_for_user(integer()) :: :ok
  def clear_scim_disabled_for_user(user_id) do
    set_user_fields(user_id, scim_disabled_at: nil)
  end

  @doc "Records the `disabled_at` SCIM's deprovisioning set on the account."
  @spec put_scim_disabled(integer(), integer(), DateTime.t()) :: :ok
  def put_scim_disabled(organization_id, user_id, %DateTime{} = at) do
    set_fields(organization_id, user_id, scim_disabled_at: at)
  end

  @doc """
  Detaches the user after a SCIM DELETE: the link stops making them
  reachable and forgets the `externalId` and name parts, keeping only
  `scim_disabled_at`, so provisioning the same account again can still
  re-enable an account SCIM disabled.
  """
  @spec detach(integer(), integer()) :: :ok
  def detach(organization_id, user_id) do
    set_fields(organization_id, user_id,
      deprovisioned_at: nil,
      external_id: nil,
      given_name: nil,
      family_name: nil
    )
  end

  @doc """
  Keeps the name parts the identity provider sent, so they read back as sent
  while they still make up the user's name.
  """
  @spec put_name_parts(integer(), integer(), String.t() | nil, String.t() | nil) :: :ok
  def put_name_parts(organization_id, user_id, given_name, family_name) do
    set_fields(organization_id, user_id, given_name: given_name, family_name: family_name)
  end

  defp set_fields(organization_id, user_id, changes) do
    from(l in __MODULE__, where: l.organization_id == ^organization_id and l.user_id == ^user_id)
    |> set_all(changes)
  end

  defp set_user_fields(user_id, changes) do
    from(l in __MODULE__, where: l.user_id == ^user_id)
    |> set_all(changes)
  end

  defp set_all(query, changes) do
    Repo.update_all(query, set: Keyword.put(changes, :updated_at, DateTime.utc_now(:second)))
    :ok
  end

  @doc "The link between the Organization and the user, or `nil`."
  @spec get(integer(), integer()) :: t() | nil
  def get(organization_id, user_id) do
    Repo.get_by(__MODULE__, organization_id: organization_id, user_id: user_id)
  end
end
