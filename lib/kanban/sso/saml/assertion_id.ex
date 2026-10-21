defmodule Kanban.SSO.SAML.AssertionID do
  @moduledoc """
  The SAML replay cache (W2246): the ID of every assertion accepted through a
  connection, kept until the assertion itself has expired. The unique index on
  the connection and the assertion ID decides even a race, so an assertion is
  accepted at most once. `Kanban.Retention.PurgeWorker` removes expired rows.

  Managed by `Kanban.SSO.SAMLLogin`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.SSO.SSOConnection

  @type t :: %__MODULE__{}

  schema "saml_assertion_ids" do
    belongs_to :sso_connection, SSOConnection
    field :assertion_id, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "A changeset recording `assertion_id` for `connection` until `expires_at`."
  @spec new_changeset(SSOConnection.t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def new_changeset(%SSOConnection{id: connection_id}, assertion_id, %DateTime{} = expires_at)
      when is_binary(assertion_id) do
    %__MODULE__{}
    |> change(
      sso_connection_id: connection_id,
      assertion_id: assertion_id,
      expires_at: DateTime.truncate(expires_at, :second)
    )
    |> validate_length(:assertion_id, min: 1, max: 256)
    |> unique_constraint([:sso_connection_id, :assertion_id])
  end
end
