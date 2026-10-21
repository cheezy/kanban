defmodule Kanban.SSO.SSOConnection do
  @moduledoc """
  An Organization's identity provider connection.

  One row per Organization and protocol: `:oidc` (W2245) or `:saml` (W2246).
  The OIDC `client_secret` is encrypted at rest
  (`Kanban.Encryption.EncryptedBinary`) and redacted from inspection, and the
  org console never renders it back: a blank secret in the form keeps the
  stored one.

  A SAML connection keeps the identity provider's entity id in `issuer` and
  its single sign-on URL and signing certificates (public, PEM, at most two
  for a rollover) in `settings`; it has no client id or secret. The form
  fills them from IdP metadata XML or from the fields typed in, through the
  virtual fields `idp_metadata`, `sso_url` and `certificates_pem`.

  Managed by `Kanban.SSO`.
  """

  use Ecto.Schema
  use Gettext, backend: KanbanWeb.Gettext

  import Ecto.Changeset

  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization
  alias Kanban.SSO.SAML.Metadata

  @type t :: %__MODULE__{}

  schema "sso_connections" do
    belongs_to :organization, Organization
    field :protocol, Ecto.Enum, values: [:oidc, :saml]
    field :issuer, :string
    field :client_id, :string
    field :client_secret, Kanban.Encryption.EncryptedBinary, redact: true
    field :settings, :map, default: %{}
    field :enabled, :boolean, default: false
    field :idp_metadata, :string, virtual: true
    field :sso_url, :string, virtual: true
    field :certificates_pem, :string, virtual: true
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

  @doc """
  A changeset for a SAML connection. The Organization, protocol and
  `updated_by` are set by the caller, never cast. Non-blank `idp_metadata`
  fills the entity id, sign-on URL and certificates; otherwise they come from
  `issuer`, `sso_url` and `certificates_pem`. Blank certificates keep the
  stored ones.
  """
  @spec saml_changeset(t(), map()) :: Ecto.Changeset.t()
  def saml_changeset(%__MODULE__{} = connection, attrs) do
    connection
    |> with_saml_fields()
    |> cast(attrs, [:issuer, :enabled, :idp_metadata, :sso_url, :certificates_pem])
    |> apply_idp_metadata()
    |> validate_saml_endpoints()
    |> put_certificates()
    |> put_saml_settings()
    |> unique_constraint([:organization_id, :protocol])
  end

  defp validate_saml_endpoints(changeset) do
    changeset
    |> update_change(:issuer, &String.trim/1)
    |> update_change(:sso_url, &String.trim/1)
    |> validate_required([:issuer, :sso_url])
    |> validate_length(:issuer, max: 1024)
    |> validate_format(:issuer, ~r/\A\S+\z/, message: gettext("must not contain spaces"))
    |> validate_length(:sso_url, max: 2048)
    |> validate_change(:sso_url, &validate_sso_url/2)
  end

  @doc "Fills the SAML form's virtual fields from the stored settings."
  @spec with_saml_fields(t()) :: t()
  def with_saml_fields(%__MODULE__{settings: settings} = connection) do
    settings = settings || %{}

    %{
      connection
      | sso_url: settings["sso_url"],
        certificates_pem: settings |> Map.get("certificates", []) |> List.wrap() |> Enum.join()
    }
  end

  defp apply_idp_metadata(changeset) do
    case get_change(changeset, :idp_metadata) do
      metadata when is_binary(metadata) and metadata != "" ->
        changeset |> put_change(:idp_metadata, nil) |> merge_metadata(metadata)

      _blank ->
        changeset
    end
  end

  defp merge_metadata(changeset, metadata) do
    case Metadata.parse_idp(metadata) do
      {:ok, idp} ->
        changeset
        |> put_change(:issuer, idp.entity_id)
        |> put_change(:sso_url, idp.sso_url)
        |> put_change(:certificates_pem, Enum.join(idp.certificates))

      {:error, reason} ->
        add_error(changeset, :idp_metadata, metadata_error(reason))
    end
  end

  defp metadata_error(:too_large), do: gettext("is too large")

  defp metadata_error(:missing_sso_url),
    do: gettext("has no single sign-on service with the HTTP-Redirect binding")

  defp metadata_error(:invalid_certificate),
    do: gettext("has no RSA signing certificate Stride can use")

  defp metadata_error(_invalid), do: gettext("is not valid identity provider metadata")

  defp validate_sso_url(:sso_url, url) do
    if valid_issuer?(url, Kanban.SSO.allow_private_issuers?()),
      do: [],
      else: [sso_url: gettext("must be an https URL such as https://login.example.com/saml")]
  end

  # Blank keeps the stored certificates; a new connection must have one.
  defp put_certificates(changeset) do
    case get_change(changeset, :certificates_pem) do
      text when is_binary(text) and text != "" ->
        text |> Metadata.parse_certificates() |> put_parsed_certificates(changeset)

      _blank ->
        changeset
        |> delete_change(:certificates_pem)
        |> validate_required([:certificates_pem])
    end
  end

  defp put_parsed_certificates({:ok, pems}, changeset),
    do: put_change(changeset, :certificates_pem, Enum.join(pems))

  defp put_parsed_certificates({:error, :invalid_certificate}, changeset) do
    add_error(
      changeset,
      :certificates_pem,
      gettext("must be one or two RSA certificates in PEM format")
    )
  end

  defp put_saml_settings(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp put_saml_settings(changeset) do
    pems =
      changeset
      |> get_field(:certificates_pem)
      |> Metadata.parse_certificates()
      |> case do
        {:ok, pems} -> pems
        {:error, _invalid} -> []
      end

    put_change(changeset, :settings, %{
      "sso_url" => get_field(changeset, :sso_url),
      "certificates" => pems
    })
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
