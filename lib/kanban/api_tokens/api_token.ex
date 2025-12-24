defmodule Kanban.ApiTokens.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  @token_prefix "stride"

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :string
    field :agent_capabilities, {:array, :string}, default: []
    field :agent_model, :string
    field :agent_version, :string
    field :agent_purpose, :string
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :token, :string, virtual: true

    belongs_to :user, Kanban.Accounts.User
    belongs_to :board, Kanban.Boards.Board

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [
      :name,
      :agent_capabilities,
      :agent_model,
      :agent_version,
      :agent_purpose,
      :user_id,
      :board_id
    ])
    |> validate_required([:name, :user_id, :board_id])
    |> generate_token()
    |> hash_token()
  end

  @doc false
  def revoke_changeset(api_token) do
    api_token
    |> change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc false
  def update_last_used_changeset(api_token) do
    api_token
    |> change(last_used_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp generate_token(changeset) do
    if changeset.valid? and is_nil(get_field(changeset, :token)) do
      env = Application.get_env(:kanban, :env, :dev)
      random = :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
      token = "#{@token_prefix}_#{env}_#{random}"
      put_change(changeset, :token, token)
    else
      changeset
    end
  end

  defp hash_token(changeset) do
    case get_change(changeset, :token) do
      nil ->
        changeset

      token ->
        hash = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
        put_change(changeset, :token_hash, hash)
    end
  end

  @doc """
  Hashes a token string for lookup in the database.
  """
  def hash_token_string(token) when is_binary(token) do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end
end
