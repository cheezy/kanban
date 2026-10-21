defmodule Kanban.SSO.SAML do
  @moduledoc """
  The SAML 2.0 protocol for single sign-on (W2246): Stride's service provider
  identity, the AuthnRequest and the validation of a signed response.

  The library is `simple_saml` (chosen on 2026-10-21; `samly`'s `esaml`
  dependency carries the unpatched XXE advisory GHSA-4g2h-vm7x-747c). It
  parses a response and verifies its XML signature; everything else is
  checked here, after `Kanban.SSO.SAML.XML` has refused the inputs its parser
  and canonicalization would mishandle.

  `validate_response/3` accepts a response only when:

    * it is a `Response` holding exactly one `Assertion` and nothing that
      `Kanban.SSO.SAML.XML` refuses (DOCTYPE, comments, unsafe characters,
      unsupported signature algorithms),
    * its status is Success and its `Destination`, when present, is the
      connection's assertion consumer service URL,
    * the response or the assertion is signed (the reference naming that
      element's ID) by one of the connection's certificates, so two can be
      configured during a rollover,
    * the assertion's issuer is the connection's IdP entity id, its audience
      is the connection's SP entity id, and its bearer confirmation names the
      assertion consumer service URL and, in `InResponseTo`, the request
      Stride sent (unsolicited, IdP-initiated responses are refused),
    * the time is inside `NotBefore` / `NotOnOrAfter` with
      120 seconds of clock skew (`skew_seconds/0`).

  It returns the assertion ID (for the replay cache), the NameID as subject,
  an email address and a display name. The connection's Organization is
  bound by the caller, which only validates a response posted to that
  connection's own URL against that connection's certificates.
  """

  alias Kanban.SSO.SAML.Metadata
  alias Kanban.SSO.SAML.XML
  alias Kanban.SSO.SSOConnection

  @skew_seconds 120
  @success "urn:oasis:names:tc:SAML:2.0:status:Success"
  @post_binding "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
  @bearer "urn:oasis:names:tc:SAML:2.0:cm:bearer"
  @transient "urn:oasis:names:tc:SAML:2.0:nameid-format:transient"

  @email_attributes [
    "email",
    "mail",
    "emailaddress",
    "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress",
    "urn:oid:0.9.2342.19200300.100.1.3",
    "user.email"
  ]
  @name_attributes [
    "displayname",
    "name",
    "http://schemas.microsoft.com/identity/claims/displayname",
    "urn:oid:2.16.840.1.113730.3.1.241"
  ]
  @given_name_attributes [
    "givenname",
    "firstname",
    "first_name",
    "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname",
    "urn:oid:2.5.4.42"
  ]
  @surname_attributes [
    "surname",
    "sn",
    "lastname",
    "last_name",
    "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname",
    "urn:oid:2.5.4.4"
  ]

  @type service_provider :: %{entity_id: String.t(), acs_url: String.t()}
  @type expected :: %{
          required(:service_provider) => service_provider(),
          required(:request_id) => String.t(),
          optional(:now) => DateTime.t()
        }
  @type result :: %{
          assertion_id: String.t(),
          subject: String.t(),
          email: String.t() | nil,
          name: String.t() | nil,
          expires_at: DateTime.t()
        }

  @doc "The clock skew allowed on an assertion's validity window, in seconds."
  @spec skew_seconds() :: pos_integer()
  def skew_seconds, do: @skew_seconds

  @doc """
  Stride's service provider identity for an Organization's SAML connection:
  its entity id and assertion consumer service URL. Both are fixed by the
  Organization, so an org-admin can register Stride with the identity
  provider before saving the connection.
  """
  @spec service_provider(integer()) :: service_provider()
  def service_provider(organization_id) when is_integer(organization_id) do
    base = KanbanWeb.Endpoint.url() <> "/users/sso/saml/#{organization_id}"
    %{entity_id: base, acs_url: base <> "/acs"}
  end

  @doc "A fresh AuthnRequest ID (an XML ID, so it starts with a letter or underscore)."
  @spec new_request_id() :: String.t()
  def new_request_id,
    do: "_" <> (20 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))

  @doc """
  The URL that sends the browser to the identity provider with an unsigned
  AuthnRequest (HTTP-Redirect binding: raw DEFLATE, base64) and `relay_state`.
  """
  @spec authn_request_url(SSOConnection.t(), service_provider(), String.t(), String.t()) ::
          String.t()
  def authn_request_url(%SSOConnection{} = connection, sp, request_id, relay_state) do
    sso_url = connection.settings["sso_url"]

    query =
      URI.encode_query(%{
        "SAMLRequest" => sp |> authn_request(sso_url, request_id) |> deflate() |> Base.encode64(),
        "RelayState" => relay_state
      })

    separator = if String.contains?(sso_url, "?"), do: "&", else: "?"
    sso_url <> separator <> query
  end

  @doc "The AuthnRequest XML (exposed for tests)."
  @spec authn_request(service_provider(), String.t(), String.t()) :: String.t()
  def authn_request(%{entity_id: entity_id, acs_url: acs_url}, sso_url, request_id) do
    issue_instant = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    ~s(<samlp:AuthnRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ) <>
      ~s(xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="#{Metadata.escape(request_id)}" ) <>
      ~s(Version="2.0" IssueInstant="#{issue_instant}" Destination="#{Metadata.escape(sso_url)}" ) <>
      ~s(ProtocolBinding="#{@post_binding}" AssertionConsumerServiceURL="#{Metadata.escape(acs_url)}">) <>
      ~s(<saml:Issuer>#{Metadata.escape(entity_id)}</saml:Issuer>) <>
      ~s(<samlp:NameIDPolicy AllowCreate="true"/>) <>
      ~s(</samlp:AuthnRequest>)
  end

  defp deflate(data) do
    z = :zlib.open()

    try do
      :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
      compressed = :zlib.deflate(z, data, :finish)
      :ok = :zlib.deflateEnd(z)
      IO.iodata_to_binary(compressed)
    after
      :zlib.close(z)
    end
  end

  # --- response validation -----------------------------------------------------

  @doc """
  Validates the base64 `SAMLResponse` posted for `connection` against what
  Stride expects (its SP identity and the request id). Returns
  `{:ok, result}` or `{:error, reason}`; the reasons are recorded in the audit
  log only.
  """
  @spec validate_response(term(), SSOConnection.t(), expected()) ::
          {:ok, result()} | {:error, atom()}
  def validate_response(saml_response, %SSOConnection{} = connection, expected)
      when is_binary(saml_response) do
    with {:ok, root} <- read_response(saml_response),
         {:ok, signed} <- read_signed_assertion(root, connection, expected) do
      check_assertion(signed, expected)
    end
  end

  def validate_response(_saml_response, %SSOConnection{}, _expected),
    do: {:error, :invalid_response}

  # Size, XML hardening, signature algorithms and status: nothing here
  # depends on the connection yet.
  defp read_response(saml_response) do
    with {:ok, xml} <- decode(saml_response),
         {:ok, root} <- XML.parse_response(xml),
         :ok <- XML.check_signature_algorithms(root),
         :ok <- check_status(root) do
      {:ok, root}
    end
  end

  defp read_signed_assertion(root, connection, %{service_provider: sp}) do
    with :ok <- check_response_attribute(root, "Destination", sp.acs_url, :destination_mismatch),
         {:ok, node, assertion} <- read_assertion(root),
         :ok <- verify_signature(root, assertion, connection),
         :ok <- check_issuer(root, node, connection) do
      {:ok, %{root: root, node: node, assertion: assertion}}
    end
  end

  defp check_assertion(%{root: root, node: node, assertion: assertion}, expected) do
    with :ok <- check_conditions(node, assertion, expected),
         {:ok, name_id} <- check_subject(root, node, expected) do
      claims(node, assertion, name_id)
    end
  end

  defp check_conditions(node, assertion, %{service_provider: sp} = expected) do
    with :ok <- check_audience(node, sp.entity_id) do
      check_times(assertion, Map.get_lazy(expected, :now, &DateTime.utc_now/0))
    end
  end

  defp check_subject(root, node, %{service_provider: sp, request_id: request_id}) do
    with {:ok, subject, data} <- bearer_confirmation(node),
         :ok <- check_equal(XML.attribute(data, "Recipient"), sp.acs_url, :recipient_mismatch),
         :ok <- check_in_response_to(root, data, request_id) do
      name_id(subject)
    end
  end

  defp decode(saml_response) do
    if byte_size(saml_response) > div(XML.max_response_bytes() * 4, 3) + 4096 do
      {:error, :response_too_large}
    else
      case Base.decode64(saml_response, ignore: :whitespace) do
        {:ok, xml} -> {:ok, xml}
        :error -> {:error, :invalid_response}
      end
    end
  end

  defp check_status(root) do
    with {:ok, status} <- XML.child(root, "Status"),
         {:ok, code} <- XML.child(status, "StatusCode"),
         @success <- XML.attribute(code, "Value") do
      :ok
    else
      _not_success -> {:error, :status_not_success}
    end
  end

  # An optional attribute of the Response that must match when present.
  defp check_response_attribute(root, name, expected, reason) do
    case XML.attribute(root, name) do
      nil -> :ok
      ^expected -> :ok
      _other -> {:error, reason}
    end
  end

  defp read_assertion(root) do
    with {:ok, node} <- XML.child(root, "Assertion"),
         {:ok, assertion} <- SimpleSaml.Assertion.from_node(node) do
      {:ok, node, assertion}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  # simple_saml verifies the Response's own signature first and otherwise the
  # signature of its first Assertion child, which XML.parse_response has
  # already made the only assertion in the document.
  defp verify_signature(root, assertion, %SSOConnection{settings: settings}) do
    keys =
      settings
      |> Map.get("certificates", [])
      |> List.wrap()
      |> Enum.flat_map(fn pem ->
        case Metadata.public_key(pem) do
          {:ok, key} -> [key]
          :error -> []
        end
      end)

    if Enum.any?(keys, &signed_by?(root, assertion, &1)),
      do: :ok,
      else: {:error, :signature_invalid}
  end

  defp signed_by?(root, assertion, key) do
    SimpleSaml.verify_and_validate_response(root, assertion, key, skip_time_conditions?: true) ==
      :ok
  rescue
    _error -> false
  end

  # The assertion's Issuer, read strictly, must be the IdP entity id; a
  # Response-level Issuer, when present, must be too.
  defp check_issuer(root, node, %SSOConnection{issuer: issuer}) do
    with {:ok, issuer_node} <- XML.child(node, "Issuer"),
         {:ok, ^issuer} <- XML.text(issuer_node),
         :ok <- response_issuer(root, issuer) do
      :ok
    else
      _mismatch -> {:error, :issuer_mismatch}
    end
  end

  defp response_issuer(root, issuer) do
    case XML.children(root, "Issuer") do
      [] ->
        :ok

      [node] ->
        if XML.text(node) == {:ok, issuer}, do: :ok, else: :error

      _many ->
        :error
    end
  end

  defp check_equal(value, value, _reason) when is_binary(value), do: :ok
  defp check_equal(_value, _expected, reason), do: {:error, reason}

  # Read strictly, by exact local name: one Subject with one bearer
  # SubjectConfirmation (the one simple_saml read the recipient and its
  # NotOnOrAfter from) and its SubjectConfirmationData.
  defp bearer_confirmation(node) do
    with {:ok, subject} <- XML.child(node, "Subject"),
         {:ok, confirmation} <- XML.child(subject, "SubjectConfirmation"),
         @bearer <- XML.attribute(confirmation, "Method"),
         {:ok, data} <- XML.child(confirmation, "SubjectConfirmationData") do
      {:ok, subject, data}
    else
      _invalid -> {:error, :invalid_response}
    end
  end

  # Audience restrictions intersect (SAML core 2.5.1.4), so every one of them
  # must name Stride's entity id.
  defp check_audience(node, entity_id) do
    with {:ok, conditions} <- XML.child(node, "Conditions"),
         [_ | _] = restrictions <- XML.children(conditions, "AudienceRestriction"),
         true <- Enum.all?(restrictions, &audience?(&1, entity_id)) do
      :ok
    else
      _mismatch -> {:error, :audience_mismatch}
    end
  end

  defp audience?(restriction, entity_id) do
    restriction
    |> XML.children("Audience")
    |> Enum.any?(&(XML.text(&1) == {:ok, entity_id}))
  end

  # The confirmation must answer this request; so must the Response, when it
  # says so.
  defp check_in_response_to(root, data, request_id) do
    case XML.attribute(data, "InResponseTo") do
      ^request_id ->
        check_response_attribute(root, "InResponseTo", request_id, :in_response_to_mismatch)

      _other ->
        {:error, :in_response_to_mismatch}
    end
  end

  defp check_times(assertion, now) do
    cond do
      DateTime.compare(now, DateTime.add(assertion.not_before, -@skew_seconds)) == :lt ->
        {:error, :assertion_not_yet_valid}

      expired?(now, assertion.not_on_or_after) or expired?(now, assertion.name_id_not_on_or_after) ->
        {:error, :assertion_expired}

      true ->
        :ok
    end
  end

  defp expired?(now, %DateTime{} = not_on_or_after),
    do: DateTime.compare(now, DateTime.add(not_on_or_after, @skew_seconds)) != :lt

  defp claims(node, assertion, subject) do
    case XML.attribute(node, "ID") do
      id when is_binary(id) and byte_size(id) in 1..256 ->
        {:ok,
         %{
           assertion_id: id,
           subject: subject,
           email: email(assertion.attributes, subject),
           name: display_name(assertion.attributes),
           expires_at: expires_at(assertion)
         }}

      _invalid ->
        {:error, :invalid_response}
    end
  end

  # One plain NameID. A transient NameID changes on every sign-in, so it
  # cannot identify a person (Kanban.SSO.Provisioning matches on it).
  defp name_id(subject) do
    with {:ok, name_id} <- XML.child(subject, "NameID"),
         false <- XML.attribute(name_id, "Format") == @transient,
         {:ok, text} when byte_size(text) <= 1024 <- XML.text(name_id) do
      {:ok, text}
    else
      true -> {:error, :unsupported_name_id}
      _invalid -> {:error, :invalid_response}
    end
  end

  defp email(attributes, subject) do
    attribute_value(attributes, @email_attributes) ||
      if String.contains?(subject, "@"), do: subject
  end

  defp display_name(attributes) do
    case attribute_value(attributes, @name_attributes) do
      nil -> given_and_surname(attributes)
      name -> name
    end
  end

  defp given_and_surname(attributes) do
    [@given_name_attributes, @surname_attributes]
    |> Enum.map(&attribute_value(attributes, &1))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " ")
    end
  end

  # The first value of the first attribute whose name (compared without case)
  # is one of `names`.
  defp attribute_value(attributes, names) when is_map(attributes) do
    Enum.find_value(names, fn name ->
      Enum.find_value(attributes, fn {key, values} ->
        String.downcase(key) == name && first_value(values)
      end)
    end)
  end

  defp attribute_value(_attributes, _names), do: nil

  defp first_value([value | _rest]) when is_binary(value) and value != "", do: value
  defp first_value(_values), do: nil

  defp expires_at(assertion) do
    [assertion.not_on_or_after, assertion.name_id_not_on_or_after]
    |> Enum.max(DateTime)
    |> DateTime.add(@skew_seconds)
  end
end
