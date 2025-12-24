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

  Returns {:ok, api_token} if found and active, {:error, :not_found} if not found,
  and {:error, :revoked} if the token has been revoked.

  ## Examples

      iex> get_api_token_by_token("kan_dev_abc123")
      {:ok, %ApiToken{}}

      iex> get_api_token_by_token("invalid")
      {:error, :not_found}

  """
  def get_api_token_by_token(token) when is_binary(token) do
    token_hash = ApiToken.hash_token_string(token)

    query =
      from t in ApiToken,
        where: t.token_hash == ^token_hash,
        preload: [:user, :board]

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %ApiToken{revoked_at: nil} = api_token ->
        update_last_used(api_token)
        {:ok, api_token}

      %ApiToken{} ->
        {:error, :revoked}
    end
  end

  @doc """
  Creates an api_token for a user and board.

  Returns {:ok, {api_token, plain_text_token}} on success.
  The plain_text_token should be shown to the user once and never stored.

  ## Examples

      iex> create_api_token(user, board, %{name: "My Token", scopes: ["tasks:read"]})
      {:ok, {%ApiToken{}, "stride_dev_abc123..."}}

      iex> create_api_token(user, board, %{name: ""})
      {:error, %Ecto.Changeset{}}

  """
  def create_api_token(user, board, attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Map.new()
      |> Map.put("user_id", user.id)
      |> Map.put("board_id", board.id)

    changeset = ApiToken.changeset(%ApiToken{}, attrs)

    case Repo.insert(changeset) do
      {:ok, api_token} ->
        plain_text_token = Ecto.Changeset.get_change(changeset, :token)

        :telemetry.execute(
          [:kanban, :api, :token_created],
          %{count: 1},
          %{user_id: user.id, board_id: board.id, token_id: api_token.id}
        )

        {:ok, {api_token, plain_text_token}}

      {:error, changeset} ->
        {:error, changeset}
    end
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

        result

      error ->
        error
    end
  end

  @doc """
  Deletes an api_token.

  ## Examples

      iex> delete_api_token(api_token)
      {:ok, %ApiToken{}}

      iex> delete_api_token(api_token)
      {:error, %Ecto.Changeset{}}

  """
  def delete_api_token(%ApiToken{} = api_token) do
    Repo.delete(api_token)
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

end
