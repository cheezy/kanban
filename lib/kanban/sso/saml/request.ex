defmodule Kanban.SSO.SAML.Request do
  @moduledoc """
  One SP-initiated SAML sign-in (W2246).

  `relay_token` is the RelayState sent to the identity provider and echoed
  back on its POST to the assertion consumer service, where the request is
  looked up by it, never through the session cookie (a SameSite=Lax browser
  does not send it on that cross-site POST). `request_id` is the AuthnRequest
  ID the assertion's `InResponseTo` must name, and `return_to` the local path
  the person goes to after signing in. A request expires after a few minutes,
  is consumed by the first assertion accepted for it, and is removed by
  `Kanban.Retention.PurgeWorker` once expired.

  Managed by `Kanban.SSO.SAMLLogin`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Kanban.SSO.SSOConnection

  @type t :: %__MODULE__{}

  schema "saml_requests" do
    belongs_to :sso_connection, SSOConnection
    field :request_id, :string
    field :relay_token, :string
    field :return_to, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  A changeset for a new request. Every field comes from server-side values,
  so nothing is cast.
  """
  @spec new_changeset(SSOConnection.t(), map()) :: Ecto.Changeset.t()
  def new_changeset(%SSOConnection{id: connection_id}, attrs) when is_map(attrs) do
    %__MODULE__{}
    |> change(
      sso_connection_id: connection_id,
      request_id: attrs.request_id,
      relay_token: attrs.relay_token,
      return_to: attrs.return_to,
      expires_at: attrs.expires_at
    )
    |> validate_length(:return_to, max: 2048)
    |> unique_constraint(:request_id)
    |> unique_constraint(:relay_token)
  end
end
