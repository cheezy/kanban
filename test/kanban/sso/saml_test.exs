defmodule Kanban.SSO.SAMLTest do
  use Kanban.DataCase, async: true

  import Kanban.OrganizationsFixtures
  import Kanban.SSOFixtures

  alias Kanban.SAMLTestHelpers
  alias Kanban.SSO.SAML
  alias Kanban.SSO.SAML.Metadata

  setup_all do
    %{idp: SAMLTestHelpers.idp(), other_idp: SAMLTestHelpers.idp()}
  end

  setup %{idp: idp} do
    organization = organization_fixture()
    connection = saml_connection_fixture(organization, idp.pem)
    sp = SAML.service_provider(organization.id)
    request_id = SAML.new_request_id()

    %{
      organization: organization,
      connection: connection,
      sp: sp,
      request_id: request_id,
      expected: %{service_provider: sp, request_id: request_id}
    }
  end

  defp opts(ctx, extra \\ []),
    do: extra ++ [organization_id: ctx.organization.id, request_id: ctx.request_id]

  defp validate(ctx, response, connection \\ nil),
    do: SAML.validate_response(response, connection || ctx.connection, ctx.expected)

  defp raw(ctx, extra), do: SAMLTestHelpers.raw_response(ctx.idp, opts(ctx, extra))

  defp tampered(ctx, extra \\ [], fun),
    do: ctx |> raw(extra) |> fun.() |> SAMLTestHelpers.encode()

  describe "validate_response/3 with a valid response" do
    test "a signed fixture assertion parses to its NameID and attributes", ctx do
      response = SAMLTestHelpers.response(ctx.idp, opts(ctx, email: "pat@corp.example"))

      assert {:ok, result} = validate(ctx, response)
      assert result.subject == "pat@corp.example"
      assert result.email == "pat@corp.example"
      assert result.name == "Pat Person"
      assert result.assertion_id =~ ~r/^_a/
      assert DateTime.compare(result.expires_at, DateTime.utc_now()) == :gt
    end

    test "is accepted when only the response is signed", ctx do
      response = SAMLTestHelpers.response(ctx.idp, opts(ctx, sign: :response))
      assert {:ok, _result} = validate(ctx, response)
    end

    test "is accepted when both the response and the assertion are signed", ctx do
      response = SAMLTestHelpers.response(ctx.idp, opts(ctx, sign: :both))
      assert {:ok, _result} = validate(ctx, response)
    end

    test "uses an email attribute over a persistent NameID", ctx do
      response =
        SAMLTestHelpers.response(
          ctx.idp,
          opts(ctx, name_id: "a1b2c3", email: "pat@corp.example", name: nil)
        )

      assert {:ok, %{subject: "a1b2c3", email: "pat@corp.example", name: nil}} =
               validate(ctx, response)
    end

    test "builds a name from given name and surname", ctx do
      response =
        SAMLTestHelpers.response(
          ctx.idp,
          opts(ctx, name: nil, attributes: [{"givenName", "Pat"}, {"sn", "Person"}])
        )

      assert {:ok, %{name: "Pat Person"}} = validate(ctx, response)
    end

    test "accepts a certificate rotation with two certificates", ctx do
      connection =
        saml_connection_fixture(organization_fixture(), [ctx.other_idp.pem, ctx.idp.pem])

      sp = SAML.service_provider(connection.organization_id)

      response =
        SAMLTestHelpers.response(ctx.idp,
          service_provider: sp,
          request_id: ctx.request_id
        )

      assert {:ok, _result} =
               SAML.validate_response(response, connection, %{
                 service_provider: sp,
                 request_id: ctx.request_id
               })
    end

    test "allows a small clock skew", ctx do
      now = DateTime.utc_now()

      response =
        SAMLTestHelpers.response(
          ctx.idp,
          opts(ctx,
            not_before: DateTime.add(now, 60),
            not_on_or_after: DateTime.add(now, -30)
          )
        )

      assert {:ok, _result} = validate(ctx, response)
    end
  end

  describe "validate_response/3 refuses" do
    test "an unsigned response", ctx do
      response = SAMLTestHelpers.response(ctx.idp, opts(ctx, sign: :none))
      assert validate(ctx, response) == {:error, :signature_invalid}
    end

    test "a response signed by another key", ctx do
      response = SAMLTestHelpers.response(ctx.other_idp, opts(ctx))
      assert validate(ctx, response) == {:error, :signature_invalid}
    end

    test "an assertion altered after signing", ctx do
      response =
        tampered(ctx, [email: "pat@corp.example"], fn xml ->
          String.replace(xml, "pat@corp.example", "boss@corp.example")
        end)

      assert validate(ctx, response) == {:error, :signature_invalid}
    end

    test "a forged assertion wrapped before the signed one (signature wrapping)", ctx do
      {tag, attrs, children} = SAMLTestHelpers.response_node(ctx.idp, opts(ctx))
      signed = List.last(children)

      forged =
        ctx.idp
        |> SAMLTestHelpers.response_node(opts(ctx, sign: :none, email: "boss@corp.example"))
        |> elem(2)
        |> List.last()

      wrapped = {tag, attrs, List.insert_at(children, 2, forged)}
      response = wrapped |> SimpleXml.XmlNode.to_string() |> SAMLTestHelpers.encode()
      assert validate(ctx, response) == {:error, :unsafe_xml}

      # The signed assertion moved under another element, the forged one in its place.
      moved =
        {tag, attrs, List.replace_at(children, 2, forged) ++ [{"samlp:Extensions", [], [signed]}]}

      response = moved |> SimpleXml.XmlNode.to_string() |> SAMLTestHelpers.encode()
      assert validate(ctx, response) == {:error, :unsafe_xml}
    end

    test "an assertion-like element the library would match by suffix", ctx do
      response =
        tampered(ctx, fn xml ->
          String.replace(
            xml,
            "<samlp:Status>",
            "<saml:EncryptedAssertion></saml:EncryptedAssertion><samlp:Status>"
          )
        end)

      assert validate(ctx, response) == {:error, :unsafe_xml}
    end

    test "a comment that would truncate the NameID", ctx do
      response =
        tampered(ctx, [email: "pat@corp.example.attacker.example"], fn xml ->
          String.replace(xml, "pat@corp.example.attacker", "pat@corp.example<!---->.attacker")
        end)

      assert validate(ctx, response) == {:error, :unsafe_xml}
    end

    test "a DOCTYPE or external entity (XXE)", ctx do
      xxe =
        ~s(<?xml version="1.0"?><!DOCTYPE r [<!ENTITY x SYSTEM "file:///etc/passwd">]>)

      response = tampered(ctx, &(xxe <> &1))
      assert validate(ctx, response) == {:error, :unsafe_xml}
    end

    test "escaped markup in a value", ctx do
      response =
        tampered(ctx, [name: "Pat"], fn xml ->
          String.replace(xml, ">Pat<", ">Pat&lt;b&gt;<")
        end)

      assert validate(ctx, response) == {:error, :unsafe_xml}
    end

    # The canonicalization keeps the last copy of a repeated attribute and
    # reads return the first, so a copy added in front left the digest as it
    # was while changing what was read.
    test "a display name the user chose, read as the email through a repeated Name", ctx do
      for sign <- [:assertion, :response] do
        response =
          tampered(
            ctx,
            [email: "pat@corp.example", name: "boss@corp.example", sign: sign],
            fn xml ->
              xml
              |> String.replace(
                ~s(<saml:Attribute Name="email">),
                ~s(<saml:Attribute Name="x" Name="email">)
              )
              |> String.replace(
                ~s(<saml:Attribute Name="displayName">),
                ~s(<saml:Attribute Name="email" Name="displayName">)
              )
            end
          )

        assert validate(ctx, response) == {:error, :unsafe_xml}
      end
    end

    test "a repeated NotOnOrAfter or assertion ID added in front of the signed one", ctx do
      far = "2099-01-01T00:00:00Z"

      for {sign, from, to} <- [
            {:assertion, "<saml:SubjectConfirmationData ",
             ~s(<saml:SubjectConfirmationData NotOnOrAfter="#{far}" )},
            {:assertion, "<saml:Conditions ", ~s(<saml:Conditions NotOnOrAfter="#{far}" )},
            {:response, "<saml:Assertion ", ~s(<saml:Assertion ID="_fresh" )}
          ] do
        response = tampered(ctx, [sign: sign], &String.replace(&1, from, to, global: false))
        assert validate(ctx, response) == {:error, :unsafe_xml}
      end
    end

    test "malformed XML and invalid base64", ctx do
      assert validate(ctx, Base.encode64("<samlp:Response")) == {:error, :unsafe_xml}
      assert validate(ctx, "not base64!") == {:error, :invalid_response}
      assert validate(ctx, nil) == {:error, :invalid_response}
    end

    test "a very large payload", ctx do
      padding = String.duplicate("a", SAML.XML.max_response_bytes() + 1)
      assert validate(ctx, Base.encode64(padding)) == {:error, :response_too_large}
    end

    test "a SHA-1 signature", ctx do
      response =
        tampered(ctx, fn xml ->
          String.replace(
            xml,
            "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
            "http://www.w3.org/2000/09/xmldsig#rsa-sha1"
          )
        end)

      assert validate(ctx, response) == {:error, :unsupported_algorithms}
    end

    test "a SHA-1 digest, a missing Transforms list or another transform", ctx do
      edits = [
        &String.replace(
          &1,
          "http://www.w3.org/2001/04/xmlenc#sha256",
          "http://www.w3.org/2000/09/xmldsig#sha1"
        ),
        &Regex.replace(~r{<ds:Transforms>.*?</ds:Transforms>}, &1, ""),
        &String.replace(
          &1,
          "http://www.w3.org/2000/09/xmldsig#enveloped-signature",
          "http://www.w3.org/TR/1999/REC-xpath-19991116"
        )
      ]

      for edit <- edits do
        assert validate(ctx, tampered(ctx, edit)) == {:error, :unsupported_algorithms}
      end
    end

    test "an expired assertion", ctx do
      past = DateTime.add(DateTime.utc_now(), -SAML.skew_seconds() - 60)
      response = SAMLTestHelpers.response(ctx.idp, opts(ctx, not_on_or_after: past))
      assert validate(ctx, response) == {:error, :assertion_expired}
    end

    test "an assertion not yet valid", ctx do
      future = DateTime.add(DateTime.utc_now(), SAML.skew_seconds() + 60)
      response = SAMLTestHelpers.response(ctx.idp, opts(ctx, not_before: future))
      assert validate(ctx, response) == {:error, :assertion_not_yet_valid}
    end

    test "the wrong audience", ctx do
      response = SAMLTestHelpers.response(ctx.idp, opts(ctx, audience: "https://other.example"))
      assert validate(ctx, response) == {:error, :audience_mismatch}
    end

    test "the wrong recipient", ctx do
      response =
        SAMLTestHelpers.response(ctx.idp, opts(ctx, recipient: "https://other.example/acs"))

      assert validate(ctx, response) == {:error, :recipient_mismatch}
    end

    test "the wrong destination", ctx do
      response =
        SAMLTestHelpers.response(ctx.idp, opts(ctx, destination: "https://other.example/acs"))

      assert validate(ctx, response) == {:error, :destination_mismatch}
    end

    test "the wrong issuer", ctx do
      response =
        SAMLTestHelpers.response(ctx.idp, opts(ctx, issuer: "https://other-idp.example"))

      assert validate(ctx, response) == {:error, :issuer_mismatch}
    end

    test "an assertion naming another issuer inside a response that names the right one", ctx do
      wrong_issuer = fn {tag, attrs, [{issuer_tag, issuer_attrs, _text} | rest]} ->
        {tag, attrs, [{issuer_tag, issuer_attrs, ["https://other-idp.example"]} | rest]}
      end

      response = SAMLTestHelpers.response(ctx.idp, opts(ctx, edit_assertion: wrong_issuer))
      assert validate(ctx, response) == {:error, :issuer_mismatch}
    end

    test "a response to another request", ctx do
      response = SAMLTestHelpers.response(ctx.idp, opts(ctx, request_id: SAML.new_request_id()))
      assert validate(ctx, response) == {:error, :in_response_to_mismatch}
    end

    test "a status other than Success", ctx do
      response =
        SAMLTestHelpers.response(
          ctx.idp,
          opts(ctx, status: "urn:oasis:names:tc:SAML:2.0:status:Requester")
        )

      assert validate(ctx, response) == {:error, :status_not_success}
    end

    test "a transient NameID, which cannot identify a person", ctx do
      transient = "urn:oasis:names:tc:SAML:2.0:nameid-format:transient"

      response =
        SAMLTestHelpers.response(
          ctx.idp,
          opts(ctx, edit_assertion: &name_id_format(&1, transient))
        )

      assert validate(ctx, response) == {:error, :unsupported_name_id}
    end

    test "an audience restriction that leaves Stride out, even beside one that names it", ctx do
      other = {"saml:AudienceRestriction", [], [{"saml:Audience", [], ["https://other.example"]}]}

      response =
        SAMLTestHelpers.response(ctx.idp, opts(ctx, edit_assertion: &add_condition(&1, other)))

      assert validate(ctx, response) == {:error, :audience_mismatch}
    end

    test "a subject confirmation that is not bearer", ctx do
      holder = "urn:oasis:names:tc:SAML:2.0:cm:holder-of-key"

      response =
        SAMLTestHelpers.response(
          ctx.idp,
          opts(ctx, edit_assertion: &confirmation_method(&1, holder))
        )

      assert validate(ctx, response) == {:error, :invalid_response}
    end

    test "a second subject confirmation or NameID", ctx do
      double_confirmation = fn assertion ->
        edit_child(assertion, "saml:Subject", fn {tag, attrs, [name_id, confirmation]} ->
          {tag, attrs, [name_id, confirmation, confirmation]}
        end)
      end

      double_name_id = fn assertion ->
        edit_child(assertion, "saml:Subject", fn {tag, attrs, [name_id | rest]} ->
          {tag, attrs, [name_id, name_id | rest]}
        end)
      end

      for edit <- [double_confirmation, double_name_id] do
        response = SAMLTestHelpers.response(ctx.idp, opts(ctx, edit_assertion: edit))
        assert validate(ctx, response) == {:error, :invalid_response}
      end
    end

    test "a signature anywhere but under the response or the assertion", ctx do
      {tag, attrs, children} = SAMLTestHelpers.response_node(ctx.idp, opts(ctx))
      {a_tag, a_attrs, [issuer, signature | rest]} = List.last(children)

      tucked =
        Enum.map(rest, fn
          {"saml:Subject", s_attrs, s_children} ->
            {"saml:Subject", s_attrs, [signature | s_children]}

          other ->
            other
        end)

      for assertion <- [
            {a_tag, a_attrs, [issuer, signature | tucked]},
            {a_tag, a_attrs, [issuer, signature, signature | rest]}
          ] do
        response =
          {tag, attrs, List.replace_at(children, -1, assertion)}
          |> SimpleXml.XmlNode.to_string()
          |> SAMLTestHelpers.encode()

        assert validate(ctx, response) == {:error, :unsafe_xml}
      end
    end

    test "a document nested too deeply", ctx do
      deep = String.duplicate("<e>", 70) <> "x" <> String.duplicate("</e>", 70)

      response =
        tampered(ctx, fn xml ->
          String.replace(xml, "<saml:AuthnStatement", deep <> "<saml:AuthnStatement")
        end)

      assert validate(ctx, response) == {:error, :unsafe_xml}
    end

    test "a response for one Organization checked against another's connection", ctx do
      other = organization_fixture()
      other_connection = saml_connection_fixture(other, ctx.idp.pem)
      response = SAMLTestHelpers.response(ctx.idp, opts(ctx))

      other_expected = %{
        service_provider: SAML.service_provider(other.id),
        request_id: ctx.request_id
      }

      assert {:error, reason} = SAML.validate_response(response, other_connection, other_expected)
      assert reason in [:destination_mismatch, :audience_mismatch, :recipient_mismatch]
    end
  end

  defp edit_child({tag, attrs, children}, name, fun),
    do: {tag, attrs, Enum.map(children, &if(elem(&1, 0) == name, do: fun.(&1), else: &1))}

  defp name_id_format(assertion, format) do
    edit_child(assertion, "saml:Subject", fn subject ->
      edit_child(subject, "saml:NameID", fn {tag, _attrs, children} ->
        {tag, [{"Format", format}], children}
      end)
    end)
  end

  defp confirmation_method(assertion, method) do
    edit_child(assertion, "saml:Subject", fn subject ->
      edit_child(subject, "saml:SubjectConfirmation", fn {tag, _attrs, children} ->
        {tag, [{"Method", method}], children}
      end)
    end)
  end

  defp add_condition(assertion, condition) do
    edit_child(assertion, "saml:Conditions", fn {tag, attrs, children} ->
      {tag, attrs, children ++ [condition]}
    end)
  end

  # Real identity provider responses with their signing certificates, copied
  # from simple_saml 1.2.1's doctests (MIT License, (c) 2023 MBX Systems).
  # They show the hardening and the signature check accept what Microsoft
  # Entra ID and Okta actually send.
  describe "validate_response/3 with real identity provider responses" do
    defp vector(name) do
      dir = Path.expand("../../support/fixtures/saml", __DIR__)
      response = dir |> Path.join("#{name}_response.b64") |> File.read!() |> String.trim()
      certificate = dir |> Path.join("#{name}_certificate.b64") |> File.read!() |> String.trim()
      {:ok, [pem]} = Metadata.parse_certificates(certificate)
      {response, pem}
    end

    defp vector_connection(pem, issuer),
      do: %Kanban.SSO.SSOConnection{
        id: 1,
        organization_id: 1,
        protocol: :saml,
        issuer: issuer,
        settings: %{"certificates" => [pem], "sso_url" => "https://idp.example.com/saml/sso"}
      }

    @entra_expected %{
      service_provider: %{
        entity_id: "https://samltest.todo.computer",
        acs_url: "https://samltest.todo.computer/saml/sp/consume/dummy-ms"
      },
      request_id: "saml_flow_jmdYlGs9hwmx7PXZ_nL423gxwS5eRmfp",
      now: ~U[2025-05-12 09:30:00Z]
    }
    @entra_issuer "https://sts.windows.net/8e4dae73-8586-43f1-8e9b-8e5a09949050/"

    test "accepts a signed Microsoft Entra ID response" do
      {response, pem} = vector("azure")
      connection = vector_connection(pem, @entra_issuer)

      assert {:ok, result} = SAML.validate_response(response, connection, @entra_expected)
      assert result.email == "adrian.gruntkowski@gmail.com"
      assert result.name == "Adrian Gruntkowski"
      assert result.assertion_id == "_d2b0e29f-57bd-4575-8b07-80c6098e0900"
    end

    test "refuses the Entra ID response altered, or checked with another certificate", ctx do
      {response, pem} = vector("azure")
      connection = vector_connection(pem, @entra_issuer)

      altered =
        response
        |> Base.decode64!()
        |> String.replace("adrian.gruntkowski@gmail.com", "boss@gmail.com")
        |> Base.encode64()

      assert SAML.validate_response(altered, connection, @entra_expected) ==
               {:error, :signature_invalid}

      other = vector_connection(ctx.idp.pem, @entra_issuer)

      assert SAML.validate_response(response, other, @entra_expected) ==
               {:error, :signature_invalid}
    end

    test "refuses an IdP-initiated Okta response, which answers no request" do
      {response, pem} = vector("okta")
      connection = vector_connection(pem, "http://www.okta.com/exk16yajm7pRjCyRN0x8")

      expected = %{
        service_provider: %{
          entity_id: "https://local.mbx.com:4001/Vd1zXr44OSkdJtfidi7uZ2NGyhI",
          acs_url: "https://local.mbx.com:4001/auth/saml/sso"
        },
        request_id: SAML.new_request_id(),
        now: ~U[2025-07-06 16:10:00Z]
      }

      # Signature, issuer, audience and recipient all pass; only the missing
      # InResponseTo refuses it.
      assert SAML.validate_response(response, connection, expected) ==
               {:error, :in_response_to_mismatch}
    end
  end

  describe "authn_request_url/4" do
    test "redirects to the sign-on URL with a deflated AuthnRequest and RelayState", ctx do
      url = SAML.authn_request_url(ctx.connection, ctx.sp, ctx.request_id, "relay-token")

      assert String.starts_with?(url, SAMLTestHelpers.sso_url() <> "?")
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["RelayState"] == "relay-token"

      xml = SAMLTestHelpers.authn_request_xml(url)
      assert xml =~ ~s(ID="#{ctx.request_id}")
      assert xml =~ ~s(AssertionConsumerServiceURL="#{ctx.sp.acs_url}")
      assert xml =~ "<saml:Issuer>#{ctx.sp.entity_id}</saml:Issuer>"
    end

    test "appends to a sign-on URL that already has a query", ctx do
      connection = %{
        ctx.connection
        | settings: Map.put(ctx.connection.settings, "sso_url", "https://idp.example.com/sso?a=1")
      }

      assert SAML.authn_request_url(connection, ctx.sp, ctx.request_id, "r") =~
               "https://idp.example.com/sso?a=1&"
    end
  end

  describe "service_provider/1 and SP metadata" do
    test "are fixed per Organization", ctx do
      assert ctx.sp.entity_id =~ "/users/sso/saml/#{ctx.organization.id}"
      assert ctx.sp.acs_url == ctx.sp.entity_id <> "/acs"

      xml = Metadata.sp_metadata(ctx.sp)
      assert {:ok, _root} = SimpleXml.parse(xml)
      assert xml =~ ~s(entityID="#{ctx.sp.entity_id}")
      assert xml =~ ~s(Location="#{ctx.sp.acs_url}")
      assert xml =~ "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
    end
  end

  describe "Metadata.parse_idp/1" do
    test "reads the entity id, redirect sign-on URL and signing certificates", ctx do
      xml = SAMLTestHelpers.idp_metadata([ctx.idp.pem, ctx.other_idp.pem])

      assert {:ok, idp} = Metadata.parse_idp(xml)
      assert idp.entity_id == SAMLTestHelpers.issuer()
      assert idp.sso_url == SAMLTestHelpers.sso_url()
      assert length(idp.certificates) == 2
      assert {:ok, _key} = idp.certificates |> hd() |> Metadata.public_key()
    end

    test "refuses a DOCTYPE, garbage, and metadata with no redirect service", ctx do
      assert Metadata.parse_idp(~s(<!DOCTYPE x [<!ENTITY a "b">]><x/>)) == {:error, :invalid}

      # Otherwise valid metadata: the parser itself would accept the DOCTYPE.
      with_doctype =
        ctx.idp.pem
        |> SAMLTestHelpers.idp_metadata()
        |> String.replace(
          ~s(<?xml version="1.0"?>),
          ~s(<?xml version="1.0"?><!DOCTYPE md:EntityDescriptor>)
        )

      assert Metadata.parse_idp(with_doctype) == {:error, :invalid}
      assert Metadata.parse_idp("not xml") == {:error, :invalid}

      xml =
        ctx.idp.pem
        |> SAMLTestHelpers.idp_metadata()
        |> String.replace("HTTP-Redirect", "HTTP-Artifact")

      assert Metadata.parse_idp(xml) == {:error, :missing_sso_url}
    end
  end

  describe "Metadata.parse_certificates/1" do
    test "accepts one or two RSA certificates and refuses anything else", ctx do
      assert {:ok, [_one]} = Metadata.parse_certificates(ctx.idp.pem)
      assert {:ok, [_a, _b]} = Metadata.parse_certificates(ctx.idp.pem <> ctx.other_idp.pem)

      assert {:ok, [_bare]} =
               ctx.idp.pem |> SAMLTestHelpers.der_base64() |> Metadata.parse_certificates()

      three = ctx.idp.pem <> ctx.other_idp.pem <> SAMLTestHelpers.idp().pem
      assert Metadata.parse_certificates(three) == {:error, :invalid_certificate}
      assert Metadata.parse_certificates("garbage") == {:error, :invalid_certificate}
      assert Metadata.parse_certificates("") == {:error, :invalid_certificate}

      ec_pem =
        X509.PrivateKey.new_ec(:secp256r1)
        |> X509.Certificate.self_signed("/CN=EC")
        |> X509.Certificate.to_pem()

      assert Metadata.parse_certificates(ec_pem) == {:error, :invalid_certificate}
    end

    test "refuses an RSA key shorter than 2048 bits" do
      weak_pem =
        X509.PrivateKey.new_rsa(1024)
        |> X509.Certificate.self_signed("/CN=Weak")
        |> X509.Certificate.to_pem()

      assert Metadata.parse_certificates(weak_pem) == {:error, :invalid_certificate}
      assert Metadata.public_key(weak_pem) == :error
    end
  end
end
