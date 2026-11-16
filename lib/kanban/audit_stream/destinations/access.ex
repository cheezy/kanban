defmodule Kanban.AuditStream.Destinations.Access do
  @moduledoc """
  Who may change an Organization's audit-log destinations, and the locked
  lookups every write in `Kanban.AuditStream.Destinations` makes
  (`docs/plans/AUDIT-LOG-STREAMING-DESIGN.md` §4, §12.3).

  `authorize/1` re-reads from the database that the scope's user is an
  enabled org-admin and finds their Organization from their own membership,
  never from the session or the caller. A destination is then looked up by
  its id and that Organization, so another Organization's destination is
  `:not_found`.

  Every write checks again inside its transaction, through
  `authorize_locked/2` or `fetch_authorized/3`, once it holds the
  Organization row lock and the destination's, so a revocation that
  committed while it waited for either lock refuses it. Removing, demoting,
  disabling or deleting an org-admin takes the Organization row lock first
  (see `Kanban.Organizations.MembershipWrites`), so one that has not
  committed by the check waits until the write has.
  """

  import Ecto.Query, only: [from: 2, lock: 2]

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Accounts.User
  alias Kanban.AuditStream.Destination
  alias Kanban.Organizations
  alias Kanban.Organizations.Organization
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  # The largest bigint primary key; a larger id cannot exist and would fail
  # to encode as a query parameter.
  @max_id 9_223_372_036_854_775_807

  @doc """
  Re-reads the scope's user from the database and returns
  `{:ok, actor, organization_id}` when they are an enabled org-admin of their
  Organization, else `{:error, :unauthorized}`. A site admin is not an
  org-admin, so is refused (D8).
  """
  @spec authorize(Scope.t() | nil) :: {:ok, User.t(), pos_integer()} | {:error, :unauthorized}
  def authorize(%Scope{user: %User{id: id}}) do
    with %User{disabled_at: nil} = actor <- Accounts.get_user(id),
         %OrganizationMember{organization_id: organization_id} <-
           Organizations.get_membership(actor),
         true <- Organizations.org_admin?(actor, organization_id) do
      {:ok, actor, organization_id}
    else
      _refused -> {:error, :unauthorized}
    end
  end

  def authorize(_scope), do: {:error, :unauthorized}

  @doc """
  The Organization's destination `id`, or `{:error, :not_found}`. With
  `lock: true` the row is locked `FOR UPDATE`.
  """
  @spec fetch(pos_integer(), term(), keyword()) :: {:ok, Destination.t()} | {:error, :not_found}
  def fetch(organization_id, id, opts \\ []) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} when is_integer(id) and id > 0 and id <= @max_id ->
        organization_id |> destination_query(id, opts) |> one()

      _invalid ->
        {:error, :not_found}
    end
  end

  @doc """
  The check `authorize/1` made, made again once the Organization row is
  locked. Two creates for one Organization also queue on that lock, so the
  second counts the first's committed destination.
  """
  @spec authorize_locked(User.t(), pos_integer()) :: :ok | {:error, :unauthorized | :not_found}
  def authorize_locked(%User{} = actor, organization_id) do
    with :ok <- lock_organization(organization_id),
         do: still_org_admin(actor, organization_id)
  end

  @doc """
  Inside a transaction: locks the Organization row, then the destination's
  (`FOR UPDATE`), and reads the actor's rights again, so a revocation that
  committed during either wait is seen. Every path that takes both locks
  takes them in that order. A revoked caller gets `{:error, :unauthorized}`
  before being told whether the destination still exists.
  """
  @spec fetch_authorized(User.t(), pos_integer(), term()) ::
          {:ok, Destination.t()} | {:error, :unauthorized | :not_found}
  def fetch_authorized(%User{} = actor, organization_id, id) do
    with :ok <- lock_organization(organization_id),
         fetched = fetch(organization_id, id, lock: true),
         :ok <- still_org_admin(actor, organization_id),
         do: fetched
  end

  defp still_org_admin(actor, organization_id) do
    if Organizations.org_admin?(actor, organization_id), do: :ok, else: {:error, :unauthorized}
  end

  defp lock_organization(organization_id) do
    query =
      from(o in Organization, where: o.id == ^organization_id, select: o.id, lock: "FOR UPDATE")

    case Repo.one(query) do
      nil -> {:error, :not_found}
      _id -> :ok
    end
  end

  defp destination_query(organization_id, id, opts) do
    query = from(d in Destination, where: d.id == ^id and d.organization_id == ^organization_id)
    if Keyword.get(opts, :lock, false), do: lock(query, "FOR UPDATE"), else: query
  end

  defp one(query) do
    case Repo.one(query) do
      nil -> {:error, :not_found}
      destination -> {:ok, destination}
    end
  end
end
