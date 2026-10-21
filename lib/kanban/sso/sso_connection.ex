defmodule Kanban.SSO.SSOConnection do
  @moduledoc """
  An Organization's identity provider connection.

  One row per Organization and protocol. Only `:oidc` is implemented (W2245);
  `:saml` is reserved for W2246. The `client_secret` is encrypted at rest
  (`Kanban.Encryption.EncryptedBinary`) and redacted from inspection, and the
  org console never renders it back: a blank secret in the form keeps the
  stored one.

  Managed by `Kanban.SSO`.
  """

  use Ecto.Schema
  use Gettext, backend: KanbanWeb.Gettext

  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization

  @type t :: %__MODULE__{}

  schema "sso_connections" do
    belongs_to :organization, Organization
    field :protocol, Ecto.Enum, values: [:oidc, :saml]
    field :issuer, :string
    field :client_id, :string
    field :client_secret, Kanban.Encryption.EncryptedBinary, redact: true
    field :settings, :map, default: %{}
    field :enabled, :boolean, default: false
    belongs_to :updated_by, User

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for an OIDC connection. The Organization, protocol and
  `updated_by` are set by the caller, never cast. `client_secret` is cast only
  when it is a non-blank string, so leaving the field empty keeps the stored
  secret; a new connection must have one.
  """
  @spec oidc_changeset(t(), map()) :: Ecto.Changeset.t()
  def oidc_changeset(%__MODULE__{} = connection, attrs) do
    connection
    |> cast(attrs, [:issuer, :client_id, :enabled])
    |> cast_secret(attrs)
    |> update_change(:issuer, &String.trim/1)
    |> update_change(:client_id, &String.trim/1)
    |> validate_required([:issuer, :client_id, :client_secret])
    |> validate_length(:issuer, max: 2048)
    |> validate_length(:client_id, max: 1024)
    |> validate_length(:client_secret, max: 4096)
    |> validate_issuer()
    |> unique_constraint([:organization_id, :protocol])
  end

  defp cast_secret(changeset, attrs) do
    case Map.get(attrs, "client_secret", Map.get(attrs, :client_secret)) do
      secret when is_binary(secret) ->
        case String.trim(secret) do
          "" -> changeset
          trimmed -> put_change(changeset, :client_secret, trimmed)
        end

      _blank ->
        changeset
    end
  end

  # The issuer must be an absolute https URL without userinfo, query or
  # fragment; plain http is accepted only where Kanban.SSO allows private
  # issuers (development, for a local identity provider).
  defp validate_issuer(changeset) do
    validate_change(changeset, :issuer, fn :issuer, issuer ->
      if valid_issuer?(issuer, Kanban.SSO.allow_private_issuers?()),
        do: [],
        else: [issuer: gettext("must be an https URL such as https://login.example.com")]
    end)
  end

  defp valid_issuer?(issuer, allow_http?) do
    case URI.new(issuer) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when is_binary(host) and host != "" ->
        scheme == "https" or (allow_http? and scheme == "http")

      _invalid ->
        false
    end
  end
end
