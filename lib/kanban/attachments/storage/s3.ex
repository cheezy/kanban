defmodule Kanban.Attachments.Storage.S3 do
  @moduledoc """
  Stores attachment bytes in an S3-compatible object store: Tigris on Fly,
  AWS S3 or MinIO. An adapter of `Kanban.Attachments.Storage`.

  Requests go through Req and are signed with its built-in `aws_sigv4`
  option, so no AWS SDK is needed. The service is always set to `:s3`
  explicitly: Req infers it only from AWS host names, and would otherwise
  refuse to sign for a Tigris or MinIO endpoint.

  Configuration, read at call time (`config/runtime.exs` fills it from the
  `ATTACHMENTS_S3_*` variables; see `docs/attachments.md`):

      config :kanban, Kanban.Attachments.Storage.S3,
        bucket: "stride-attachments",
        endpoint: "https://fly.storage.tigris.dev",
        region: "auto",
        access_key_id: "...",
        secret_access_key: "...",
        path_style: false,
        request_timeout: 60_000,
        req_options: []

  `endpoint` defaults to the AWS endpoint of `region`, and `region` to
  `"us-east-1"`. With `path_style: false` (the default) an object is
  addressed as `https://<bucket>.<endpoint host>/<key>`; with `true` as
  `https://<endpoint host>/<bucket>/<key>`, which MinIO usually needs.
  Path-style is used anyway for an IPv4-address endpoint or a dotted bucket
  name, and a path on the endpoint is kept as a prefix (see `object_url/2`).
  `req_options` are merged last, so tests can route requests to a
  `Req.Test` stub.

  Behaviour worth knowing:

    * A file upload is streamed from disk with an explicit `content-length`,
      which Req requires to sign a streamed body. It is then signed with
      `UNSIGNED-PAYLOAD`; an in-memory upload has its SHA-256 signed. A file
      that changes size while it is sent fails the put with a logged
      `:source_changed` and never sends a byte past its declared length.
    * Bodies are never decoded or decompressed, so a JSON or gzip object
      comes back byte for byte as it was stored.
    * `stream/1` reads the object with `into: :self`: the bytes arrive as
      messages to the process that called it, so enumerate the stream in
      that same process. It checks the status before returning, so a missing
      object is `{:error, :not_found}` rather than a stream that fails later.
    * Redirects are not followed, so a misconfigured endpoint cannot bounce a
      signed request to another host.
    * Each attempt waits at most 5 seconds to connect and 30 seconds for each
      read. A put, a delete and a HEAD also have an overall deadline,
      `request_timeout` (60 seconds), so a store that trickles its reply
      cannot hold the call; a download has none, since its body is the file.
    * An endpoint whose host is an IPv6 address is refused, with the reason
      `:ipv6_endpoint_unsupported` in the log, because Req signs and sends
      its Host header without the brackets. Use a host name for it instead.
      An endpoint `URI.new/1` cannot parse is refused as
      `:invalid_endpoint`, and a region that is not a plain region name
      (lowercase letters and digits joined by hyphens) as `:invalid_region`.
    * The enumerable is single-pass: enumerate it once, in the process
      that called `stream/1`. Halting early cancels the download.
    * Transient failures (a 408, 429, 500, 502, 503 or 504, a timeout, a
      refused or closed connection, or an HTTP/2 request the server never
      processed) are retried twice, 250 ms and then 500 ms apart. PUT and
      DELETE on a fixed key are idempotent, and these calls run inside user
      requests rather than a job with its own retries. A retried download is
      cancelled before the retry, so it leaves no stray messages behind.
    * A 404 whose error code is `NoSuchKey` is `:not_found` on a download
      and `:ok` on a delete. Any other 404 (`NoSuchBucket`, an empty body, a
      proxy's page) means the request reached no bucket, so it is
      `:storage_unavailable`, as is a 404 on a put and any other failure. A
      HEAD reply has no body, so its 404 is `{:ok, false}` either way.
      Only the operation, the HTTP status and a well-formed S3 error code
      are logged, never a header, a URL, a body or a credential.
  """

  @behaviour Kanban.Attachments.Storage

  require Logger

  @default_region "us-east-1"
  @default_request_timeout 60_000
  @default_content_type "application/octet-stream"
  defmodule SourceChanged do
    @moduledoc false
    # Raised inside a file upload's body when the file no longer has the
    # size its content-length declared; caught by the put that sent it.
    defexception message: "the file changed size while it was being uploaded"
  end

  @chunk_bytes 65_536
  @error_body_bytes 4_096
  @region_format ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @error_body_chunks 4

  @impl true
  def put(key, {:file, path}, opts) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        body = framed_body(path, size)
        upload(key, body, [{"content-length", Integer.to_string(size)}], opts)

      _not_a_file ->
        log_failure(:put, :source_unreadable)
    end
  end

  def put(key, {:binary, data}, opts), do: upload(key, data, [], opts)

  @impl true
  def stream(key), do: :get |> request(key, into: :self) |> stream_result()

  @impl true
  def exists(key) do
    case request(:head, key) do
      {:ok, %Req.Response{status: 200}} -> {:ok, true}
      {:ok, %Req.Response{status: 404}} -> {:ok, false}
      {:ok, %Req.Response{status: status}} -> status_error(:head, status)
      {:error, reason} -> log_failure(:head, reason)
    end
  end

  @impl true
  def delete(key), do: :delete |> request(key) |> delete_result()

  defp stream_result({:ok, %Req.Response{status: 200, body: body}}), do: {:ok, body}

  defp stream_result({:ok, %Req.Response{status: 404} = response}),
    do: response |> read_error_body() |> missing_or_failed(:get, {:error, :not_found})

  defp stream_result({:ok, %Req.Response{status: status} = response}) do
    _ = Req.cancel_async_response(response)
    status_error(:get, status)
  end

  defp stream_result({:error, reason}), do: log_failure(:get, reason)

  defp delete_result({:ok, %Req.Response{status: status}}) when status in 200..299, do: :ok

  defp delete_result({:ok, %Req.Response{status: 404} = response}),
    do: response |> read_error_body() |> missing_or_failed(:delete, :ok)

  defp delete_result({:ok, %Req.Response{status: status}}), do: status_error(:delete, status)
  defp delete_result({:error, reason}), do: log_failure(:delete, reason)

  @doc """
  The URL of the object stored under `key`: virtual-hosted by default,
  path-style when `path_style: true`. Pure, so URL building can be tested
  without a request.

  A path on the endpoint (`https://proxy.example/s3`) is kept as a prefix.
  Path-style is also used, whatever `path_style` says, when the endpoint host
  is an IP address or the bucket name contains a dot: a virtual-hosted URL
  cannot put a bucket in front of an IP address, and a dotted bucket breaks
  the store's wildcard TLS certificate, which is what the AWS SDKs do too.
  """
  @spec object_url(keyword(), String.t()) :: String.t()
  def object_url(config, key) when is_list(config) and is_binary(key) do
    bucket = Keyword.fetch!(config, :bucket)
    uri = config |> endpoint() |> URI.parse()
    prefix = (uri.path || "") |> String.trim_trailing("/")

    uri =
      if path_style?(config, uri.host, bucket),
        do: %URI{uri | path: "#{prefix}/#{bucket}/#{key}"},
        else: %URI{uri | host: "#{bucket}.#{uri.host}", path: "#{prefix}/#{key}"}

    URI.to_string(%URI{uri | query: nil, fragment: nil})
  end

  defp path_style?(config, host, bucket) do
    Keyword.get(config, :path_style, false) == true or String.contains?(bucket, ".") or
      ip_address?(host)
  end

  defp ip_address?(host) when is_binary(host),
    do: match?({:ok, _ip}, host |> to_charlist() |> :inet.parse_address())

  defp ip_address?(_host), do: false

  defp upload(key, body, headers, opts) do
    headers = [{"content-type", content_type(opts)} | headers]

    case request(:put, key, body: body, headers: headers) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> log_status(:put, status)
      {:error, reason} -> log_failure(:put, reason)
    end
  rescue
    SourceChanged -> log_failure(:put, :source_changed)
  end

  # A file's content-length is its size when it was checked, and the body is
  # read from disk only as it is sent. A file that grew in between used to
  # send bytes past the declared length, which the store read as the start
  # of the next request on that pooled connection (someone else's), while
  # this put returned :ok; one that shrank left the store waiting for bytes
  # until its read timeout. So the body is held to the declared length: a
  # chunk that would pass it, or an end that falls short of it, raises
  # before anything past the length is sent. The connection is then
  # dropped rather than returned to the pool (G488 exploratory campaign).
  defp framed_body(path, size) do
    path
    |> File.stream!(@chunk_bytes)
    |> Stream.transform(fn -> 0 end, &within_size(&1, &2, size), &at_size(&1, size), & &1)
  end

  defp within_size(chunk, sent, size) do
    sent = sent + byte_size(chunk)
    if sent > size, do: raise(SourceChanged), else: {[chunk], sent}
  end

  defp at_size(size, size), do: {[], size}
  defp at_size(_sent, _size), do: raise(SourceChanged)

  # SigV4 signs a header value trimmed, with runs of whitespace collapsed,
  # but Req signs it exactly as given, and HTTP drops a value's outer
  # whitespace in transit. So the value is put in that form before it is
  # signed and sent: otherwise " text/plain" was signed with its space, sent
  # without it, and refused by the store (G488 exploratory campaign).
  defp content_type(opts) do
    (Keyword.get(opts, :content_type) || @default_content_type)
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> case do
      "" -> @default_content_type
      value -> value
    end
  end

  defp request(method, key, extra \\ []) do
    case config() do
      {:ok, config} -> send_request(method, key, config, extra)
      :error -> {:error, :not_configured}
    end
  end

  defp send_request(method, key, config, extra) do
    case config_problem(config) do
      nil -> sign_and_send(method, key, config, extra)
      problem -> {:error, problem}
    end
  end

  defp sign_and_send(method, key, config, extra) do
    [method: method, url: object_url(config, key), aws_sigv4: sigv4(config)]
    |> Keyword.merge(base_options())
    |> Keyword.merge(deadline(method, config))
    |> Keyword.merge(extra)
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.request()
  end

  # config/runtime.exs refuses these at boot; they are checked again here
  # because the adapter's config can be set by other means.
  #
  #   * The region is part of the default AWS host name, so one such as
  #     "x.example?" sent signed requests to another host.
  #   * Req builds the signed Host header from the bare URL host, so an IPv6
  #     literal went out as "::1:9000" instead of "[::1]:9000", which names a
  #     different host. A host name that resolves to the address works.
  #   * An endpoint URI.new/1 cannot parse is not guessed at: URI.parse/1
  #     read "http://[fe80::1%25en0]:9000" as host "fe80", port 80.
  defp config_problem(config) do
    region = Keyword.get(config, :region)

    if is_nil(region) or region =~ @region_format,
      do: endpoint_problem(endpoint(config)),
      else: :invalid_region
  end

  defp endpoint_problem(endpoint) do
    case URI.new(endpoint) do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" ->
        if String.contains?(host, ":"), do: :ipv6_endpoint_unsupported

      _unparseable ->
        :invalid_endpoint
    end
  end

  # receive_timeout bounds each socket read, not the whole response, so a
  # store that trickles its reply a byte at a time held a request (and the
  # cleanup worker's single queue slot) for as long as it kept trickling.
  # A put, a delete and a HEAD get only a short reply, so each attempt also
  # has an overall deadline. A download is left unbounded: its body is the
  # file, and a large one on a slow link takes as long as it takes.
  defp deadline(:get, _config), do: []

  defp deadline(_method, config),
    do: [request_timeout: Keyword.get(config, :request_timeout, @default_request_timeout)]

  defp sigv4(config) do
    [
      service: :s3,
      region: Keyword.get(config, :region) || @default_region,
      access_key_id: Keyword.fetch!(config, :access_key_id),
      secret_access_key: Keyword.fetch!(config, :secret_access_key)
    ]
  end

  defp base_options do
    [
      redirect: false,
      retry: &retry?/2,
      retry_delay: &retry_delay/1,
      max_retries: 2,
      retry_log_level: false,
      compressed: false,
      decode_body: false,
      connect_options: [timeout: 5_000],
      receive_timeout: 30_000
    ]
  end

  # Every required setting must be present and non-empty; nothing is
  # logged about which one is missing here, runtime.exs names it at boot.
  defp config do
    config = Application.get_env(:kanban, __MODULE__, [])

    if Enum.all?([:bucket, :access_key_id, :secret_access_key], &present?(config[&1])),
      do: {:ok, config},
      else: :error
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp endpoint(config) do
    case Keyword.get(config, :endpoint) do
      endpoint when is_binary(endpoint) and endpoint != "" ->
        endpoint

      _unset ->
        "https://s3.#{Keyword.get(config, :region) || @default_region}.amazonaws.com"
    end
  end

  # Req's `retry: :transient`, plus one thing it lacks: a retried response
  # read with `into: :self` is cancelled first. Req would otherwise abandon
  # it, and its remaining chunks would arrive as stray messages in the
  # caller's mailbox (a LiveView, say). Every method is retried, because PUT
  # and DELETE on a fixed key are idempotent.
  @transient_statuses [408, 429, 500, 502, 503, 504]

  defp retry?(_request, %Req.Response{status: status} = response)
       when status in @transient_statuses do
    cancel_async(response)
    true
  end

  defp retry?(_request, %Req.TransportError{reason: reason})
       when reason in [:timeout, :econnrefused, :closed],
       do: true

  defp retry?(_request, %Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available],
       do: true

  defp retry?(_request, _response_or_exception), do: false

  defp cancel_async(%Req.Response{body: %Req.Response.Async{}} = response) do
    _ = Req.cancel_async_response(response)
    :ok
  end

  defp cancel_async(_response), do: :ok

  # 250 ms, then 500 ms. Fixed rather than taken from a Retry-After header,
  # so a store asking for a long pause cannot stall a user request with it.
  defp retry_delay(attempt), do: 250 * Integer.pow(2, attempt)

  defp status_error(operation, status), do: log_status(operation, status)

  # S3 answers 404 for a missing object (NoSuchKey) and for a missing bucket
  # (NoSuchBucket), and a wrong endpoint or a proxy may answer 404 too. Only
  # NoSuchKey says the object is gone. Mapping every 404 by its status let
  # the cleanup worker drop the tombstones of every blob it "deleted" from a
  # bucket that did not exist, logging nothing, and made a missing bucket
  # look like a missing file (G488 exploratory campaign, 2026-11-02).
  defp missing_or_failed(body, operation, missing) do
    case error_code(body) do
      "NoSuchKey" -> missing
      code -> log_status(operation, 404, code)
    end
  end

  # An error body is a few hundred bytes; at most @error_body_bytes of it, in
  # at most @error_body_chunks reads, are taken, so a reply that trickles
  # cannot hold the call for long. A body that fails to arrive is no code.
  defp read_error_body(%Req.Response{body: %Req.Response.Async{} = async}) do
    async
    |> Enum.reduce_while({[], 0, 0}, fn data, {acc, bytes, chunks} ->
      next = {[acc | data], bytes + IO.iodata_length(data), chunks + 1}
      if full?(next), do: {:halt, next}, else: {:cont, next}
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  rescue
    _exception -> ""
  catch
    :exit, _reason -> ""
  end

  defp read_error_body(%Req.Response{body: body}) when is_binary(body), do: body
  defp read_error_body(_response), do: ""

  defp full?({_acc, bytes, chunks}),
    do: bytes >= @error_body_bytes or chunks >= @error_body_chunks

  # Only a code made of letters, as every S3 error code is, is kept, so
  # nothing else from the body can reach the log.
  defp error_code(body) do
    head = binary_part(body, 0, min(byte_size(body), @error_body_bytes))

    case Regex.run(~r|<Code>([A-Za-z]{1,64})</Code>|, head) do
      [_match, code] -> code
      nil -> nil
    end
  end

  defp log_status(operation, status, code \\ nil)

  defp log_status(operation, status, nil) do
    Logger.warning("attachment storage #{operation} failed with status #{status}")
    {:error, :storage_unavailable}
  end

  defp log_status(operation, status, code) do
    Logger.warning("attachment storage #{operation} failed with status #{status} (#{code})")
    {:error, :storage_unavailable}
  end

  # Only the operation and the error's kind are logged: an exception struct
  # can carry request details, so it is never inspected whole. A transport or
  # HTTP error adds its reason when that is a bare atom (:timeout,
  # :econnrefused, :closed, ...), which names the failure and holds nothing
  # from the request; a tuple reason (a TLS alert, say) is left out.
  defp log_failure(operation, reason) do
    Logger.warning("attachment storage #{operation} failed: #{failure_kind(reason)}")
    {:error, :storage_unavailable}
  end

  defp failure_kind(%struct{reason: reason})
       when struct in [Req.TransportError, Req.HTTPError] and is_atom(reason),
       do: "#{inspect(struct)} (#{inspect(reason)})"

  defp failure_kind(%{__exception__: true, __struct__: struct}), do: inspect(struct)
  defp failure_kind(reason) when is_atom(reason), do: inspect(reason)
  defp failure_kind(_reason), do: "unknown"
end
