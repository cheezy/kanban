defmodule Kanban.AuditStream.Adapters.HttpsTest do
  # async: false — some tests replace the application config of
  # Kanban.AuditLog.Signing, which is global, to turn signing off.
  use ExUnit.Case, async: false

  import Kanban.AuditStreamFixtures, only: [destination_attrs: 2]

  alias Kanban.AuditLog.Signing
  alias Kanban.AuditStream.Adapter
  alias Kanban.AuditStream.Adapters.Https
  alias Kanban.AuditStream.Destination
  alias Kanban.Webhooks.Signer
  alias Kanban.Webhooks.Transport

  @now 1_760_000_000
  @secret "assec_current-secret"
  @old_secret "assec_previous-secret"
  @organization %{id: 210, name: "Northwind Studio"}
  @events [
    %{"id" => "1", "schema" => "stride.audit.v1", "action" => "login_failed"},
    %{"id" => "2", "schema" => "stride.audit.v1", "action" => "org_member_removed"}
  ]

  setup do
    saved = Application.fetch_env(:kanban, Signing)

    on_exit(fn ->
      case saved do
        {:ok, config} -> Application.put_env(:kanban, Signing, config)
        :error -> Application.delete_env(:kanban, Signing)
      end
    end)
  end

  defp destination(overrides \\ %{}) do
    struct!(
      %Destination{
        id: 31,
        kind: :https,
        url: "https://siem.example.org/ingest?token=abcd",
        settings: %{},
        signing_secret: @secret
      },
      overrides
    )
  end

  defp batch(overrides \\ %{}) do
    Map.merge(
      %{batch_id: "5f0c-batch", events: @events, organization: @organization, signed_at: @now},
      overrides
    )
  end

  defp header(headers, name) do
    case for({^name, value} <- headers, do: value) do
      [value] -> value
      [] -> nil
    end
  end

  defp request(destination \\ destination(), batch \\ batch()) do
    {url, headers, body} = Https.build_request(destination, batch)
    {url, headers, :zlib.gunzip(body)}
  end

  defp audit_signature(header) do
    header
    |> String.split(",")
    |> Map.new(&(&1 |> String.split("=", parts: 2) |> List.to_tuple()))
  end

  defp verify_hmac(headers, body, opts \\ []) do
    signature = header(headers, "x-stride-signature")
    Signer.verify(signature, body, @secret, opts)
  end

  defp audit_signature_valid?(header, destination_id, body) do
    %{"t" => t, "kid" => kid, "ed25519" => encoded} = audit_signature(header)
    {:ok, signature} = Base.url_decode64(encoded, padding: false)
    Signing.verify([t, ".", to_string(destination_id), ".", body], signature, kid)
  end

  describe "build_request/2 body" do
    test "json and ndjson bodies inflate to the expected text" do
      {_url, json_headers, json} = request()

      assert Jason.decode!(json) == %{
               "version" => 1,
               "batch_id" => "5f0c-batch",
               "destination_id" => 31,
               "organization" => %{"id" => 210, "name" => "Northwind Studio"},
               "events" => @events
             }

      assert header(json_headers, "content-type") == "application/json"

      {_url, ndjson_headers, ndjson} =
        request(destination(%{settings: %{"format" => "ndjson"}}))

      assert ndjson == Enum.map_join(@events, &(Jason.encode!(&1) <> "\n"))
      assert ndjson |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) == @events
      assert header(ndjson_headers, "content-type") == "application/x-ndjson"
    end

    test "an explicit json format is the JSON batch" do
      {_url, headers, body} = request(destination(%{settings: %{"format" => "json"}}))

      assert %{"version" => 1} = Jason.decode!(body)
      assert header(headers, "content-type") == "application/json"
    end

    test "the body is gzipped and says so" do
      {_url, headers, body} = Https.build_request(destination(), batch())

      assert <<0x1F, 0x8B, _rest::binary>> = body
      assert header(headers, "content-encoding") == "gzip"
    end

    test "the URL is the destination's" do
      assert {"https://siem.example.org/ingest?token=abcd", _headers, _body} = request()
    end
  end

  describe "build_request/2 headers" do
    test "Stride's headers carry the destination, batch and count" do
      {_url, headers, _body} = request()

      assert header(headers, "user-agent") == "Stride-AuditStream/1"
      assert header(headers, "x-stride-destination") == "31"
      assert header(headers, "x-stride-batch") == "5f0c-batch"
      assert header(headers, "x-stride-event-count") == "2"
      assert Enum.all?(headers, fn {name, _value} -> name == String.downcase(name) end)
    end

    test "the batch id is the same on every retry of the batch" do
      {_url, first, _body} = request(destination(), batch(%{signed_at: @now}))
      {_url, retry, _body} = request(destination(), batch(%{signed_at: @now + 60}))

      assert header(first, "x-stride-batch") == header(retry, "x-stride-batch")
    end

    test "signed_at defaults to now" do
      {_url, headers, body} = request(destination(), Map.delete(batch(), :signed_at))

      assert verify_hmac(headers, body) == :ok
    end

    test "the custom header is sent last with the credential as its value" do
      dest =
        destination(%{settings: %{"header_name" => "Authorization"}, credential: "Bearer xyz"})

      {_url, headers, _body} = request(dest)

      assert List.last(headers) == {"authorization", "Bearer xyz"}
    end

    test "empty optional header name and value send no custom header" do
      for {settings, credential} <- [
            {%{}, nil},
            {%{"header_name" => ""}, "Bearer xyz"},
            {%{"header_name" => "Authorization"}, nil},
            {%{"header_name" => "Authorization"}, ""},
            {%{"header_name" => "Authorization"}, :unreadable}
          ] do
        {_url, headers, _body} =
          request(destination(%{settings: settings, credential: credential}))

        assert header(headers, "authorization") == nil, inspect(settings)
        assert length(headers) == 8
      end
    end

    test "a reserved custom header stored without the changeset never replaces a Stride header" do
      for name <- ["X-Stride-Signature", "user-agent", "Bad Header"] do
        dest = destination(%{settings: %{"header_name" => name}, credential: "spoofed"})
        {_url, headers, _body} = request(dest)

        refute Enum.any?(headers, fn {_name, value} -> value == "spoofed" end), name
        names = Enum.map(headers, &elem(&1, 0))
        assert names == Enum.uniq(names)
      end
    end

    test "a destination with no readable URL or signing secret is refused without its values" do
      for dest <- [
            destination(%{signing_secret: nil}),
            destination(%{signing_secret: :unreadable}),
            destination(%{url: :unreadable})
          ] do
        error = assert_raise ArgumentError, fn -> Https.build_request(dest, batch()) end
        refute error.message =~ "assec_"
      end
    end
  end

  describe "X-Stride-Signature" do
    test "verifies with Signer.verify/4 on the inflated body" do
      {_url, headers, body} = request()

      assert verify_hmac(headers, body, now: @now) == :ok
    end

    test "HMAC verifies with Signer.verify/4 including two secrets during rotation" do
      dest =
        destination(%{
          previous_signing_secret: @old_secret,
          previous_secret_expires_at: DateTime.from_unix!(@now + 3_600)
        })

      {_url, headers, body} = request(dest)
      signature = header(headers, "x-stride-signature")

      assert [_, old, new] = Regex.run(~r/\At=#{@now},v1=(\w{64}),v1=(\w{64})\z/, signature)
      assert "t=#{@now},v1=#{old}" == Signer.sign(body, @old_secret, @now)
      assert "t=#{@now},v1=#{new}" == Signer.sign(body, @secret, @now)
      assert Signer.verify(signature, body, @old_secret, now: @now) == :ok
      assert Signer.verify(signature, body, @secret, now: @now) == :ok
    end

    test "rotation exactly at previous_secret_expires_at, or after it, sends one v1" do
      for expires_at <- [@now, @now - 1] do
        dest =
          destination(%{
            previous_signing_secret: @old_secret,
            previous_secret_expires_at: DateTime.from_unix!(expires_at)
          })

        {_url, headers, body} = request(dest)
        signature = header(headers, "x-stride-signature")

        assert signature == Signer.sign(body, @secret, @now)

        assert Signer.verify(signature, body, @old_secret, now: @now) ==
                 {:error, :invalid_signature}
      end
    end

    test "a previous secret that is missing, unreadable or has no expiry sends one v1" do
      for {previous, expires_at} <- [
            {nil, DateTime.from_unix!(@now + 3_600)},
            {:unreadable, DateTime.from_unix!(@now + 3_600)},
            {@old_secret, nil}
          ] do
        dest =
          destination(%{
            previous_signing_secret: previous,
            previous_secret_expires_at: expires_at
          })

        {_url, headers, body} = request(dest)

        assert header(headers, "x-stride-signature") == Signer.sign(body, @secret, @now)
      end
    end
  end

  describe "X-Stride-Audit-Signature" do
    test "Ed25519 signature verifies by kid over t, the destination id and the inflated body" do
      {_url, headers, body} = request()
      value = header(headers, "x-stride-audit-signature")
      %{"t" => t, "kid" => kid, "ed25519" => encoded} = audit_signature(value)

      assert t == Integer.to_string(@now)
      assert kid == Signing.current_key().key_id
      # base64url without padding: 64 bytes are 86 characters, no "=".
      assert encoded =~ ~r/\A[A-Za-z0-9_-]{86}\z/
      assert {:ok, signature} = Base.url_decode64(encoded, padding: false)

      # Checked with the published public key directly, not only Signing.verify/3.
      assert {:ok, %{public_key: public_key}} = Signing.find_published(kid)
      message = "#{@now}.31.#{body}"
      assert :crypto.verify(:eddsa, :none, message, signature, [public_key, :ed25519])
      assert audit_signature_valid?(value, 31, body)
    end

    test "t is the same in both signatures" do
      {_url, headers, _body} = request()

      assert "t=1760000000," <> _ = header(headers, "x-stride-signature")
      assert %{"t" => "1760000000"} = audit_signature(header(headers, "x-stride-audit-signature"))
    end

    test "the signature covers the destination id, so it is not valid for another" do
      {_url, headers, body} = request()

      refute audit_signature_valid?(header(headers, "x-stride-audit-signature"), 32, body)
    end

    test "neither signature covers the gzip bytes" do
      {_url, headers, gzipped} = Https.build_request(destination(), batch())

      refute audit_signature_valid?(header(headers, "x-stride-audit-signature"), 31, gzipped)

      assert verify_hmac(headers, gzipped, now: @now) ==
               {:error, :invalid_signature}
    end

    test "a changed byte fails both" do
      {_url, headers, body} = request()
      <<first, rest::binary>> = body
      tampered = <<Bitwise.bxor(first, 1), rest::binary>>

      assert verify_hmac(headers, tampered, now: @now) ==
               {:error, :invalid_signature}

      refute audit_signature_valid?(header(headers, "x-stride-audit-signature"), 31, tampered)
    end

    test "no signing key sends only the HMAC" do
      Application.put_env(:kanban, Signing, [])
      refute Signing.enabled?()

      {_url, headers, body} = request()

      assert header(headers, "x-stride-audit-signature") == nil
      assert verify_hmac(headers, body, now: @now) == :ok
      assert length(headers) == 7
    end
  end

  describe "validate_credential/2" do
    @named %{"header_name" => "Authorization"}

    test "accepts visible ASCII, space and tab under a header name" do
      for credential <- ["Bearer abc.DEF-123_~", "key with spaces", "a\tb", "!#$%&'*+-.^_`|~"] do
        assert Https.validate_credential(credential, @named) == :ok, inspect(credential)
      end
    end

    test "accepts neither a name nor a credential" do
      for settings <- [%{}, %{"header_name" => ""}], credential <- [nil, ""] do
        assert Https.validate_credential(credential, settings) == :ok
      end
    end

    test "refuses a value the transport could not send, without quoting it" do
      for credential <- ["Bearer abc\n", "a\r\nX-Evil: 1", "clé", "del\x7F", "bell\a"] do
        assert Https.validate_credential(credential, @named) ==
                 {:error, [credential: {"is invalid", validation: :header_value}]},
               inspect(credential)
      end
    end

    test "a header name needs a credential, and a credential needs a header name" do
      for credential <- [nil, ""] do
        assert Https.validate_credential(credential, @named) ==
                 {:error, [credential: {"can't be blank", validation: :required}]}
      end

      for settings <- [%{}, %{"header_name" => ""}, %{"format" => "ndjson"}] do
        assert Https.validate_credential("Bearer xyz", settings) ==
                 {:error, [settings: {"is invalid", validation: :header_name_required}]}
      end
    end

    test "Destination.changeset refuses an unsendable HTTPS credential with HTTPS rules" do
      https = fn credential ->
        Destination.changeset(
          %Destination{},
          destination_attrs(:https, %{settings: @named, credential: credential})
        )
      end

      assert https.("Bearer abcdefghijklmnop").valid?

      refused = https.("Bearer abcdefghijklmnop\n")
      refute refused.valid?
      assert {"is invalid", [validation: :header_value]} = refused.errors[:credential]
      refute inspect(refused.errors) =~ "abcdefghijklmnop"

      # Datadog's stricter rule for its key is in
      # Kanban.AuditStream.Adapters.DatadogTest.
      datadog =
        Destination.changeset(
          %Destination{},
          destination_attrs(:datadog, %{credential: "datadog-key-1234567890"})
        )

      assert datadog.valid?
    end

    test "Destination.changeset refuses a half-configured header from either side" do
      no_credential =
        Destination.changeset(%Destination{}, destination_attrs(:https, %{settings: @named}))

      refute no_credential.valid?
      assert {"can't be blank", [validation: :required]} = no_credential.errors[:credential]

      no_name =
        Destination.changeset(
          %Destination{},
          destination_attrs(:https, %{settings: %{}, credential: "Bearer xyz"})
        )

      refute no_name.valid?
      assert {"is invalid", [validation: :header_name_required]} = no_name.errors[:settings]
    end

    test "Destination.changeset checks the pair when only the settings change" do
      stored = %Destination{
        kind: :https,
        name: "Stored",
        url: "https://siem.example.org/ingest",
        settings: @named,
        credential: "Bearer xyz"
      }

      refute Destination.changeset(stored, %{settings: %{}}).valid?
      assert Destination.changeset(stored, %{name: "Renamed"}).valid?
    end

    test "an unreadable credential is left to the update flow" do
      stored = %Destination{
        kind: :https,
        name: "Stored",
        url: "https://siem.example.org/ingest",
        settings: @named,
        credential: :unreadable
      }

      refute Keyword.has_key?(
               Destination.changeset(stored, %{name: "Renamed"}).errors,
               :credential
             )
    end

    test "an unsendable credential stored without the changeset is never sent" do
      for credential <- ["Bearer xyz\n", "clé"] do
        dest = destination(%{settings: @named, credential: credential})
        {_url, headers, _body} = request(dest)

        assert header(headers, "authorization") == nil
        refute Enum.any?(headers, fn {_name, value} -> value == credential end)
      end
    end
  end

  describe "validate/1" do
    test "accepts the defaults, both formats and usable header names" do
      for settings <- [
            %{},
            %{"format" => "json"},
            %{"format" => "ndjson", "header_name" => "X-Api-Key"},
            %{"header_name" => "Authorization"},
            %{"header_name" => "X-goog-api-key"},
            %{"header_name" => ""}
          ] do
        assert Https.validate(settings) == :ok, inspect(settings)
      end
    end

    test "reserved header names refused in any case" do
      for reserved <- Https.reserved_headers(),
          name <- [reserved, String.upcase(reserved), title_case(reserved)] do
        assert Https.validate(%{"header_name" => name}) ==
                 {:error, [settings: {"is invalid", validation: :reserved_header}]},
               name
      end

      assert length(Https.reserved_headers()) == 10
    end

    test "connection and framing header names are refused in any case" do
      for framing <- Https.framing_headers(),
          name <- [framing, String.upcase(framing), title_case(framing)] do
        assert Https.validate(%{"header_name" => name}) ==
                 {:error, [settings: {"is invalid", validation: :reserved_header}]},
               name
      end

      assert "transfer-encoding" in Https.framing_headers()
    end

    test "a framing header stored without the changeset is never sent" do
      dest =
        destination(%{settings: %{"header_name" => "Transfer-Encoding"}, credential: "chunked"})

      {_url, headers, _body} = request(dest)

      assert header(headers, "transfer-encoding") == nil
    end

    test "a name that is not an HTTP token is refused" do
      for name <- ["Bad Header", "a:b", "x\r\ny", String.duplicate("a", 257), 42] do
        assert Https.validate(%{"header_name" => name}) ==
                 {:error, [settings: {"is invalid", validation: :header_name}]},
               inspect(name)
      end
    end

    test "an unknown format is refused, with every error reported" do
      assert Https.validate(%{"format" => "xml"}) ==
               {:error, [settings: {"is invalid", validation: :format}]}

      assert Https.validate(%{"format" => "xml", "header_name" => "Host"}) ==
               {:error,
                [
                  settings: {"is invalid", validation: :format},
                  settings: {"is invalid", validation: :reserved_header}
                ]}
    end

    test "Destination.changeset applies it for an HTTPS destination" do
      changeset = fn settings ->
        credential = if settings["header_name"], do: "Bearer abcdefghijklmnop"

        Destination.changeset(
          %Destination{},
          destination_attrs(:https, %{settings: settings, credential: credential})
        )
      end

      assert changeset.(%{"format" => "ndjson", "header_name" => "X-Api-Key"}).valid?
      assert changeset.(%{}).valid?

      refused = changeset.(%{"header_name" => "content-TYPE"})
      refute refused.valid?
      assert {"is invalid", [validation: :reserved_header]} = refused.errors[:settings]

      refute changeset.(%{"format" => "xml"}).valid?
    end

    test "Destination.changeset leaves another kind's settings to its own adapter" do
      changeset =
        Destination.changeset(%Destination{}, destination_attrs(:datadog, %{}))

      assert changeset.valid?
    end
  end

  defp title_case(name),
    do: name |> String.split("-") |> Enum.map_join("-", &String.capitalize/1)

  describe "classify/2" do
    test "classify maps each status class" do
      for status <- [200, 202, 204, 299], do: assert(Https.classify(status, "") == :ok)

      for status <- [408, 429, 500, 503, 599],
          do: assert(Https.classify(status, "") == {:retry, nil})

      assert Https.classify(413, "") == :split
      assert Https.classify(401, "") == :unauthorized
      assert Https.classify(403, "") == :unauthorized

      for status <- [400, 404, 409, 422, 451],
          do: assert(Https.classify(status, "") == :permanent)

      for status <- [100, 301, 302], do: assert(Https.classify(status, "") == :permanent)
    end

    test "max_event_age is :infinity" do
      assert Https.max_event_age() == :infinity
    end

    test "validate_url/1 adds no rules of its own, so any path is kept" do
      assert Https.validate_url("https://siem.example.org/any/path?token=abcd") == :ok

      changeset =
        Destination.changeset(
          %Destination{},
          destination_attrs(:https, %{url: "https://siem.example.org/services/collector/raw"})
        )

      assert changeset.valid?
    end
  end

  describe "Adapter.module_for/1" do
    test "maps a kind to its adapter, and a kind without one to nil" do
      assert Adapter.module_for(:https) == Https
      assert Adapter.module_for(:splunk_hec) == Kanban.AuditStream.Adapters.SplunkHec
      assert Adapter.module_for(:datadog) == Kanban.AuditStream.Adapters.Datadog
      assert Adapter.module_for(:other) == nil
      assert Adapter.module_for(nil) == nil
    end
  end

  describe "through the transport" do
    test "build_request output posted to a Req.Test stub on Kanban.Webhooks.Transport arrives with all headers" do
      test = self()

      Req.Test.stub(Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, conn, body})
        Plug.Conn.send_resp(conn, 202, "accepted")
      end)

      dest = destination(%{settings: %{"header_name" => "X-Api-Key"}, credential: "key-1234"})
      {url, headers, body} = Https.build_request(dest, batch())

      assert {:ok, %{status: 202}} =
               Transport.post(
                 %{uri: URI.parse(url), addresses: [{93, 184, 216, 35}]},
                 body,
                 headers
               )

      assert_receive {:request, conn, inflated}
      assert conn.method == "POST"

      # Req.Test's plug adapter inflates a gzip request body and drops
      # Content-Encoding before the stub sees it, so what goes on the wire is
      # checked from the options Transport hands Req: the gzip bytes, unchanged.
      options =
        Transport.request_options(
          %{uri: URI.parse(url), addresses: [{93, 184, 216, 35}]},
          body,
          headers
        )

      assert options[:body] == body
      assert {"content-encoding", "gzip"} in options[:headers]
      assert inflated == :zlib.gunzip(body)

      for {name, value} <- headers, name != "content-encoding" do
        assert Plug.Conn.get_req_header(conn, name) == [value], name
      end

      assert Jason.decode!(inflated)["events"] == @events

      signature = conn |> Plug.Conn.get_req_header("x-stride-signature") |> hd()
      assert Signer.verify(signature, inflated, @secret, now: @now) == :ok

      [audit] = Plug.Conn.get_req_header(conn, "x-stride-audit-signature")
      assert audit_signature_valid?(audit, 31, inflated)
    end
  end
end
