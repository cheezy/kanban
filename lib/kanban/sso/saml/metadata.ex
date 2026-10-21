defmodule Kanban.SSO.SAML.Metadata do
  @moduledoc """
  SAML metadata and signing certificates (W2246).

    * `parse_idp/1` reads an identity provider's metadata XML for its entity
      id, its HTTP-Redirect single sign-on URL and its signing certificates.
    * `sp_metadata/1` builds Stride's own service provider metadata for one
      connection.
    * `parse_certificates/1` turns pasted certificates (PEM blocks, or bare
      base64 DER as metadata carries them) into normalized PEM, and
      `public_key/1` reads the RSA key a response signature is checked with.

  Certificates are public, so they are stored in the connection's `settings`
  unencrypted. Only RSA keys of at least 2048 bits are accepted, matching the RSA-SHA256 signatures
  `Kanban.SSO.SAML.XML` allows.
  """

  alias Kanban.SSO.SAML.XML

  @redirect_binding "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
  @post_binding "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
  @protocol "urn:oasis:names:tc:SAML:2.0:protocol"
  @max_certificates 2
  @min_rsa_modulus Bitwise.bsl(1, 2047)

  @type idp :: %{entity_id: String.t(), sso_url: String.t(), certificates: [String.t()]}

  @doc "The most signing certificates a connection keeps (two during a rollover)."
  @spec max_certificates() :: pos_integer()
  def max_certificates, do: @max_certificates

  # --- identity provider metadata ----------------------------------------------

  @doc """
  Reads IdP metadata. Returns `{:ok, idp}` or `{:error, reason}` with reason
  `:too_large`, `:invalid` (unparsable, a DOCTYPE or ENTITY, or no
  `IDPSSODescriptor`), `:missing_sso_url` (no HTTP-Redirect sign-on service)
  or `:invalid_certificate` (none, or one that is not an RSA certificate of
  at least 2048 bits).
  """
  @spec parse_idp(binary()) :: {:ok, idp()} | {:error, atom()}
  def parse_idp(xml) when is_binary(xml) do
    with {:ok, root} <- xml |> String.trim() |> XML.parse_metadata(),
         {:ok, entity} <- entity_descriptor(root),
         {:ok, entity_id} <- entity_id(entity) do
      read_idp_descriptor(entity, entity_id)
    end
  end

  def parse_idp(_xml), do: {:error, :invalid}

  defp read_idp_descriptor(entity, entity_id) do
    with {:ok, idp} <- entity |> XML.child("IDPSSODescriptor") |> invalid_unless_ok(),
         {:ok, sso_url} <- redirect_sso_url(idp),
         {:ok, certificates} <- signing_certificates(idp) do
      {:ok, %{entity_id: entity_id, sso_url: sso_url, certificates: certificates}}
    end
  end

  # A metadata document is either one EntityDescriptor or an EntitiesDescriptor
  # holding several; only one identity provider is accepted.
  defp entity_descriptor(root) do
    case XML.local_name(root) do
      "EntityDescriptor" ->
        {:ok, root}

      "EntitiesDescriptor" ->
        root |> XML.children("EntityDescriptor") |> Enum.filter(&idp_entity?/1) |> only_entity()

      _other ->
        {:error, :invalid}
    end
  end

  defp only_entity([entity]), do: {:ok, entity}
  defp only_entity(_none_or_many), do: {:error, :invalid}

  defp idp_entity?(entity), do: XML.children(entity, "IDPSSODescriptor") != []

  defp entity_id(entity) do
    case entity |> XML.attribute("entityID") |> trimmed() do
      nil -> {:error, :invalid}
      entity_id -> {:ok, entity_id}
    end
  end

  defp invalid_unless_ok({:ok, node}), do: {:ok, node}
  defp invalid_unless_ok(:error), do: {:error, :invalid}

  defp redirect_sso_url(idp) do
    idp
    |> XML.children("SingleSignOnService")
    |> Enum.find_value(fn service ->
      XML.attribute(service, "Binding") == @redirect_binding &&
        trimmed(XML.attribute(service, "Location"))
    end)
    |> case do
      url when is_binary(url) -> {:ok, url}
      _missing -> {:error, :missing_sso_url}
    end
  end

  # Key descriptors without a `use`, or with use="signing", carry signing keys.
  defp signing_certificates(idp) do
    case certificate_texts(idp) do
      [] -> {:error, :invalid_certificate}
      texts -> texts |> Enum.take(@max_certificates) |> Enum.join("\n\n") |> parse_certificates()
    end
  end

  defp certificate_texts(idp) do
    idp
    |> XML.children("KeyDescriptor")
    |> Enum.filter(&signing_key?/1)
    |> Enum.flat_map(&XML.descendants(&1, fn name -> name == "X509Certificate" end))
    |> Enum.map(&XML.all_text/1)
    |> Enum.uniq()
  end

  defp signing_key?(key_descriptor), do: XML.attribute(key_descriptor, "use") in [nil, "signing"]

  # --- certificates ------------------------------------------------------------

  @doc """
  Parses one or more certificates from PEM blocks or bare base64 DER (one per
  block, separated by blank lines or PEM armour). Returns `{:ok, pems}`, each
  normalized to a single PEM block, or `{:error, :invalid_certificate}` when
  there is none, more than `max_certificates/0`, or one is not an RSA
  certificate.
  """
  @spec parse_certificates(term()) :: {:ok, [String.t()]} | {:error, :invalid_certificate}
  def parse_certificates(text) when is_binary(text) do
    with ders when is_list(ders) <- text |> der_blocks() |> within_limit(),
         pems when is_list(pems) <- normalize_all(ders) do
      {:ok, Enum.uniq(pems)}
    else
      _invalid -> {:error, :invalid_certificate}
    end
  end

  def parse_certificates(_text), do: {:error, :invalid_certificate}

  defp within_limit([_ | _] = ders) when length(ders) <= @max_certificates, do: ders
  defp within_limit(_none_or_too_many), do: :error

  defp der_blocks(text) do
    if String.contains?(text, "-----BEGIN") do
      text
      |> :public_key.pem_decode()
      |> Enum.map(fn
        {:Certificate, der, :not_encrypted} -> der
        _other -> :invalid
      end)
    else
      text
      |> String.split(~r/\n\s*\n/, trim: true)
      |> Enum.map(&decode_base64/1)
    end
  rescue
    _error -> [:invalid]
  end

  defp decode_base64(block) do
    case Base.decode64(block, ignore: :whitespace) do
      {:ok, der} -> der
      :error -> :invalid
    end
  end

  defp normalize_all(ders) do
    Enum.reduce_while(ders, [], fn der, acc ->
      case rsa_key(der) do
        {:ok, _key} -> {:cont, acc ++ [to_pem(der)]}
        :error -> {:halt, :error}
      end
    end)
  end

  defp to_pem(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  @doc """
  The RSA public key of a stored PEM certificate, in the form
  `:public_key.verify/4` takes, or `:error`.
  """
  @spec public_key(String.t()) :: {:ok, term()} | :error
  def public_key(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted}] -> rsa_key(der)
      _other -> :error
    end
  rescue
    _error -> :error
  end

  def public_key(_pem), do: :error

  # Only RSA keys of at least 2048 bits are trusted (NIST SP 800-131A).
  defp rsa_key(der) when is_binary(der) do
    {:OTPCertificate, tbs, _algorithm, _signature} = :public_key.pkix_decode_cert(der, :otp)

    case elem(tbs, 7) do
      {:OTPSubjectPublicKeyInfo, _algorithm, {:RSAPublicKey, modulus, _exponent} = key}
      when modulus >= @min_rsa_modulus ->
        {:ok, key}

      _other ->
        :error
    end
  rescue
    _error -> :error
  end

  defp rsa_key(_der), do: :error

  # --- service provider metadata -----------------------------------------------

  @doc """
  Stride's SP metadata for a connection: its entity id and its HTTP-POST
  assertion consumer service. Stride signs no requests and wants assertions
  signed.
  """
  @spec sp_metadata(%{entity_id: String.t(), acs_url: String.t()}) :: String.t()
  def sp_metadata(%{entity_id: entity_id, acs_url: acs_url}) do
    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" entityID="#{escape(entity_id)}">) <>
      ~s(<md:SPSSODescriptor AuthnRequestsSigned="false" WantAssertionsSigned="true" protocolSupportEnumeration="#{@protocol}">) <>
      ~s(<md:NameIDFormat>urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress</md:NameIDFormat>) <>
      ~s(<md:NameIDFormat>urn:oasis:names:tc:SAML:2.0:nameid-format:persistent</md:NameIDFormat>) <>
      ~s(<md:AssertionConsumerService Binding="#{@post_binding}" Location="#{escape(acs_url)}" index="0" isDefault="true"/>) <>
      ~s(</md:SPSSODescriptor></md:EntityDescriptor>)
  end

  @doc "Escapes a value for an XML attribute or text node."
  @spec escape(String.t()) :: String.t()
  def escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil
end
