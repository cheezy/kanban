defmodule Kanban.Webhooks do
  @moduledoc """
  Outbound webhook endpoints for a board (W2226).

  Only the board's owner can see or manage its endpoints: every function
  takes the caller's `%Kanban.Accounts.Scope{}` first and checks
  `Kanban.Boards.owner?/2`. A member with modify or read-only access gets
  `{:error, :unauthorized}` from a write, `{:error, :not_found}` from
  `get_endpoint/3` and an empty list from `list_endpoints/2`.

  The signing secret is revealed exactly once, as the second element of the
  `{:ok, {endpoint, secret}}` that `create_endpoint/4` and `rotate_secret/2`
  return. It is stored only as `Kanban.Integrations.SecretBox` ciphertext, and
  a rotation overwrites the old ciphertext, so the old secret cannot be
  recovered from the database. A backup taken before the rotation still holds
  the old ciphertext, which the same `secret_key_base` decrypts.
  `signing_secret/1` decrypts the secret for the delivery worker.

  A new or changed URL must pass `Kanban.Webhooks.UrlGuard.check/2`, which
  resolves its host. The `opts` of `create_endpoint/4` and
  `update_endpoint/4` are passed to it (tests inject `:resolver`).

  Related modules: `Kanban.Webhooks.Endpoint` and `Kanban.Webhooks.Delivery`
  (schemas), `Kanban.Webhooks.Signer` (the signature header) and
  `Kanban.Webhooks.UrlGuard` (SSRF protection).
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Integrations.SecretBox
  alias Kanban.Repo
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.UrlGuard

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
    with :ok <- authorize_owner(scope, board_id) do
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
  is checked again with `UrlGuard.check/2`. An endpoint deleted since it was
  loaded yields `{:error, changeset}` with an error on `:id`.
  """
  def update_endpoint(scope, %Endpoint{board_id: board_id} = endpoint, attrs, opts \\ []) do
    with :ok <- authorize_owner(scope, board_id) do
      endpoint
      |> Endpoint.changeset(attrs, opts)
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
    with :ok <- authorize_owner(scope, board_id) do
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

  defp scope_user(%Scope{user: %{id: _} = user}), do: user
  defp scope_user(_scope), do: nil
end
