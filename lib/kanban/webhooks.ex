defmodule Kanban.Webhooks do
  @moduledoc """
  Outbound webhook endpoints for a board (W2226).

  Only the board's owner can see or manage its endpoints: every function
  takes the caller's `%Kanban.Accounts.Scope{}` first and checks
  `Kanban.Boards.owner?/2`. A member with modify or read-only access gets
  `{:error, :unauthorized}` from a write, `{:error, :not_found}` from
  `get_endpoint/3` and an empty list from `list_endpoints/2`.

  ## Paid plans

  Integrations are a paid feature. While paid plans are enforced,
  `create_endpoint/4`, `update_endpoint/4` (which also enables and disables an
  endpoint), `rotate_secret/2` and `send_test_event/2` return
  `{:error, {:plan_required, :integrations}}` on a free board
  (`Kanban.Plans.check_board/3`, surface `:context`, checked after the owner
  check). `delete_endpoint/2`, the listings and `get_endpoint/3` stay allowed,
  so an owner can still see and remove the configuration. Nothing here changes
  an endpoint because of the plan: `Kanban.Webhooks.Events` and
  `Kanban.Webhooks.DeliveryWorker` skip a free board's deliveries instead, so
  they resume on their own when the board moves into an Organization.

  The signing secret is revealed exactly once, as the second element of the
  `{:ok, {endpoint, secret}}` that `create_endpoint/4` and `rotate_secret/2`
  return. It is stored only as `Kanban.Integrations.SecretBox` ciphertext, and
  a rotation overwrites the old ciphertext, so the old secret cannot be
  recovered from the database. A backup taken before the rotation still holds
  the old ciphertext, which the same `secret_key_base` decrypts.
  `signing_secret/1` decrypts the secret for the delivery worker.

  A new or changed URL must pass `Kanban.Webhooks.UrlGuard.check/2`, which
  resolves its host. The `opts` of `create_endpoint/4` and
  `update_endpoint/4` are passed to it, on top of a `:resolver` configured
  with `config :kanban, Kanban.Webhooks, resolver: {module, function}`
  (the test environment points it at a fixed table, so no test does DNS).

  Delivery (W2227): `Kanban.Webhooks.Events` turns task changes into jobs
  for `Kanban.Webhooks.DeliveryWorker`, which sends them. Both query the
  endpoint and delivery tables themselves, privately, so this context exposes
  no unscoped lookup by id; `signing_secret/1` only decrypts an endpoint the
  caller already holds. `list_deliveries/3` is the owner-scoped read of an
  endpoint's delivery log for the Integrations tab (W2228).

  Related modules: `Kanban.Webhooks.Endpoint` and `Kanban.Webhooks.Delivery`
  (schemas), `Kanban.Webhooks.Signer` (the signature header),
  `Kanban.Webhooks.UrlGuard` (SSRF protection), `Kanban.Webhooks.Payload`
  (the envelope), `Kanban.Webhooks.SlackFormatter` (Slack messages),
  `Kanban.Webhooks.DiscordFormatter` (Discord messages) and
  `Kanban.Webhooks.Transport` (the HTTP request).

  ## Endpoints whose creator loses access

  An endpoint sends the board's task events to a URL its creator chose, so
  it is disabled when its creator can no longer open the board (decided
  2026-10-20), in the transaction that ends their access:

    * `pause_former_member_endpoints/2` when they are removed from the board
      or from a workspace and keep no access through an org-admin role,
    * `pause_creator_endpoints/2` when they leave the Organization or delete
      their account, and
    * `pause_outside_endpoints/2` when a board moves into an Organization
      and an endpoint's creator is not a member of it.

  The owner sees it as Disabled in the Integrations tab. Re-enabling it
  through `update_endpoint/4` makes the owner its creator.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Integrations.SecretBox
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.Webhooks.Delivery
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Payload
  alias Kanban.Webhooks.UrlGuard
  alias Kanban.Workspaces.Policy

  @delivery_log_fields ~w(id endpoint_id event status attempt response_status error delivered_at inserted_at)a

  @doc """
  Lists a board's endpoints, oldest first, for its owner; `[]` for anyone
  else.
  """
  def list_endpoints(scope, %Board{id: board_id}) do
    case authorize_owner(scope, board_id) do
      :ok ->
        Endpoint
        |> where([e], e.board_id == ^board_id)
        |> order_by([e], asc: e.inserted_at, asc: e.id)
        |> Repo.all()

      {:error, :unauthorized} ->
        []
    end
  end

  @doc """
  Gets one of a board's endpoints. Returns `{:error, :not_found}` for a
  caller who is not the owner, an endpoint on another board, or an id that
  does not exist or is malformed.
  """
  def get_endpoint(scope, %Board{id: board_id}, id) do
    with :ok <- authorize_owner(scope, board_id),
         {:ok, id} when is_integer(id) <- Ecto.Type.cast(:id, id),
         %Endpoint{} = endpoint <- Repo.get_by(Endpoint, id: id, board_id: board_id) do
      {:ok, endpoint}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Returns a changeset for tracking endpoint form changes."
  def change_endpoint(%Endpoint{} = endpoint \\ %Endpoint{}, attrs \\ %{}) do
    Endpoint.changeset(endpoint, attrs)
  end

  @doc """
  Creates an endpoint on the board with a new signing secret. Returns
  `{:ok, {endpoint, secret}}`, where `secret` is the only copy of the
  plaintext the caller will ever get.
  """
  def create_endpoint(scope, %Board{id: board_id}, attrs, opts \\ []) do
    opts = guard_opts(opts)

    with :ok <- authorize_owner(scope, board_id),
         :ok <- check_plan(board_id) do
      %Endpoint{board_id: board_id, created_by_id: scope.user.id}
      |> Endpoint.changeset(attrs, opts)
      |> check_reachable(opts)
      |> Endpoint.put_new_secret()
      |> Repo.insert()
      |> reveal()
    end
  end

  @doc """
  Updates an endpoint's kind, URL, event types or enabled flag. A changed URL
  is checked again with `UrlGuard.check/2`. Enabling a disabled endpoint makes
  the caller its creator. An endpoint deleted since it was
  loaded yields `{:error, changeset}` with an error on `:id`.
  """
  def update_endpoint(scope, %Endpoint{board_id: board_id} = endpoint, attrs, opts \\ []) do
    opts = guard_opts(opts)

    with :ok <- authorize_owner(scope, board_id),
         :ok <- check_plan(board_id) do
      endpoint
      |> Endpoint.changeset(attrs, opts)
      |> creator_on_enable(scope)
      |> check_reachable(opts)
      |> Repo.update(stale_error_field: :id)
    end
  end

  @doc """
  Replaces the endpoint's signing secret, returning `{:ok, {endpoint,
  secret}}` with the new plaintext. The old secret is gone.

  The rotation is optimistically locked on `lock_version`: rotating an
  endpoint loaded before another rotation yields `{:error, changeset}` with
  an error on `:id`, so no caller is shown a secret that was overwritten.
  """
  def rotate_secret(scope, %Endpoint{board_id: board_id} = endpoint) do
    with :ok <- authorize_owner(scope, board_id),
         :ok <- check_plan(board_id) do
      endpoint
      |> Changeset.change()
      |> Changeset.optimistic_lock(:lock_version)
      |> Endpoint.put_new_secret()
      |> Repo.update(stale_error_field: :id)
      |> reveal()
    end
  end

  @doc """
  Deletes an endpoint and, by the database cascade, its delivery log.
  """
  def delete_endpoint(scope, %Endpoint{board_id: board_id} = endpoint) do
    with :ok <- authorize_owner(scope, board_id) do
      Repo.delete(endpoint, stale_error_field: :id)
    end
  end

  @doc """
  Decrypts the endpoint's signing secret. For the delivery worker only: it
  checks no scope, so it must never be reachable from a request.
  """
  def signing_secret(%Endpoint{encrypted_secret: ciphertext}), do: SecretBox.decrypt(ciphertext)

  @doc """
  Queues a `ping` delivery to the endpoint so its owner can check the
  receiver. Returns `{:ok, job}`, `{:error, :unauthorized}` for anyone but
  the board's owner, or `{:error, :disabled}` for a disabled endpoint (the
  worker never sends to one).
  """
  def send_test_event(scope, %Endpoint{board_id: board_id} = endpoint) do
    with :ok <- authorize_owner(scope, board_id),
         :ok <- check_plan(board_id),
         :ok <- check_enabled(endpoint) do
      payload = Board |> Repo.get!(board_id) |> Payload.ping()
      DeliveryWorker.enqueue(endpoint.id, "ping", payload)
    end
  end

  @doc """
  The endpoint's most recent delivery attempts, newest first, at most
  `limit`, for the board's owner; `[]` for anyone else. The stored payload
  is not loaded.
  """
  def list_deliveries(scope, %Endpoint{} = endpoint, limit \\ 20)
      when is_integer(limit) and limit > 0 do
    case authorize_owner(scope, endpoint.board_id) do
      :ok -> query_deliveries(endpoint, limit)
      {:error, :unauthorized} -> []
    end
  end

  # The join re-checks the board, so an endpoint struct naming a board it is
  # not on reads nothing.
  defp query_deliveries(%Endpoint{id: id, board_id: board_id}, limit) do
    Delivery
    |> join(:inner, [d], e in assoc(d, :endpoint))
    |> where([d, e], d.endpoint_id == ^id and e.board_id == ^board_id)
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> limit(^limit)
    |> select([d], struct(d, @delivery_log_fields))
    |> Repo.all()
  end

  @doc """
  Disables the enabled endpoints `user_id` created on `boards` and returns how
  many. `boards` is a list of board ids, a query selecting board ids, or
  `:all`. Call it inside the transaction that ends the user's access to
  those boards. It checks no scope.

  ## Examples

      iex> pause_creator_endpoints(user.id, :all)
      1

  """
  @spec pause_creator_endpoints(integer(), [integer()] | Ecto.Query.t() | :all) ::
          non_neg_integer()
  def pause_creator_endpoints(user_id, boards) when is_integer(user_id) do
    Endpoint
    |> where([e], e.enabled and e.created_by_id == ^user_id)
    |> on_boards(boards)
    |> pause_all()
  end

  @doc """
  Like `pause_creator_endpoints/2`, but leaves the endpoints on boards that
  `user_id` can still open (`Kanban.Workspaces.Policy.effective_board_access/2`),
  such as an org-admin's. Call it after the change that removed their access,
  in the same transaction.

  ## Examples

      iex> pause_former_member_endpoints(user.id, [board.id])
      1

  """
  @spec pause_former_member_endpoints(integer(), [integer()] | Ecto.Query.t()) ::
          non_neg_integer()
  def pause_former_member_endpoints(user_id, boards) when is_integer(user_id) do
    lost_board_ids =
      Endpoint
      |> where([e], e.enabled and e.created_by_id == ^user_id)
      |> on_boards(boards)
      |> distinct(true)
      |> select([e], e.board_id)
      |> Repo.all()
      |> Enum.reject(&Policy.effective_board_access(&1, user_id))

    pause_creator_endpoints(user_id, lost_board_ids)
  end

  @doc """
  Disables the enabled endpoints on `board_id` whose creator is not a member
  of `organization_id`, or is gone, and returns how many. Call it inside the
  transaction that moves the board into the Organization.

  ## Examples

      iex> pause_outside_endpoints(board.id, organization.id)
      1

  """
  @spec pause_outside_endpoints(integer(), integer()) :: non_neg_integer()
  def pause_outside_endpoints(board_id, organization_id)
      when is_integer(board_id) and is_integer(organization_id) do
    members =
      from(m in OrganizationMember,
        where: m.organization_id == ^organization_id,
        select: m.user_id
      )

    Endpoint
    |> where([e], e.board_id == ^board_id and e.enabled)
    |> where([e], is_nil(e.created_by_id) or e.created_by_id not in subquery(members))
    |> pause_all()
  end

  defp on_boards(query, :all), do: query
  defp on_boards(query, ids) when is_list(ids), do: where(query, [e], e.board_id in ^ids)
  defp on_boards(query, %Ecto.Query{} = ids), do: where(query, [e], e.board_id in subquery(ids))

  defp pause_all(query) do
    {count, _} =
      Repo.update_all(query,
        set: [enabled: false, updated_at: DateTime.utc_now(:second)],
        inc: [lock_version: 1]
      )

    count
  end

  defp creator_on_enable(changeset, scope) do
    case {Changeset.get_change(changeset, :enabled), scope_user(scope)} do
      {true, %{id: user_id}} -> Changeset.put_change(changeset, :created_by_id, user_id)
      _unchanged -> changeset
    end
  end

  # Read by board id, so a preloaded workspace can never decide it.
  defp check_plan(board_id), do: Plans.check_board(board_id, :integrations, surface: :context)

  defp check_enabled(%Endpoint{enabled: true}), do: :ok
  defp check_enabled(%Endpoint{}), do: {:error, :disabled}

  defp check_reachable(%Changeset{valid?: true} = changeset, opts) do
    case Changeset.get_change(changeset, :url) do
      nil -> changeset
      url -> add_reachability_error(changeset, UrlGuard.check(url, opts))
    end
  end

  defp check_reachable(changeset, _opts), do: changeset

  defp add_reachability_error(changeset, {:ok, _resolved}), do: changeset

  defp add_reachability_error(changeset, {:error, reason}),
    do: Changeset.add_error(changeset, :url, UrlGuard.error_message(reason), reason: reason)

  defp reveal({:ok, %Endpoint{secret: secret} = endpoint}),
    do: {:ok, {%{endpoint | secret: nil}, secret}}

  defp reveal(error), do: error

  defp authorize_owner(scope, board_id) do
    case scope_user(scope) do
      nil -> {:error, :unauthorized}
      user -> if Boards.owner?(%Board{id: board_id}, user), do: :ok, else: {:error, :unauthorized}
    end
  end

  # Explicit opts win over the configured resolver.
  defp guard_opts(opts), do: Keyword.merge(configured_guard_opts(), opts)

  defp configured_guard_opts do
    case Application.get_env(:kanban, __MODULE__, [])[:resolver] do
      {module, function} -> [resolver: &apply(module, function, [&1])]
      nil -> []
    end
  end

  defp scope_user(%Scope{user: %{id: _} = user}), do: user
  defp scope_user(_scope), do: nil
end
