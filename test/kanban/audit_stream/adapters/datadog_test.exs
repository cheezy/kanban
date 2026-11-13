defmodule Kanban.AuditStream.Adapters.DatadogTest do
  use ExUnit.Case, async: true

  import Kanban.AuditStreamFixtures, only: [destination_attrs: 2]

  alias Kanban.AuditLog.AuditEvent
  alias Kanban.AuditStream.Adapter
  alias Kanban.AuditStream.Adapters.Datadog
  alias Kanban.AuditStream.Destination
  alias Kanban.AuditStream.Payload
  alias Kanban.Webhooks.Transport

  @key "0123456789abcdef0123456789abcdef"
  @organization %{id: 210, name: "Northwind Studio"}

  @sites ~w(
    datadoghq.com us3.datadoghq.com us5.datadoghq.com datadoghq.eu
    ap1.datadoghq.com ap2.datadoghq.com uk1.datadoghq.com
    ddog-gov.com us2.ddog-gov.com
  )

  defp event(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "schema" => "stride.audit.v1",
        "occurred_at" => "2026-11-12T08:30:15.123456Z",
        "instance" => "stridelikeaboss.com",
        "action" => "login_failed",
        "action_label" => "Failed sign-in",
        "organization" => %{"id" => 210, "name" => "Northwind Studio"},
        "actor" => %{"user_id" => 7, "email" => "ada@example.com", "in_organization" => true}
      },
      overrides
    )
  end

  defp destination(settings \\ %{"site" => "datadoghq.eu"}, overrides \\ %{}) do
    struct!(
      %Destination{id: 31, kind: :datadog, credential: @key, settings: settings},
      overrides
    )
  end

  defp batch(events \\ [event("1"), event("2")]),
    do: %{batch_id: "5f0c-batch", events: events, organization: @organization}

  defp entries(destination, events) do
    {_url, _headers, body} = Datadog.build_request(destination, batch(events))
    body |> :zlib.gunzip() |> Jason.decode!()
  end

  defp entry(event, settings \\ %{"site" => "datadoghq.eu"}),
    do: settings |> destination() |> entries([event]) |> hd()

  defp invalid(reason), do: {:error, [settings: {"is invalid", validation: reason}]}

  defp tags(count, length \\ 10) do
    for n <- 1..count//1 do
      prefix = "k#{n}:"
      prefix <> String.duplicate("v", length - String.length(prefix))
    end
  end

  describe "sites and the intake URL" do
    test "each of the nine sites builds its intake URL" do
      assert Datadog.sites() == @sites

      for site <- @sites do
        assert Datadog.validate(%{"site" => site}) == :ok, site

        {url, _headers, _body} =
          %{"site" => site} |> destination() |> Datadog.build_request(batch())

        assert url == "https://http-intake.logs.#{site}/api/v2/logs"
        assert Datadog.intake_url(site) == url
      end
    end

    test "any other site, a URL or no site at all is refused" do
      for site <- [
            nil,
            "",
            "DATADOGHQ.COM",
            "datadoghq.com.attacker.example",
            "us4.datadoghq.com",
            "https://http-intake.logs.datadoghq.com/api/v2/logs",
            "collector.example.com",
            ["datadoghq.com"]
          ] do
        assert Datadog.validate(%{"site" => site}) == invalid(:site), inspect(site)
      end

      assert Datadog.validate(%{}) == invalid(:site)
    end

    test "build_request refuses a destination with no valid site without naming the key" do
      for settings <- [nil, %{}, %{"site" => "collector.example.com"}] do
        error =
          assert_raise ArgumentError, fn ->
            settings |> destination() |> Datadog.build_request(batch())
          end

        refute Exception.message(error) =~ @key
      end
    end

    test "Destination.changeset runs the site and tag rules" do
      assert Destination.changeset(%Destination{}, destination_attrs(:datadog, %{})).valid?

      refused =
        Destination.changeset(
          %Destination{},
          destination_attrs(:datadog, %{settings: %{"site" => "collector.example.com"}})
        )

      refute refused.valid?
      assert {"is invalid", [validation: :site]} = refused.errors[:settings]

      refused =
        Destination.changeset(
          %Destination{},
          destination_attrs(:datadog, %{settings: %{"site" => "datadoghq.com", "tags" => ["x"]}})
        )

      assert {"is invalid", [validation: :tags]} = refused.errors[:settings]
    end
  end

  describe "validate_credential/2" do
    test "accepts an API key that is one header word, and leaves nil to the required check" do
      assert Datadog.validate_credential(@key, %{}) == :ok
      assert Datadog.validate_credential(nil, %{}) == :ok
      assert Datadog.validate_credential("", %{}) == :ok
    end

    test "refuses a key the transport could not send, without quoting it" do
      for key <- ["key with space", "key-é-0123456789", "key\r\nx-injected: 1", "key\t"] do
        assert Datadog.validate_credential(key, %{}) ==
                 {:error, [credential: {"is invalid", validation: :header_value}]},
               inspect(key)
      end

      refused =
        Destination.changeset(
          %Destination{},
          destination_attrs(:datadog, %{credential: "datadog-key-1234567890 "})
        )

      refute refused.valid?
      assert {"is invalid", [validation: :header_value]} = refused.errors[:credential]
      refute inspect(refused.errors) =~ "datadog-key-1234567890"
    end
  end

  describe "tags" do
    test "tag limits at 90 and 200 characters" do
      site = %{"site" => "datadoghq.com"}

      assert site |> Map.put("tags", tags(90, 200)) |> Datadog.validate() == :ok
      assert site |> Map.put("tags", tags(91)) |> Datadog.validate() == invalid(:tags)
      assert site |> Map.put("tags", tags(1, 201)) |> Datadog.validate() == invalid(:tags)
    end

    test "Unicode tag values count characters, not bytes, at the length limit" do
      at_limit = "team:" <> String.duplicate("é", 195)
      assert String.length(at_limit) == 200 and byte_size(at_limit) > 200

      assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => [at_limit]}) == :ok

      assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => [at_limit <> "é"]}) ==
               invalid(:tags)
    end

    test "each tag must be key:value with no comma or whitespace" do
      assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => []}) == :ok

      assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => ["url:https://a.b/c"]}) ==
               :ok

      for tag <- ["env", "env:", ":prod", "env:prod,team:x", "env:pro d", "env :prod", "", 7] do
        assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => [tag]}) ==
                 invalid(:tags),
               inspect(tag)
      end

      assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => "env:prod"}) ==
               invalid(:tags)
    end

    test "the length limit counts codepoints, so combining marks cannot stretch a tag" do
      # 5 + 2 x 98 = 201 codepoints in only 103 characters as they render.
      combining = "team:" <> String.duplicate("e\u0301", 98)
      assert length(String.codepoints(combining)) == 201

      assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => [combining]}) ==
               invalid(:tags)

      at_limit = "team:" <> String.duplicate("e\u0301", 97) <> "e"
      assert length(String.codepoints(at_limit)) == 200
      assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => [at_limit]}) == :ok
    end

    test "source and organization_id are Stride's own keys, in any case" do
      for tag <- [
            "organization_id:998",
            "ORGANIZATION_ID:998",
            "organization$id:998",
            "organization#id:998",
            "organization id:998",
            "source:other",
            "Source:x",
            "sour*ce:x"
          ] do
        assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => [tag]}) ==
                 invalid(:tags),
               tag
      end

      for tag <- ["source_team:a", "organization-id:a", "org.id/x:1", "équipe_2:a"] do
        assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => [tag]}) == :ok, tag
      end
    end

    test "a key must start with a letter, and no part may be zero-width, format or control" do
      for tag <- [
            "1env:prod",
            "\u200B:prod",
            "env:\u200B",
            "env:\u200D\u200D",
            "env:\uFEFF",
            "env:a\u202Eb",
            "env:a\u0001",
            "e\u001Fnv:prod",
            "\u0301:x",
            "env:\u0301"
          ] do
        assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => [tag]}) ==
                 invalid(:tags),
               inspect(tag)
      end

      assert Datadog.validate(%{"site" => "datadoghq.com", "tags" => ["équipe:café"]}) == :ok
    end

    test "build_request leaves out a stored tag that fails the rules" do
      settings = %{
        "site" => "datadoghq.eu",
        "tags" => ["env:prod", "x:y,organization_id:9", "organization_id:9", 7]
      }

      assert entry(event("1"), settings)["ddtags"] ==
               "source:stride,organization_id:210,env:prod"
    end

    test "a bad site and bad tags are both reported" do
      assert Datadog.validate(%{"site" => "nope", "tags" => ["nope"]}) ==
               {:error,
                [
                  settings: {"is invalid", validation: :site},
                  settings: {"is invalid", validation: :tags}
                ]}
    end

    test "no tags gives only the two default tags" do
      assert entry(event("1"))["ddtags"] == "source:stride,organization_id:210"

      assert entry(event("1"), %{"site" => "datadoghq.eu", "tags" => []})["ddtags"] ==
               "source:stride,organization_id:210"
    end

    test "custom tags follow the two default tags in order, and never the Organization name" do
      settings = %{"site" => "datadoghq.eu", "tags" => ["env:prod", "team:platform"]}
      ddtags = entry(event("1"), settings)["ddtags"]

      assert ddtags == "source:stride,organization_id:210,env:prod,team:platform"
      refute ddtags =~ "Northwind"
    end
  end

  describe "build_request/2" do
    test "the request carries DD-API-KEY and gzip encoding" do
      {_url, headers, body} = Datadog.build_request(destination(), batch())

      assert headers == [
               {"content-type", "application/json"},
               {"content-encoding", "gzip"},
               {"user-agent", "Stride-AuditStream/1"},
               {"dd-api-key", @key}
             ]

      assert <<0x1F, 0x8B, _rest::binary>> = body
    end

    test "an API key the transport could not send is left out, not quoted" do
      for key <- [nil, "", "key with space", "key-é-0123456789", "key\r\nx-injected: 1"] do
        {_url, headers, _body} =
          %{"site" => "datadoghq.eu"}
          |> destination(%{credential: key})
          |> Datadog.build_request(batch())

        refute List.keymember?(headers, "dd-api-key", 0), inspect(key)
      end
    end

    test "date is epoch milliseconds and ddtags order" do
      [first, second] =
        entries(destination(), [
          event("1"),
          event("2", %{"occurred_at" => "2026-11-12T10:30:15.000000+02:00"})
        ])

      expected = DateTime.to_unix(~U[2026-11-12 08:30:15.123Z], :millisecond)
      assert first["date"] == expected
      assert second["date"] == expected - 123
      assert first["ddtags"] == "source:stride,organization_id:210"
      assert first["message"] == "Failed sign-in by ada@example.com"
    end

    test "an unreadable occurred_at leaves date out, so Datadog uses its receipt time" do
      for occurred_at <- [nil, "yesterday"] do
        entry = "1" |> event(%{"occurred_at" => occurred_at}) |> entry()
        refute Map.has_key?(entry, "date")
      end
    end

    test "each entry is a JSON array element with the Datadog fields and the stride event" do
      settings = %{"site" => "datadoghq.eu", "service" => "audit-prod"}
      [first, second] = entries(destination(settings), [event("1"), event("2")])

      assert first["ddsource"] == "stride"
      assert first["service"] == "audit-prod"
      assert first["hostname"] == "stridelikeaboss.com"
      assert first["stride"] == event("1")
      assert second["stride"]["id"] == "2"

      assert Map.keys(first) |> Enum.sort() ==
               ~w(date ddsource ddtags hostname message service stride)
    end

    test "a blank service is stride-audit" do
      for settings <- [%{"site" => "datadoghq.eu"}, %{"site" => "datadoghq.eu", "service" => ""}] do
        assert entry(event("1"), settings)["service"] == "stride-audit"
      end
    end

    test "an empty batch is an empty JSON array" do
      assert entries(destination(), []) == []
    end
  end

  describe "message" do
    test "names the email when the event has it" do
      assert entry(event("1"))["message"] == "Failed sign-in by ada@example.com"
    end

    test "names the user id when the event has no email" do
      actor = %{"user_id" => 7, "email" => nil, "in_organization" => true}
      assert entry(event("1", %{"actor" => actor}))["message"] == "Failed sign-in by user 7"

      actor = %{actor | "email" => ""}
      assert entry(event("1", %{"actor" => actor}))["message"] == "Failed sign-in by user 7"
    end

    test "is the label alone for a redacted actor or an event with no actor" do
      redacted = %{"user_id" => nil, "email" => nil, "in_organization" => false}

      assert entry(event("1", %{"actor" => redacted}))["message"] == "Failed sign-in"
      assert entry(event("1", %{"actor" => nil}))["message"] == "Failed sign-in"
    end

    test "names only an integer user id, so a text user id never reaches the message" do
      actor = %{"user_id" => "ada@example.com", "email" => nil, "in_organization" => true}
      assert entry(event("1", %{"actor" => actor}))["message"] == "Failed sign-in"
    end

    test "never contains an email when personal data is off" do
      # The Reader removes the actor's email (and every metadata email) when
      # a destination leaves personal data out; the message is built from the
      # payload that results, so the stored email cannot reach it.
      audit_event = %AuditEvent{
        id: 42,
        action: "organization_updated",
        inserted_at: ~U[2026-11-12 08:30:15.123456Z],
        actor_user_id: 7,
        actor_user: %{email: nil},
        metadata: %{}
      }

      payload = Payload.build(audit_event, @organization, instance: "stridelikeaboss.com")
      message = entry(payload)["message"]

      assert message == "#{payload["action_label"]} by user 7"
      refute message =~ "@"

      with_email = %{audit_event | actor_user: %{email: "ada@example.com"}}
      payload = Payload.build(with_email, @organization, instance: "stridelikeaboss.com")
      assert entry(payload)["message"] == "#{payload["action_label"]} by ada@example.com"
    end
  end

  describe "classify/2" do
    test "classify 202, 401, 403, 408, 413, 429, 400" do
      for status <- [200, 202, 204, 299], do: assert(Datadog.classify(status, "{}") == :ok)

      for status <- [408, 429, 500, 503, 599],
          do: assert(Datadog.classify(status, "") == {:retry, nil})

      assert Datadog.classify(413, "") == :split
      assert Datadog.classify(401, "") == :unauthorized
      assert Datadog.classify(403, ~s({"errors":["Forbidden"]})) == :unauthorized

      for status <- [400, 404, 422, 100, 302],
          do: assert(Datadog.classify(status, "") == :permanent)
    end
  end

  test "max_event_age is 17 hours" do
    assert Datadog.max_event_age() == 61_200
    assert Datadog.max_event_age() == 17 * 60 * 60
  end

  test "is the adapter for :datadog" do
    assert Adapter.module_for(:datadog) == Datadog
  end

  describe "through the transport" do
    test "request posted through Transport to a Req.Test stub inflates to a JSON array" do
      test = self()

      Req.Test.stub(Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, conn, body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(202, "{}")
      end)

      {url, headers, body} = Datadog.build_request(destination(), batch())
      resolved = %{uri: URI.parse(url), addresses: [{93, 184, 216, 36}]}

      assert {:ok, %{status: 202, body: response}} = Transport.post(resolved, body, headers)
      assert Datadog.classify(202, response) == :ok

      assert_receive {:request, conn, inflated}
      assert conn.method == "POST"
      assert Plug.Conn.get_req_header(conn, "host") == ["http-intake.logs.datadoghq.eu"]
      assert conn.request_path == "/api/v2/logs"

      # Req.Test's plug adapter inflates a gzip request body and drops
      # Content-Encoding before the stub sees it, so the wire bytes are
      # checked from the options Transport hands Req.
      options = Transport.request_options(resolved, body, headers)
      assert options[:body] == body
      assert {"content-encoding", "gzip"} in options[:headers]
      assert inflated == :zlib.gunzip(body)

      for {name, value} <- headers, name != "content-encoding" do
        assert Plug.Conn.get_req_header(conn, name) == [value], name
      end

      assert inflated |> Jason.decode!() |> Enum.map(& &1["stride"]["id"]) == ["1", "2"]
    end
  end
end
