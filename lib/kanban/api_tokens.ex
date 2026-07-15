defmodule Kanban.ApiTokens do
  @moduledoc """
  The ApiTokens context for managing API authentication tokens.
  """

  import Ecto.Query, warn: false

  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Repo

  @doc """
  Returns the list of api_tokens for a board.

  ## Examples

      iex> list_api_tokens(board)
      [%ApiToken{}, ...]

  """
  def list_api_tokens(board) do
    ApiToken
    |> where([t], t.board_id == ^board.id)
    |> order_by([t], desc: t.inserted_at)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Gets a single api_token.

  Raises `Ecto.NoResultsError` if the Api token does not exist.

  ## Examples

      iex> get_api_token!(123)
      %ApiToken{}

      iex> get_api_token!(456)
      ** (Ecto.NoResultsError)

  """
  def get_api_token!(id), do: Repo.get!(ApiToken, id)

  @doc """
  Gets an active (non-revoked) API token by its token string.

  Returns `{:ok, api_token}` if found and active, `{:error, :not_found}` if not
  found, `{:error, :revoked}` if the token has been revoked, `{:error, :expired}`
  if it has expired, and `{:error, :user_disabled}` if the token is valid but its
  owner is disabled — a disabled account must not keep API access through a token
  issued before it was disabled.

  ## Examples

      iex> get_api_token_by_token("kan_dev_abc123")
      {:ok, %ApiToken{}}

      iex> get_api_token_by_token("invalid")
      {:error, :not_found}

      iex> get_api_token_by_token("token_of_a_disabled_user")
      {:error, :user_disabled}

  """
  def get_api_token_by_token(token) when is_binary(token) do
    token_hash = ApiToken.hash_token_string(token)

    query =
      from t in ApiToken,
        where: t.token_hash == ^token_hash,
        preload: [:user, :board]

    # Dummy query used to normalize timing across all code paths,
    # preventing side-channel attacks that distinguish token states.
    timing_query = from t in ApiToken, where: t.id == -1, select: count()

    case Repo.one(query) do
      nil -> reject_with_timing(timing_query, :not_found)
      %ApiToken{revoked_at: nil} = api_token -> authorize_token(api_token, timing_query)
      %ApiToken{} -> reject_with_timing(timing_query, :revoked)
    end
  end

  # D107: every rejection runs the dummy query so the response time does not
  # distinguish a not-found token from a revoked, expired, or disabled-owner one.
  defp reject_with_timing(timing_query, reason) do
    Repo.one(timing_query)
    {:error, reason}
  end

  defp authorize_token(%ApiToken{} = api_token, timing_query) do
    cond do
      ApiToken.expired?(api_token) ->
        reject_with_timing(timing_query, :expired)

      not is_nil(api_token.user.disabled_at) ->
        reject_with_timing(timing_query, :user_disabled)

      true ->
        update_last_used(api_token)
        {:ok, api_token}
    end
  end

  @doc """
  Creates an api_token for a user and board.

  Returns {:ok, {api_token, plain_text_token}} on success.
  The plain_text_token should be shown to the user once and never stored.

  ## Examples

      iex> create_api_token(user, board, %{name: "My Token", agent_capabilities: ["code_generation"]})
      {:ok, {%ApiToken{}, "stride_dev_abc123..."}}

      iex> create_api_token(user, board, %{name: ""})
      {:error, %Ecto.Changeset{}}

  """
  def create_api_token(user, board, attrs \\ %{}) do
    attrs = normalize_api_token_attrs(attrs, user, board)
    changeset = ApiToken.changeset(%ApiToken{}, attrs)

    case Repo.insert(changeset) do
      {:ok, api_token} ->
        plain_text_token = Ecto.Changeset.get_change(changeset, :token)

        :telemetry.execute(
          [:kanban, :api, :token_created],
          %{count: 1},
          %{user_id: user.id, board_id: board.id, token_id: api_token.id}
        )

        Kanban.AuditLog.event(:api_token_created,
          user_id: user.id,
          board_id: board.id,
          token_id: api_token.id
        )

        {:ok, {api_token, plain_text_token}}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp normalize_api_token_attrs(attrs, user, board) do
    attrs
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
    |> Map.put("user_id", user.id)
    |> Map.put("board_id", board.id)
  end

  @doc """
  Revokes an api_token.

  ## Examples

      iex> revoke_api_token(api_token)
      {:ok, %ApiToken{}}

      iex> revoke_api_token(api_token)
      {:error, %Ecto.Changeset{}}

  """
  def revoke_api_token(%ApiToken{} = api_token) do
    api_token
    |> ApiToken.revoke_changeset()
    |> Repo.update()
    |> case do
      {:ok, api_token} = result ->
        :telemetry.execute(
          [:kanban, :api, :token_revoked],
          %{count: 1},
          %{user_id: api_token.user_id, token_id: api_token.id}
        )

        Kanban.AuditLog.event(:api_token_revoked,
          user_id: api_token.user_id,
          token_id: api_token.id
        )

        result

      error ->
        error
    end
  end

  @doc """
  Deletes an API token.

  ## Examples

      iex> delete_api_token(api_token)
      {:ok, %ApiToken{}}

      iex> delete_api_token(api_token)
      {:error, %Ecto.Changeset{}}

  """
  def delete_api_token(%ApiToken{} = api_token) do
    api_token
    |> Repo.delete()
    |> case do
      {:ok, api_token} = result ->
        :telemetry.execute(
          [:kanban, :api, :token_deleted],
          %{count: 1},
          %{user_id: api_token.user_id, token_id: api_token.id}
        )

        result

      error ->
        error
    end
  end

  @doc """
  Revokes every active (non-revoked) API token belonging to `user_id` that is
  scoped to `board_id`.

  Used when a user is removed from a board or downgraded to `:read_only`, so a
  board-bound token cannot outlive the access grant that justified it (W1430).
  Already-revoked tokens are left untouched. Safe to run inside an
  `Ecto.Multi`/transaction — it issues a single `update_all`.

  Returns `{count, nil}` where `count` is the number of tokens revoked.

  ## Examples

      iex> revoke_user_tokens_for_board(board.id, user.id)
      {2, nil}

  """
  def revoke_user_tokens_for_board(board_id, user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in ApiToken,
      where: t.board_id == ^board_id and t.user_id == ^user_id and is_nil(t.revoked_at)
    )
    |> Repo.update_all(set: [revoked_at: now])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking api_token changes.

  ## Examples

      iex> change_api_token(api_token)
      %Ecto.Changeset{data: %ApiToken{}}

  """
  def change_api_token(%ApiToken{} = api_token, attrs \\ %{}) do
    ApiToken.changeset(api_token, attrs)
  end

  @doc """
  Updates the last_used_at timestamp for an API token.
  This is called automatically when a token is successfully used for authentication.
  """
  def update_last_used(%ApiToken{} = api_token) do
    api_token
    |> ApiToken.update_last_used_changeset()
    |> Repo.update()

    :telemetry.execute(
      [:kanban, :api, :token_used],
      %{count: 1},
      %{user_id: api_token.user_id, token_id: api_token.id}
    )
  end

  @unknown_agent_name "Unknown"

  @doc """
  Returns true when `agent_name` is a usable display name: a non-blank binary
  that is not the `"Unknown"` claim/complete fallback literal (D137).
  """
  def usable_agent_name?(agent_name) when is_binary(agent_name) do
    String.trim(agent_name) != "" and agent_name != @unknown_agent_name
  end

  def usable_agent_name?(_agent_name), do: false

  @doc """
  Best-effort stamp of the last usable agent name presented by this token
  (D137). Follows `update_last_used/1`: the `Repo.update` result is discarded
  so a failed stamp (e.g. an over-length name rejected by the changeset) never
  fails the parent API request. No-op unless `usable_agent_name?/1`.
  """
  def stamp_last_agent_name(%ApiToken{} = api_token, agent_name) do
    if usable_agent_name?(agent_name) do
      api_token
      |> ApiToken.update_last_agent_name_changeset(agent_name)
      |> Repo.update()
    end

    :ok
  end
end
