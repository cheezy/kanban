defmodule Kanban.Attachments.Storage.S3Test do
  # Not async: some tests change the application-wide S3 config. Every
  # request goes to the Req.Test stub configured in config/test.exs.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kanban.Attachments.Storage.S3

  @key "boards/12/0b9c4e2a-6f1d-4c8e-9a7b-3d2e1f0a9b8c"

  setup do
    previous = Application.get_env(:kanban, S3)
    on_exit(fn -> restore(S3, previous) end)
    %{config: previous}
  end

  defp put_config(changes) do
    Application.put_env(:kanban, S3, Keyword.merge(Application.get_env(:kanban, S3), changes))
  end

  # Replies `status` with `body` and `headers`, reporting each request.
  defp stub(status, body \\ "", headers \\ []) do
    test = self()

    Req.Test.stub(S3, fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, request_body})

      headers
      |> Enum.reduce(conn, fn {name, value}, conn ->
        Plug.Conn.put_resp_header(conn, name, value)
      end)
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  defp read_all(stream), do: stream |> Enum.to_list() |> IO.iodata_to_binary()

  test "signs a put with AWS4-HMAC-SHA256 for the s3 service and configured region" do
    stub(200)

    assert :ok = S3.put(@key, {:binary, "hello"}, content_type: "text/plain")
    assert_received {:request, conn, "hello"}

    assert conn.method == "PUT"
    assert header(conn, "content-type") == "text/plain"

    date = Calendar.strftime(DateTime.utc_now(), "%Y%m%d")
    authorization = header(conn, "authorization")

    assert authorization =~
             ~r"\AAWS4-HMAC-SHA256 Credential=test-access-key-id/#{date}/test-region/s3/aws4_request,"

    assert authorization =~ "SignedHeaders="
    assert authorization =~ "Signature="
    refute authorization =~ "test-secret-access-key"

    sha = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
    assert header(conn, "x-amz-content-sha256") == sha
    assert header(conn, "x-amz-date")
  end

  test "defaults the content type of a put to application/octet-stream" do
    stub(200)
    assert :ok = S3.put(@key, {:binary, ["a", "b"]}, [])
    assert_received {:request, conn, "ab"}
    assert header(conn, "content-type") == "application/octet-stream"
  end

  test "uses a virtual-hosted URL by default and a path-style URL when configured" do
    stub(200)

    assert :ok = S3.put(@key, {:binary, "x"}, [])
    assert_received {:request, conn, _body}
    assert conn.scheme == :https
    assert conn.host == "test-bucket.storage.test"
    assert conn.request_path == "/" <> @key

    put_config(path_style: true)

    assert :ok = S3.put(@key, {:binary, "x"}, [])
    assert_received {:request, conn, _body}
    assert conn.host == "storage.test"
    assert conn.request_path == "/test-bucket/" <> @key
  end

  describe "object_url/2" do
    test "builds virtual-hosted and path-style URLs, keeping a custom port" do
      config = [bucket: "files", endpoint: "http://localhost:9000"]

      assert S3.object_url(config, "a/b") == "http://files.localhost:9000/a/b"

      assert S3.object_url([path_style: true] ++ config, "a/b") ==
               "http://localhost:9000/files/a/b"
    end

    test "keeps a path on the endpoint as a prefix in both styles" do
      config = [bucket: "files", endpoint: "https://proxy.test/s3/"]

      assert S3.object_url(config, "a/b") == "https://files.proxy.test/s3/a/b"

      assert S3.object_url([path_style: true] ++ config, "a/b") ==
               "https://proxy.test/s3/files/a/b"
    end

    test "uses path style for an IP address endpoint and for a dotted bucket" do
      assert S3.object_url([bucket: "files", endpoint: "http://127.0.0.1:9000"], "k") ==
               "http://127.0.0.1:9000/files/k"

      assert S3.object_url([bucket: "files", endpoint: "http://[::1]:9000"], "k") ==
               "http://[::1]:9000/files/k"

      assert S3.object_url([bucket: "my.files", region: "eu-west-1"], "k") ==
               "https://s3.eu-west-1.amazonaws.com/my.files/k"
    end

    test "defaults the endpoint to the AWS endpoint of the region" do
      assert S3.object_url([bucket: "files", region: "eu-west-1"], "k") ==
               "https://files.s3.eu-west-1.amazonaws.com/k"

      assert S3.object_url([bucket: "files"], "k") ==
               "https://files.s3.us-east-1.amazonaws.com/k"
    end
  end

  test "streams a file upload with an explicit content-length" do
    stub(200)
    dir = Path.join(System.tmp_dir!(), "stride_s3_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "upload.bin")
    bytes = :crypto.strong_rand_bytes(150_000)
    File.write!(path, bytes)

    assert :ok = S3.put(@key, {:file, path}, content_type: "image/png")
    assert_received {:request, conn, ^bytes}

    assert header(conn, "content-length") == "150000"
    assert header(conn, "x-amz-content-sha256") == "UNSIGNED-PAYLOAD"
    assert header(conn, "content-type") == "image/png"
  end

  test "refuses a file source that cannot be read, without a request" do
    stub(200)

    log =
      capture_log(fn ->
        assert {:error, :storage_unavailable} = S3.put(@key, {:file, "/no/such/upload"}, [])
      end)

    assert log =~ "attachment storage put failed"
    refute_received {:request, _conn, _body}
  end

  test "returns raw bytes for a JSON object without decoding" do
    json = ~s({"a":1,"b":[true]})
    stub(200, json, [{"content-type", "application/json"}])

    assert {:ok, stream} = S3.stream(@key)
    assert read_all(stream) == json
    assert_received {:request, conn, ""}
    assert conn.method == "GET"
    assert header(conn, "authorization") =~ "/s3/aws4_request"
  end

  test "returns gzip bytes unchanged, never decompressed" do
    gzipped = :zlib.gzip("compressed content")
    stub(200, gzipped, [{"content-type", "application/gzip"}, {"content-encoding", "gzip"}])

    assert {:ok, stream} = S3.stream(@key)
    assert read_all(stream) == gzipped
  end

  test "maps 404 to not_found and treats delete of a missing object as ok" do
    stub(404, "<Error><Code>NoSuchKey</Code></Error>")
    assert {:error, :not_found} = S3.stream(@key)
    assert_received {:request, %{method: "GET"}, _body}
    assert Process.info(self(), :messages) == {:messages, []}

    assert :ok = S3.delete(@key)
    assert_received {:request, %{method: "DELETE"} = conn, _body}
    assert conn.request_path == "/" <> @key

    stub(204)
    assert :ok = S3.delete(@key)
  end

  test "maps 403 and 500 to storage_unavailable without logging credentials" do
    for status <- [403, 500] do
      stub(status, "<Error><Code>Denied</Code></Error>")

      log =
        capture_log(fn ->
          assert {:error, :storage_unavailable} = S3.put(@key, {:binary, "x"}, [])
          assert {:error, :storage_unavailable} = S3.stream(@key)
          assert {:error, :storage_unavailable} = S3.delete(@key)
          assert {:error, :storage_unavailable} = S3.exists(@key)
        end)

      assert log =~ "attachment storage put failed with status #{status}"
      assert log =~ "attachment storage get failed with status #{status}"

      for secret <- ["test-secret-access-key", "test-access-key-id", "AWS4-HMAC", "storage.test"] do
        refute log =~ secret
      end
    end
  end

  test "logs a put that gets 404, a missing bucket, as storage_unavailable" do
    stub(404, "<Error><Code>NoSuchBucket</Code></Error>")

    log =
      capture_log(fn ->
        assert {:error, :storage_unavailable} = S3.put(@key, {:binary, "x"}, [])
      end)

    assert log =~ "attachment storage put failed with status 404"
  end

  # A Req adapter whose first call fails the way an HTTP/2 connection does
  # when the server refuses a stream before processing it. Req.Test plugs
  # can only raise transport errors, so this stands in for the adapter.
  defmodule Http2Unprocessed do
    def run(request) do
      case Agent.get_and_update(__MODULE__, &{&1, &1 + 1}) do
        0 -> {request, %Req.HTTPError{protocol: :http2, reason: :unprocessed}}
        _call -> {request, Req.Response.new(status: 200)}
      end
    end
  end

  test "retries an HTTP/2 request the server never processed" do
    start_supervised!(%{
      id: Http2Unprocessed,
      start: {Agent, :start_link, [fn -> 0 end, [name: Http2Unprocessed]]}
    })

    put_config(req_options: [adapter: Http2Unprocessed, retry_delay: 0])

    assert :ok = S3.put(@key, {:binary, "x"}, [])
    assert Agent.get(Http2Unprocessed, & &1) == 2
  end

  test "maps a transport error to storage_unavailable" do
    Req.Test.stub(S3, &Req.Test.transport_error(&1, :econnrefused))

    log =
      capture_log(fn ->
        assert {:error, :storage_unavailable} = S3.put(@key, {:binary, "x"}, [])
        assert {:error, :storage_unavailable} = S3.exists(@key)
      end)

    assert log =~ "attachment storage put failed: Req.TransportError (:econnrefused)"
    assert log =~ "attachment storage head failed: Req.TransportError (:econnrefused)"
    refute log =~ "test-secret-access-key"
  end

  test "a transport error whose reason is not an atom logs only its kind" do
    Req.Test.stub(S3, &Req.Test.transport_error(&1, {:tls_alert, {:handshake_failure, ~c"x"}}))

    # Colours off: the "\n" anchor proves nothing follows the kind, and an ANSI
    # terminal would put "\e[0m" before the newline.
    log =
      capture_log([colors: [enabled: false]], fn ->
        assert {:error, :storage_unavailable} = S3.put(@key, {:binary, "x"}, [])
      end)

    assert log =~ "attachment storage put failed: Req.TransportError\n"
    refute log =~ "tls_alert"
  end

  test "retries a transient failure on every operation, streaming the retried response" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(S3, fn conn ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        call when rem(call, 2) == 0 -> Plug.Conn.send_resp(conn, 503, "slow down")
        _call -> Plug.Conn.send_resp(conn, 200, "after retry")
      end
    end)

    assert :ok = S3.put(@key, {:binary, "x"}, [])
    assert {:ok, stream} = S3.stream(@key)
    assert read_all(stream) == "after retry"
    assert {:ok, true} = S3.exists(@key)
    assert :ok = S3.delete(@key)
    assert Agent.get(calls, & &1) == 8
    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "gives up after two retries with storage_unavailable" do
    test = self()

    Req.Test.stub(S3, fn conn ->
      send(test, :attempt)
      Plug.Conn.send_resp(conn, 500, "down")
    end)

    capture_log(fn -> assert {:error, :storage_unavailable} = S3.stream(@key) end)

    for _attempt <- 1..3, do: assert_received(:attempt)
    refute_received :attempt
    assert Process.info(self(), :messages) == {:messages, []}
  end

  test "exists maps HEAD 200 to true and 404 to false" do
    stub(200)
    assert {:ok, true} = S3.exists(@key)
    assert_received {:request, %{method: "HEAD"}, _body}

    stub(404)
    assert {:ok, false} = S3.exists(@key)
  end

  test "answers storage_unavailable when the bucket or credentials are not configured" do
    stub(200)
    put_config(bucket: nil)

    capture_log(fn ->
      assert {:error, :storage_unavailable} = S3.put(@key, {:binary, "x"}, [])
      assert {:error, :storage_unavailable} = S3.exists(@key)
    end)

    refute_received {:request, _conn, _body}
  end

  describe "header values are signed as they are sent" do
    test "the content type is trimmed and its runs of whitespace collapsed" do
      stub(200)

      assert :ok =
               S3.put(@key, {:binary, "x"}, content_type: "  text/plain;   charset=utf-8\t")

      assert_received {:request, conn, _body}
      assert header(conn, "content-type") == "text/plain; charset=utf-8"

      # content-type is among the signed headers, so what was signed is the
      # value that was sent.
      assert header(conn, "authorization") =~ "SignedHeaders=content-type;"
    end

    test "a content type that is only whitespace falls back to the default" do
      stub(200)

      assert :ok = S3.put(@key, {:binary, "x"}, content_type: " \t ")
      assert_received {:request, conn, _body}
      assert header(conn, "content-type") == "application/octet-stream"
    end
  end

  describe "an IPv6-address endpoint" do
    test "is refused for every operation, with no request sent" do
      stub(200)

      for endpoint <- ["http://[::1]:9000", "https://[2001:db8::5]/s3"] do
        put_config(endpoint: endpoint)

        log =
          capture_log(fn ->
            assert {:error, :storage_unavailable} = S3.put(@key, {:binary, "x"}, [])
            assert {:error, :storage_unavailable} = S3.stream(@key)
            assert {:error, :storage_unavailable} = S3.exists(@key)
            assert {:error, :storage_unavailable} = S3.delete(@key)
          end)

        assert log =~ "attachment storage put failed: :ipv6_endpoint_unsupported"
        assert log =~ "attachment storage delete failed: :ipv6_endpoint_unsupported"
      end

      refute_received {:request, _conn, _body}
    end

    test "a scoped IPv6 endpoint, which URI.parse misreads, is refused too" do
      stub(200)
      put_config(endpoint: "http://[fe80::1%25en0]:9000")

      log = capture_log(fn -> assert {:error, :storage_unavailable} = S3.exists(@key) end)

      assert log =~ "attachment storage head failed: :invalid_endpoint"
      refute_received {:request, _conn, _body}
    end

    test "an endpoint that does not parse is refused" do
      stub(200)

      for endpoint <- ["https://h.test:abc", "https://h .test", "not a url"] do
        put_config(endpoint: endpoint)
        log = capture_log(fn -> assert {:error, :storage_unavailable} = S3.delete(@key) end)
        assert log =~ "attachment storage delete failed: :invalid_endpoint"
      end

      refute_received {:request, _conn, _body}
    end

    test "a region that is not a plain region name is refused before it builds a host" do
      stub(200)
      put_config(endpoint: nil)

      for region <- ["attacker.test?", "x.attacker.test/", "a@attacker.test", " us-east-1"] do
        put_config(region: region)
        log = capture_log(fn -> assert {:error, :storage_unavailable} = S3.exists(@key) end)
        assert log =~ "attachment storage head failed: :invalid_region"
      end

      refute_received {:request, _conn, _body}

      put_config(region: "eu-west-1")
      assert {:ok, true} = S3.exists(@key)
      assert_received {:request, conn, _body}
      assert conn.host == "test-bucket.s3.eu-west-1.amazonaws.com"
    end

    test "an IPv4-address endpoint still works, path-style" do
      stub(200)
      put_config(endpoint: "http://10.0.0.5:9000")

      assert :ok = S3.put(@key, {:binary, "x"}, [])
      assert_received {:request, conn, _body}
      assert conn.request_path == "/#{Application.get_env(:kanban, S3)[:bucket]}/#{@key}"
    end
  end

  describe "a 404 that is not NoSuchKey" do
    @no_such_bucket "<Error><Code>NoSuchBucket</Code><Message>The specified bucket does not exist</Message></Error>"

    test "is storage_unavailable on a download and a delete, logged with its code" do
      stub(404, @no_such_bucket)

      log =
        capture_log(fn ->
          assert {:error, :storage_unavailable} = S3.stream(@key)
          assert {:error, :storage_unavailable} = S3.delete(@key)
        end)

      assert log =~ "attachment storage get failed with status 404 (NoSuchBucket)"
      assert log =~ "attachment storage delete failed with status 404 (NoSuchBucket)"
      refute log =~ "specified bucket"
    end

    test "an empty 404 or a proxy's page is storage_unavailable too, with no code" do
      for body <- ["", "<html><body><h1>404 Not Found</h1></body></html>"] do
        stub(404, body)

        # Colours off so the "\n" anchor below holds on an ANSI terminal too.
        log =
          capture_log([colors: [enabled: false]], fn ->
            assert {:error, :storage_unavailable} = S3.stream(@key)
            assert {:error, :storage_unavailable} = S3.delete(@key)
          end)

        assert log =~ "attachment storage delete failed with status 404\n"
        refute log =~ "html"
      end
    end

    test "only a code made of letters reaches the log" do
      for code <- ["token=abc123 secret", "No Such<script>Bucket"] do
        stub(404, "<Error><Code>#{code}</Code></Error>")

        log =
          capture_log([colors: [enabled: false]], fn ->
            assert {:error, :storage_unavailable} = S3.delete(@key)
          end)

        assert log =~ "attachment storage delete failed with status 404\n"
        refute log =~ "secret"
        refute log =~ "script"
      end
    end

    test "a HEAD has no body to read, so its 404 is still absent" do
      stub(404, @no_such_bucket)
      assert {:ok, false} = S3.exists(@key)
    end
  end

  describe "a 404 read from a real socket" do
    # The download path reads a streamed (async) body, which the Req.Test
    # plug does not produce; the stub replies with the code named in the
    # key's last segment, a byte every 20 ms for "trickle".
    defmodule ErrorStub do
      @behaviour Plug

      @impl true
      def init(opts), do: opts

      @impl true
      def call(conn, _opts) do
        case List.last(conn.path_info) do
          "trickle" -> trickle(Plug.Conn.send_chunked(conn, 404))
          code -> Plug.Conn.send_resp(conn, 404, "<Error><Code>#{code}</Code></Error>")
        end
      end

      defp trickle(conn) do
        Enum.reduce_while(1..200, conn, fn _i, conn ->
          Process.sleep(20)

          case Plug.Conn.chunk(conn, "x") do
            {:ok, conn} -> {:cont, conn}
            {:error, _closed} -> {:halt, conn}
          end
        end)
      end
    end

    setup do
      {:ok, server} =
        Bandit.start_link(plug: ErrorStub, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> stop_server(server) end)

      put_config(
        endpoint: "http://127.0.0.1:#{port}",
        path_style: true,
        req_options: [retry: false]
      )

      :ok
    end

    test "NoSuchKey is not_found and NoSuchBucket is storage_unavailable" do
      assert {:error, :not_found} = S3.stream("boards/1/NoSuchKey")

      log =
        capture_log(fn ->
          assert {:error, :storage_unavailable} = S3.stream("boards/1/NoSuchBucket")
        end)

      assert log =~ "attachment storage get failed with status 404 (NoSuchBucket)"
    end

    test "a trickling 404 body is read for a few chunks only" do
      {elapsed_us, {result, _log}} =
        :timer.tc(fn -> with_log(fn -> S3.stream("boards/1/trickle") end) end)

      assert result == {:error, :storage_unavailable}
      assert elapsed_us < 1_000_000
    end
  end

  describe "a store that trickles its reply" do
    # A real socket, not the Req.Test plug: receive_timeout bounds each read,
    # so only a reply that keeps arriving shows whether the whole call is
    # bounded. The stub sends one byte every 20 ms for about 2 seconds.
    defmodule TrickleStub do
      @behaviour Plug

      @impl true
      def init(opts), do: opts

      @impl true
      def call(conn, _opts) do
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce_while(1..100, conn, fn _i, conn ->
          Process.sleep(20)

          case Plug.Conn.chunk(conn, "x") do
            {:ok, conn} -> {:cont, conn}
            {:error, _closed} -> {:halt, conn}
          end
        end)
      end
    end

    setup do
      {:ok, server} =
        Bandit.start_link(plug: TrickleStub, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> stop_server(server) end)

      put_config(
        endpoint: "http://127.0.0.1:#{port}",
        path_style: true,
        request_timeout: 300,
        req_options: [retry: false]
      )

      :ok
    end

    test "a delete gives up at request_timeout instead of waiting out the trickle" do
      {elapsed_us, {result, log}} =
        :timer.tc(fn -> with_log(fn -> S3.delete(@key) end) end)

      assert result == {:error, :storage_unavailable}
      assert elapsed_us < 1_500_000
      assert log =~ "attachment storage delete failed"
    end

    test "a download is not cut off by request_timeout" do
      assert {:ok, chunks} = S3.stream(@key)
      assert byte_size(read_all(chunks)) == 100
    end
  end

  describe "a file that changes size while it is uploaded" do
    # A real socket, so bytes past the declared content-length would reach
    # the store as the start of the next request on the pooled connection.
    defmodule StoreStub do
      @behaviour Plug

      @impl true
      def init(test), do: test

      @impl true
      def call(conn, test) do
        send(test, {:store_saw, conn.method, conn.request_path})

        case conn.method do
          "PUT" ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test, {:stored, conn.request_path, body})
            :persistent_term.put({__MODULE__, conn.request_path}, body)
            Plug.Conn.send_resp(conn, 200, "")

          "GET" ->
            body = :persistent_term.get({__MODULE__, conn.request_path}, nil)

            if body,
              do: Plug.Conn.send_resp(conn, 200, body),
              else: Plug.Conn.send_resp(conn, 404, "")

          _other ->
            Plug.Conn.send_resp(conn, 400, "")
        end
      end
    end

    setup %{tmp_dir: tmp_dir} do
      {:ok, server} =
        Bandit.start_link(
          plug: {StoreStub, self()},
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      on_exit(fn -> stop_server(server) end)

      put_config(
        endpoint: "http://127.0.0.1:#{port}",
        path_style: true,
        req_options: [retry: false]
      )

      %{path: Path.join(tmp_dir, "upload")}
    end

    # Rewrites the file once, after put/3 has read its size and before the
    # body is read, from the process that makes the request.
    defp rewrite_after_stat(path, bytes) do
      id = {__MODULE__, make_ref()}

      :telemetry.attach(
        id,
        [:finch, :request, :start],
        fn _event, _measurements, %{request: %{method: "PUT"}}, _config ->
          File.write!(path, bytes)
          :telemetry.detach(id)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    defp neighbour_reads_back do
      :ok = S3.put("boards/1/neighbour", {:binary, "abc"}, [])

      fn ->
        assert {:ok, chunks} = S3.stream("boards/1/neighbour")
        read_all(chunks)
      end
    end

    @tag :tmp_dir
    test "a file that grew fails the put and never corrupts the next request", %{path: path} do
      read_neighbour = neighbour_reads_back()
      File.write!(path, "")
      rewrite_after_stat(path, "hello")

      log =
        capture_log(fn ->
          assert {:error, :storage_unavailable} = S3.put(@key, {:file, path}, [])
        end)

      assert log =~ "attachment storage put failed: :source_changed"
      assert read_neighbour.() == "abc"
      assert read_neighbour |> Task.async() |> Task.await() == "abc"
      refute_received {:store_saw, "hello" <> _, _}

      for {:store_saw, method, _path} <- flush_seen(), do: assert(method in ["PUT", "GET"])
    end

    @tag :tmp_dir
    test "a file that grew past a non-empty size sends no byte past it", %{path: path} do
      File.write!(path, "hello")
      rewrite_after_stat(path, "helloWORLD")

      log =
        capture_log(fn ->
          assert {:error, :storage_unavailable} = S3.put(@key, {:file, path}, [])
        end)

      assert log =~ ":source_changed"
      refute_received {:stored, _path, _body}
      assert neighbour_reads_back().() == "abc"
    end

    @tag :tmp_dir
    test "a file that shrank fails at once instead of waiting on the store", %{path: path} do
      File.write!(path, "hello")
      rewrite_after_stat(path, "he")

      {elapsed_us, log} =
        :timer.tc(fn ->
          capture_log(fn ->
            assert {:error, :storage_unavailable} = S3.put(@key, {:file, path}, [])
          end)
        end)

      assert log =~ ":source_changed"
      assert elapsed_us < 2_000_000
      refute_received {:stored, _path, _body}
    end

    @tag :tmp_dir
    test "a file that keeps its size uploads whole", %{path: path} do
      File.write!(path, "hello")

      assert :ok = S3.put(@key, {:file, path}, [])
      assert_received {:stored, _path, "hello"}
    end
  end

  defp flush_seen do
    receive do
      {:store_saw, _method, _path} = seen -> [seen | flush_seen()]
    after
      0 -> []
    end
  end

  defp stop_server(server) do
    if Process.alive?(server), do: Supervisor.stop(server)
  catch
    :exit, _reason -> :ok
  end

  defp restore(module, nil), do: Application.delete_env(:kanban, module)
  defp restore(module, previous), do: Application.put_env(:kanban, module, previous)
end
