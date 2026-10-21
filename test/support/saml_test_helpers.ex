defmodule Kanban.SAMLTestHelpers do
  @moduledoc """
  A stand-in SAML identity provider for tests (W2246): an RSA key with a
  self-signed certificate, and signed SAML responses built from it.

      idp = SAMLTestHelpers.idp()
      connection = SSOFixtures.saml_connection_fixture(organization, idp.pem)
      response = SAMLTestHelpers.response(idp, request_id: id, email: "pat@" <> domain)

  `response/2` signs with exclusive canonicalization as `simple_xml`
  computes it, so the fixtures are deterministic; `raw_response/2` returns the
  XML before base64 so a test can tamper with it, and `encode/1` re-encodes.
  """

  alias Kanban.SSO.SAML
  alias SimpleXml.XmlNode

  @assertion_ns "urn:oasis:names:tc:SAML:2.0:assertion"
  @protocol_ns "urn:oasis:names:tc:SAML:2.0:protocol"
  @ds_ns "http://www.w3.org/2000/09/xmldsig#"
  @exc_c14n "http://www.w3.org/2001/10/xml-exc-c14n#"
  @enveloped "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
  @rsa_sha256 "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
  @sha256 "http://www.w3.org/2001/04/xmlenc#sha256"
  @success "urn:oasis:names:tc:SAML:2.0:status:Success"

  @issuer "https://idp.example.com/saml"
  @sso_url "https://idp.example.com/saml/sso"

  def issuer, do: @issuer
  def sso_url, do: @sso_url

  @doc "A fresh signing key and its self-signed certificate in PEM."
  def idp do
    key = X509.PrivateKey.new_rsa(2048)
    certificate = X509.Certificate.self_signed(key, "/CN=Test SAML IdP")
    %{key: key, pem: X509.Certificate.to_pem(certificate)}
  end

  @doc """
  IdP metadata XML for `idp` (and optionally a second certificate), with an
  HTTP-Redirect single sign-on service.
  """
  def idp_metadata(pems, opts \\ []) do
    entity_id = Keyword.get(opts, :entity_id, @issuer)
    key_descriptors = pems |> List.wrap() |> Enum.map_join(&key_descriptor/1)

    ~s(<?xml version="1.0"?><md:EntityDescriptor xmlns:md="urn:oasis:names:tc:SAML:2.0:metadata" ) <>
      ~s(xmlns:ds="#{@ds_ns}" entityID="#{entity_id}">) <>
      ~s(<md:IDPSSODescriptor protocolSupportEnumeration="#{@protocol_ns}">) <>
      key_descriptors <>
      ~s(<md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST" Location="https://idp.example.com/saml/post"/>) <>
      ~s(<md:SingleSignOnService Binding="urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect" Location="#{@sso_url}"/>) <>
      ~s(</md:IDPSSODescriptor></md:EntityDescriptor>)
  end

  defp key_descriptor(pem) do
    ~s(<md:KeyDescriptor use="signing"><ds:KeyInfo><ds:X509Data><ds:X509Certificate>) <>
      der_base64(pem) <>
      ~s(</ds:X509Certificate></ds:X509Data></ds:KeyInfo></md:KeyDescriptor>)
  end

  @doc "The base64 DER body of a PEM certificate, as metadata carries it."
  def der_base64(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    Base.encode64(der)
  end

  @doc """
  A signed, base64-encoded SAML response. Options:

    * `:organization_id` (required unless `:service_provider` is given)
    * `:request_id` — the InResponseTo (default a fresh id)
    * `:email`, `:name_id` (default the email), `:name`
    * `:sign` — `:assertion` (default), `:response`, `:both` or `:none`
    * `:issuer`, `:audience`, `:recipient`, `:destination`, `:status`,
      `:assertion_id`, `:not_before`, `:not_on_or_after` (DateTimes)
    * `:attributes` — extra `{name, value}` pairs
    * `:edit_assertion` — a function applied to the assertion node before it
      is signed, to build a well-signed but unusual assertion
  """
  def response(idp, opts), do: idp |> raw_response(opts) |> encode()

  @doc "Base64-encodes a response XML string."
  def encode(xml), do: Base.encode64(xml)

  @doc "The signed response XML, before base64 (see `response/2`)."
  def raw_response(idp, opts) do
    idp |> response_node(opts) |> XmlNode.to_string()
  end

  @doc "The response as a DOM tuple, signed per `:sign`."
  def response_node(idp, opts) do
    sp = service_provider(opts)
    request_id = Keyword.get_lazy(opts, :request_id, &SAML.new_request_id/0)
    sign = Keyword.get(opts, :sign, :assertion)

    assertion =
      opts
      |> assertion_node(sp, request_id)
      |> Keyword.get(opts, :edit_assertion, & &1).()
      |> maybe_sign(idp.key, sign in [:assertion, :both])

    opts
    |> response_envelope(sp, request_id, assertion)
    |> maybe_sign(idp.key, sign in [:response, :both])
  end

  defp response_envelope(opts, sp, request_id, assertion) do
    status = Keyword.get(opts, :status, @success)

    {"samlp:Response",
     [
       {"xmlns:samlp", @protocol_ns},
       {"xmlns:saml", @assertion_ns},
       {"ID", random_id("_resp", 8)},
       {"Version", "2.0"},
       {"IssueInstant", iso(DateTime.utc_now())},
       {"Destination", Keyword.get(opts, :destination, sp.acs_url)},
       {"InResponseTo", request_id}
     ],
     [
       {"saml:Issuer", [], [Keyword.get(opts, :issuer, @issuer)]},
       {"samlp:Status", [], [{"samlp:StatusCode", [{"Value", status}], []}]},
       assertion
     ]}
  end

  defp random_id(prefix, bytes),
    do: prefix <> (bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

  defp service_provider(opts) do
    Keyword.get_lazy(opts, :service_provider, fn ->
      opts |> Keyword.fetch!(:organization_id) |> SAML.service_provider()
    end)
  end

  defp assertion_node(opts, sp, request_id) do
    now = DateTime.utc_now()
    email = Keyword.get(opts, :email, "pat@example.com")
    not_on_or_after = opts |> Keyword.get(:not_on_or_after, DateTime.add(now, 300)) |> iso()
    assertion_id = Keyword.get_lazy(opts, :assertion_id, fn -> random_id("_a", 10) end)

    {"saml:Assertion",
     [
       {"xmlns:saml", @assertion_ns},
       {"ID", assertion_id},
       {"Version", "2.0"},
       {"IssueInstant", iso(now)}
     ],
     [
       {"saml:Issuer", [], [Keyword.get(opts, :issuer, @issuer)]},
       subject_node(opts, sp, request_id, email, not_on_or_after),
       conditions_node(opts, sp, now, not_on_or_after),
       {"saml:AuthnStatement", [{"AuthnInstant", iso(now)}], []},
       {"saml:AttributeStatement", [], attribute_nodes(opts, email)}
     ]}
  end

  defp subject_node(opts, sp, request_id, email, not_on_or_after) do
    confirmation_data =
      {"saml:SubjectConfirmationData",
       [
         {"InResponseTo", request_id},
         {"NotOnOrAfter", not_on_or_after},
         {"Recipient", Keyword.get(opts, :recipient, sp.acs_url)}
       ], []}

    {"saml:Subject", [],
     [
       {"saml:NameID", [{"Format", "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"}],
        [Keyword.get(opts, :name_id, email)]},
       {"saml:SubjectConfirmation", [{"Method", "urn:oasis:names:tc:SAML:2.0:cm:bearer"}],
        [confirmation_data]}
     ]}
  end

  defp conditions_node(opts, sp, now, not_on_or_after) do
    not_before = opts |> Keyword.get(:not_before, DateTime.add(now, -60)) |> iso()
    audience = Keyword.get(opts, :audience, sp.entity_id)

    {"saml:Conditions", [{"NotBefore", not_before}, {"NotOnOrAfter", not_on_or_after}],
     [{"saml:AudienceRestriction", [], [{"saml:Audience", [], [audience]}]}]}
  end

  defp attribute_nodes(opts, email) do
    [{"email", email}, {"displayName", Keyword.get(opts, :name, "Pat Person")}]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
    |> Kernel.++(Keyword.get(opts, :attributes, []))
    |> Enum.map(fn {name, value} ->
      {"saml:Attribute", [{"Name", name}], [{"saml:AttributeValue", [], [value]}]}
    end)
  end

  defp maybe_sign(node, _key, false), do: node
  defp maybe_sign(node, key, true), do: sign(node, key)

  @doc """
  Signs `node` (an element with an `ID`) with an enveloped signature placed
  after its Issuer, as an identity provider does.
  """
  def sign({tag, attrs, [issuer | rest]} = node, key) do
    {"ID", id} = List.keyfind(attrs, "ID", 0)
    signed_info = signed_info(id, digest(node))

    signature =
      {"ds:Signature", [{"xmlns:ds", @ds_ns}],
       [signed_info, {"ds:SignatureValue", [], [signature_value(signed_info, key)]}]}

    {tag, attrs, [issuer, signature | rest]}
  end

  defp digest(node) do
    node
    |> XmlNode.canonicalize(inclusive_namespaces: [])
    |> XmlNode.to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode64()
  end

  defp signed_info(id, digest) do
    transforms =
      {"ds:Transforms", [],
       [
         {"ds:Transform", [{"Algorithm", @enveloped}], []},
         {"ds:Transform", [{"Algorithm", @exc_c14n}], []}
       ]}

    {"ds:SignedInfo", [],
     [
       {"ds:CanonicalizationMethod", [{"Algorithm", @exc_c14n}], []},
       {"ds:SignatureMethod", [{"Algorithm", @rsa_sha256}], []},
       {"ds:Reference", [{"URI", "#" <> id}],
        [
          transforms,
          {"ds:DigestMethod", [{"Algorithm", @sha256}], []},
          {"ds:DigestValue", [], [digest]}
        ]}
     ]}
  end

  # SignedInfo is canonicalized on its own, so it carries the ds namespace.
  defp signature_value({tag, attrs, children}, key) do
    {tag, [{"xmlns:ds", @ds_ns} | attrs], children}
    |> XmlNode.canonicalize()
    |> XmlNode.to_string()
    |> :public_key.sign(:sha256, key)
    |> Base.encode64()
  end

  defp iso(%DateTime{} = datetime),
    do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  @doc "Inflates the SAMLRequest query parameter of an HTTP-Redirect URL."
  def authn_request_xml(url) do
    %{"SAMLRequest" => encoded} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, -15)
    xml = z |> :zlib.inflate(Base.decode64!(encoded)) |> IO.iodata_to_binary()
    :zlib.close(z)
    xml
  end
end
