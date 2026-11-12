defmodule Kanban.AuditStream.Adapters.SplunkHecTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Kanban.AuditStreamFixtures, only: [destination_attrs: 2]

  alias Kanban.AuditStream.Adapter
  alias Kanban.AuditStream.Adapters.SplunkHec
  alias Kanban.AuditStream.Destination
  alias Kanban.Webhooks.Transport

  @url "https://http-inputs-acme.splunkcloud.com/services/collector/event"
  @token "8e1b6a3c-hec-token-wxyz"
  @organization %{id: 210, name: "Northwind Studio"}
  @locales ~w(de en es fr ja pt zh)

  defp occurred_at(microseconds),
    do: microseconds |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  defp event(id, occurred_at) do
    %{
      "id" => id,
      "schema" => "stride.audit.v1",
      "occurred_at" => occurred_at,
      "instance" => "stridelikeaboss.com",
      "action" => "login_failed"
    }
  end

  defp events do
    [
      event("1", occurred_at(1_794_193_366_015_123)),
      event("2", occurred_at(1_794_193_367_000_000))
    ]
  end

  defp destination(overrides \\ %{}) do
    struct!(
      %Destination{id: 31, kind: :splunk_hec, url: @url, credential: @token, settings: %{}},
      overrides
    )
  end

  defp batch, do: %{batch_id: "5f0c-batch", events: events(), organization: @organization}

  defp header(headers, name) do
    case for({^name, value} <- headers, do: value) do
      [value] -> value
      [] -> nil
    end
  end

  defp request(destination \\ destination()) do
    {url, headers, body} = SplunkHec.build_request(destination, batch())
    {url, headers, :zlib.gunzip(body)}
  end

  defp lines(inflated), do: inflated |> String.split("\n") |> Enum.map(&Jason.decode!/1)

  defp hec(code, extra \\ %{}),
    do: %{"text" => "Some Splunk text", "code" => code} |> Map.merge(extra) |> Jason.encode!()

  describe "validate/1" do
    test "accepts no settings, a blank index and a Splunk index name" do
      assert SplunkHec.validate(%{}) == :ok
      assert SplunkHec.validate(%{"index" => ""}) == :ok
      assert SplunkHec.validate(%{"index" => "main", "source_type" => "stride:audit"}) == :ok
      assert SplunkHec.validate(%{"index" => "audit_2026-stride"}) == :ok
    end

    test "refuses an index Splunk would not accept" do
      for index <- ["Main", "-audit", "audit log", "audit.log", String.duplicate("a", 81), 7] do
        assert SplunkHec.validate(%{"index" => index}) ==
                 {:error, [settings: {"is invalid", validation: :index}]},
               inspect(index)
      end
    end
  end

  describe "validate_url/1" do
    test "path check accepts the two collector paths and refuses raw" do
      for url <- [
            "https://splunk.example.com:8088/services/collector",
            "https://splunk.example.com:8088/services/collector/event",
            "https://http-inputs-acme.splunkcloud.com/services/collector",
            "https://http-inputs.acme.splunkcloud.com/services/collector/event",
            "https://http-inputs.acme.splunkcloudgc.com/services/collector/event"
          ] do
        assert SplunkHec.validate_url(url) == :ok, url
      end

      for url <- [
            "https://splunk.example.com:8088/services/collector/raw",
            "https://splunk.example.com:8088/services/collector/",
            "https://splunk.example.com:8088/services/collector/event/1.0",
            "https://splunk.example.com:8088/services",
            "https://splunk.example.com:8088",
            "https://splunk.example.com:8088/services/collector#event"
          ] do
        assert SplunkHec.validate_url(url) == {:error, [url: {"is invalid", validation: :path}]},
               url
      end
    end

    test "refuses a query string, plain HTTP and anything that is not a URL" do
      assert SplunkHec.validate_url("https://splunk.example.com/services/collector?token=abc") ==
               {:error, [url: {"is invalid", validation: :query}]}

      assert SplunkHec.validate_url("http://splunk.example.com:8088/services/collector") ==
               {:error, [url: {"is invalid", validation: :scheme_not_allowed}]}

      assert SplunkHec.validate_url("not a url") ==
               {:error, [url: {"is invalid", validation: :invalid_url}]}

      assert SplunkHec.validate_url(nil) ==
               {:error, [url: {"is invalid", validation: :invalid_url}]}
    end
  end

  describe "url_warning/1" do
    test "splunkcloud host without http-inputs warns" do
      for url <- [
            "https://acme.splunkcloud.com/services/collector",
            "https://ACME.SplunkCloud.com/services/collector",
            "https://acme.splunkcloudgc.com:443/services/collector/event"
          ] do
        assert SplunkHec.url_warning(url) =~ "web address", url
      end
    end

    test "all three Splunk Cloud collector forms, self-managed hosts and non-URLs do not warn" do
      for url <- [
            "https://http-inputs-acme.splunkcloud.com/services/collector",
            "https://http-inputs.acme.splunkcloud.com/services/collector",
            "https://http-inputs.acme.splunkcloudgc.com/services/collector",
            "https://splunk.example.com:8088/services/collector",
            "https://notsplunkcloud.com/services/collector",
            "not a url",
            nil
          ] do
        assert SplunkHec.url_warning(url) == nil, inspect(url)
      end
    end
  end

  describe "validate_credential/2" do
    test "accepts a token and leaves a missing one to the required check" do
      assert SplunkHec.validate_credential(@token, %{}) == :ok
      assert SplunkHec.validate_credential(nil, %{}) == :ok
      assert SplunkHec.validate_credential("", %{}) == :ok
    end

    test "refuses a token that is not one sendable header word, without its value" do
      for token <- ["two words", "line\nbreak", "tab\there", "naïve"] do
        assert SplunkHec.validate_credential(token, %{}) ==
                 {:error, [credential: {"is invalid", validation: :header_value}]}
      end
    end
  end

  describe "through Destination.changeset/2" do
    test "the Splunk settings and token rules apply when a destination is saved" do
      changeset = fn overrides ->
        Destination.changeset(%Destination{}, destination_attrs(:splunk_hec, overrides))
      end

      assert changeset.(%{}).valid?

      bad_index = changeset.(%{settings: %{"index" => "Main"}})
      assert {"is invalid", [validation: :index]} = bad_index.errors[:settings]

      pasted = changeset.(%{credential: "8e1b6a3c-hec-token-wxyz\n"})
      assert {"is invalid", [validation: :header_value]} = pasted.errors[:credential]
      refute inspect(pasted.errors) =~ "hec-token"
    end

    test "a URL being set must be a HEC collector URL, and the error never quotes it" do
      changeset = fn url ->
        Destination.changeset(%Destination{}, destination_attrs(:splunk_hec, %{url: url}))
      end

      assert changeset.("https://splunk.example.com:8088/services/collector").valid?

      for {url, reason} <- [
            {"https://splunk.example.com:8088/services/collector/raw", :path},
            {"https://splunk.example.com:8088/services/collector?token=abc", :query}
          ] do
        refused = changeset.(url)
        assert {"is invalid", [validation: ^reason]} = refused.errors[:url]
        refute inspect(refused.errors) =~ "splunk.example.com"
      end
    end

    test "a URL Destination already refuses gets one error, not two" do
      for url <- [
            "https://collector.example.com/services/collector ",
            "https:///services/collector"
          ] do
        changeset =
          Destination.changeset(%Destination{}, destination_attrs(:splunk_hec, %{url: url}))

        assert [{"is invalid", [validation: :url]}] = Keyword.get_values(changeset.errors, :url)
      end
    end

    test "a stored URL is not re-checked by an edit that leaves it alone" do
      stored =
        struct!(Destination, %{
          kind: :splunk_hec,
          name: "Legacy",
          url: "https://collector.example.com/services/collector/raw",
          credential: @token,
          settings: %{}
        })

      assert Destination.changeset(stored, %{name: "Renamed"}).valid?
      refute Destination.changeset(stored, %{url: stored.url <> "/1"}).valid?
    end
  end

  describe "build_request/2" do
    test "request headers and inflated HEC body" do
      {url, headers, inflated} = request()

      assert url == @url

      assert headers == [
               {"content-type", "application/json"},
               {"content-encoding", "gzip"},
               {"user-agent", "Stride-AuditStream/1"},
               {"authorization", "Splunk " <> @token}
             ]

      refute Enum.any?(headers, fn {name, _value} -> name == "x-splunk-request-channel" end)

      [first, second] = String.split(inflated, "\n")
      assert first =~ ~r/"time":1794193366\.015[,}]/
      assert second =~ ~r/"time":1794193367\.000[,}]/

      [event1, event2] = events()

      assert lines(inflated) == [
               %{
                 "time" => 1_794_193_366.015,
                 "host" => "stridelikeaboss.com",
                 "source" => "stride",
                 "sourcetype" => "stride:audit",
                 "event" => event1
               },
               %{
                 "time" => 1_794_193_367.0,
                 "host" => "stridelikeaboss.com",
                 "source" => "stride",
                 "sourcetype" => "stride:audit",
                 "event" => event2
               }
             ]
    end

    test "the index and source type settings go in every event" do
      settings = %{"index" => "security", "source_type" => "stride:custom"}
      {_url, _headers, inflated} = request(destination(%{settings: settings}))

      for line <- lines(inflated) do
        assert line["index"] == "security"
        assert line["sourcetype"] == "stride:custom"
      end
    end

    test "blank index is left out" do
      for settings <- [%{}, %{"index" => ""}, %{"index" => nil}, nil] do
        {_url, _headers, inflated} = request(destination(%{settings: settings}))

        for line <- lines(inflated) do
          refute Map.has_key?(line, "index"), inspect(settings)
          assert line["sourcetype"] == "stride:audit"
        end
      end
    end

    test "an unreadable occurred_at leaves time null for Splunk to fill in" do
      batch = %{batch() | events: [event("1", "yesterday")]}
      {_url, _headers, body} = SplunkHec.build_request(destination(), batch)

      assert [%{"time" => nil}] = body |> :zlib.gunzip() |> lines()
    end

    test "a token that is not sendable is left out rather than sent or quoted" do
      for token <- ["two words", nil, ""] do
        {_url, headers, _inflated} = request(destination(%{credential: token}))
        assert header(headers, "authorization") == nil
      end
    end

    test "a destination without a readable URL raises without any secret" do
      error =
        assert_raise ArgumentError, fn ->
          %{url: :unreadable} |> destination() |> SplunkHec.build_request(batch())
        end

      refute Exception.message(error) =~ @token
    end
  end

  describe "classify/2" do
    test "every HEC code classifies per the table" do
      table = [
        {200, 0, :ok},
        {200, 24, :ok},
        {200, 25, :ok},
        {400, 5, :permanent},
        {400, 6, :permanent},
        {400, 12, :permanent},
        {400, 13, :permanent},
        {400, 15, :permanent},
        {400, 7, {:config_error, :incorrect_index}},
        {400, 10, {:config_error, :indexer_ack_enabled}},
        {400, 11, {:config_error, :indexer_ack_enabled}},
        {400, 14, {:config_error, :ack_disabled}},
        {400, 16, {:config_error, :query_string_auth}},
        {400, 21, :unauthorized},
        {400, 22, :unauthorized},
        {401, 2, :unauthorized},
        {403, 1, :unauthorized},
        {413, nil, :split},
        {429, 26, {:retry, nil}},
        {429, 27, {:retry, nil}},
        {503, 9, {:retry, nil}},
        {503, 18, {:retry, nil}},
        {503, 19, {:retry, nil}},
        {503, 20, {:retry, nil}},
        {503, 23, {:retry, nil}},
        {500, 8, {:retry, nil}},
        {502, nil, {:retry, nil}}
      ]

      capture_log(fn ->
        for {status, code, expected} <- table do
          assert SplunkHec.classify(status, hec(code)) == expected, "#{status} code #{code}"
        end
      end)
    end

    test "codes 24 and 25 are logged as a warning naming only the code" do
      for code <- [24, 25] do
        log = capture_log(fn -> assert SplunkHec.classify(200, hec(code)) == :ok end)
        assert log =~ "code #{code}"
        refute log =~ "Some Splunk text"
      end

      assert capture_log(fn -> SplunkHec.classify(200, hec(0)) end) == ""
    end

    test "unparseable 400 body is :permanent" do
      for body <- ["", "<html>Bad Request</html>", "[1,2]", hec("7"), hec(-1), hec(99)] do
        assert SplunkHec.classify(400, body) == :permanent, body
      end
    end

    test "a gzipped answer is read, within a bound" do
      gzipped = 7 |> hec() |> :zlib.gzip()
      assert SplunkHec.classify(400, gzipped) == {:config_error, :incorrect_index}
      assert SplunkHec.describe_error(400, gzipped) =~ "code 7"

      padded = hec(7, %{"text" => String.duplicate(" ", 70_000)})
      assert SplunkHec.classify(400, :zlib.gzip(padded)) == :permanent
      assert SplunkHec.classify(400, <<0x1F, 0x8B, 8, 0, "not gzip">>) == :permanent
      assert SplunkHec.describe_error(400, binary_part(gzipped, 0, 12)) == nil
    end

    test "a gzipped answer is inflated once, never layer after layer" do
      twice = 7 |> hec() |> :zlib.gzip() |> :zlib.gzip()

      assert SplunkHec.classify(400, twice) == :permanent
      assert SplunkHec.describe_error(400, twice) == nil
    end

    test "an empty or unparseable body still classifies by status" do
      assert SplunkHec.classify(503, "") == {:retry, nil}
      assert SplunkHec.classify(429, "") == {:retry, nil}
      assert SplunkHec.classify(408, "") == {:retry, nil}
      assert SplunkHec.classify(200, "") == :ok
      assert SplunkHec.classify(401, "") == :unauthorized
      assert SplunkHec.classify(413, "nope") == :split
      assert SplunkHec.classify(404, hec(0)) == :permanent
    end
  end

  describe "describe_error/2" do
    test "describe_error names invalid-event-number" do
      body = hec(6, %{"invalid-event-number" => 3})
      text = SplunkHec.describe_error(400, body)

      assert text =~ "HTTP 400"
      assert text =~ "code 6"
      assert text =~ "invalid-event-number 3"
      refute text =~ "Some Splunk text"
    end

    test "names the code alone, and never copies body text" do
      body = hec(7, %{"text" => "Incorrect index <script>Splunk abc-secret</script>"})
      text = SplunkHec.describe_error(400, body)

      assert text ==
               "Splunk HEC answered HTTP 400 with code 7 (the token can't write to the index)"

      refute text =~ "secret"
      refute text =~ "<script>"
    end

    test "names the fix for a configuration code and the fault for an unauthorized one" do
      for {code, fix} <- [
            {7, "can't write to the index"},
            {10, "turn off indexer acknowledgement"},
            {11, "turn off indexer acknowledgement"},
            {14, "does not use indexer acknowledgement"},
            {16, "remove the token from the HEC URL"},
            {21, "invalid or disabled"},
            {22, "invalid or disabled"}
          ] do
        assert SplunkHec.describe_error(400, hec(code)) =~ "code #{code} (", "code #{code}"
        assert SplunkHec.describe_error(400, hec(code)) =~ fix, "code #{code}"
      end

      assert SplunkHec.describe_error(503, hec(9)) == "Splunk HEC answered HTTP 503 with code 9"
    end

    test "invalid-event-number 0 does not claim earlier events may be indexed" do
      assert SplunkHec.describe_error(400, hec(6, %{"invalid-event-number" => 0})) ==
               "Splunk HEC answered HTTP 400 with code 6, invalid-event-number 0"
    end

    test "is nil when the body carries no numeric code" do
      for body <- ["", "Bad Request", hec("6"), Jason.encode!(%{"text" => "x"})] do
        assert SplunkHec.describe_error(400, body) == nil, body
      end
    end

    test "ignores an invalid-event-number that is not a whole number" do
      assert SplunkHec.describe_error(400, hec(6, %{"invalid-event-number" => "3 secret"})) ==
               "Splunk HEC answered HTTP 400 with code 6"
    end
  end

  describe "fix_message/2" do
    test "names a fix for each configuration reason" do
      assert SplunkHec.fix_message(:incorrect_index, %{"index" => "security"}) ==
               "The token can't write to index security"

      assert SplunkHec.fix_message(:incorrect_index, %{}) ==
               "The token can't write to its default index"

      assert SplunkHec.fix_message(:incorrect_index, nil) ==
               "The token can't write to its default index"

      assert SplunkHec.fix_message(:indexer_ack_enabled) ==
               "Turn off indexer acknowledgement on this HEC token"

      assert SplunkHec.fix_message(:ack_disabled) =~ "acknowledgement"
      assert SplunkHec.fix_message(:query_string_auth) =~ "HEC token"
      assert SplunkHec.fix_message(:something_else) =~ "Splunk HEC settings"
    end

    test "fix and warning messages are translated in all seven locales" do
      messages = fn ->
        [
          SplunkHec.fix_message(:incorrect_index, %{"index" => "security"}),
          SplunkHec.fix_message(:incorrect_index),
          SplunkHec.fix_message(:indexer_ack_enabled),
          SplunkHec.fix_message(:ack_disabled),
          SplunkHec.fix_message(:query_string_auth),
          SplunkHec.fix_message(:other),
          SplunkHec.url_warning("https://acme.splunkcloud.com/services/collector")
        ]
      end

      english = Gettext.with_locale(KanbanWeb.Gettext, "en", messages)

      for locale <- @locales -- ["en"] do
        translated = Gettext.with_locale(KanbanWeb.Gettext, locale, messages)

        for {text, source} <- Enum.zip(translated, english) do
          assert is_binary(text) and text != "" and text != source, "#{locale}: #{source}"
        end

        assert hd(translated) =~ "security", locale
      end
    end
  end

  test "max_event_age is :infinity" do
    assert SplunkHec.max_event_age() == :infinity
  end

  test "is the adapter for :splunk_hec" do
    assert Adapter.module_for(:splunk_hec) == SplunkHec
  end

  describe "through the transport" do
    test "request posted through Transport to a Req.Test stub arrives intact" do
      test = self()

      Req.Test.stub(Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, conn, body})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"text":"Success","code":0}))
      end)

      # Req.Test runs Plug.Parsers on an application/json body before the
      # stub, and a HEC batch of several events is not one JSON document, so
      # this posts a one-event batch; the newline-separated form is checked
      # in "request headers and inflated HEC body".
      one_event = %{batch() | events: Enum.take(events(), 1)}
      {url, headers, body} = SplunkHec.build_request(destination(), one_event)
      resolved = %{uri: URI.parse(url), addresses: [{93, 184, 216, 35}]}

      assert {:ok, %{status: 200, body: response}} = Transport.post(resolved, body, headers)
      assert SplunkHec.classify(200, response) == :ok

      assert_receive {:request, conn, inflated}
      assert conn.method == "POST"
      assert conn.request_path == "/services/collector/event"

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

      assert Plug.Conn.get_req_header(conn, "x-splunk-request-channel") == []
      assert inflated |> lines() |> Enum.map(& &1["event"]) == Enum.take(events(), 1)
    end
  end
end
