defmodule Kanban.SCIM.ScimToken do
  @moduledoc """
  An Organization-scoped bearer token for SCIM provisioning (W2247).

  Only the SHA-256 hash of the token is stored, exactly as for API tokens
  (`Kanban.ApiTokens.ApiToken.hash_token_string/1`). The plaintext lives in
  the virtual `:token` field of the changeset that created it and is shown to
  the org-admin once. Tokens start with `stride_scim_`, so a leaked one is
  easy to recognise, and they are looked up only in this table: an API token
  is never accepted by `/scim/v2`, nor a SCIM token by `/api`.

  `organization_id` and `created_by_id` are set by the context, never cast.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.ChangesetText
  alias Kanban.Organizations.Organization

  @prefix "stride_scim_"

  @type t :: %__MODULE__{}

  schema "scim_tokens" do
    field :name, :string
    field :token, :string, virtual: true, redact: true
    field :token_hash, :string, redact: true
    field :last_used_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :organization, Organization
    belongs_to :created_by, User

    timestamps(type: :utc_datetime)
  end

  @doc "A changeset for the token form, with nothing generated."
  @spec form_changeset(map()) :: Ecto.Changeset.t()
  def form_changeset(attrs \\ %{}) do
    %__MODULE__{}
    |> cast(attrs, [:name])
    |> validate_name()
  end

  @doc """
  A changeset for a new token of the Organization with `organization_id`,
  created by the user with `created_by_id`. Generates the plaintext token
  into the virtual `:token` field and stores only its hash.
  """
  @spec create_changeset(integer(), integer(), map()) :: Ecto.Changeset.t()
  def create_changeset(organization_id, created_by_id, attrs)
      when is_integer(organization_id) and is_integer(created_by_id) do
    token = @prefix <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    %__MODULE__{organization_id: organization_id, created_by_id: created_by_id}
    |> cast(attrs, [:name])
    |> validate_name()
    |> put_change(:token, token)
    |> put_change(:token_hash, hash(token))
    |> unique_constraint(:token_hash)
  end

  @doc "The stored hash of a presented token."
  @spec hash(String.t()) :: String.t()
  def hash(token) when is_binary(token), do: ApiToken.hash_token_string(token)

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> ChangesetText.validate_storable([:name])
    |> ChangesetText.validate_visible([:name])
    |> validate_length(:name, max: 100)
  end
end
