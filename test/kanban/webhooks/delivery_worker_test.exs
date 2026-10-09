defmodule Kanban.Webhooks.DeliveryWorkerTest do
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import ExUnit.CaptureLog
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures
  import Kanban.WebhooksFixtures

  alias Kanban.Columns
  alias Kanban.Repo
  alias Kanban.Webhooks
  alias Kanban.Webhooks.Delivery
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Payload
  alias Kanban.Webhooks.Signer
  alias Kanban.Webhooks.Transport

  @slack_url "https://hooks.slack.com/services/T000/B000/XXXX"

  setup do
    board = ai_optimized_board_fixture(user_fixture())
    column = board |> Columns.list_columns() |> Enum.find(&(&1.name == "Doing"))
    task = task_fixture(column, %{title: "Ship <it> & more", completion_notes: "secret notes"})
    {:ok, payload} = Payload.build("task.moved", task)
    Repo.delete_all(Oban.Job)

    %{
      board: board,
      task: task,
      payload: payload,
      endpoint: webhook_endpoint_fixture(board, url: "https://hooks.example.com/stride")
    }
  end

  defp args(endpoint, payload, event \\ "task.moved") do
    %{
      "endpoint_id" => endpoint.id,
      "delivery_id" => "dlv-1",
      "event" => event,
      "payload" => payload
    }
  end

  # Replies `status` with `body`, reporting each request to the test process.
  defp stub(status, body \\ "ok") do
    test = self()

    Req.Test.stub(Transport, fn conn ->
      {:ok, request_body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, request_body})
      Plug.Conn.send_resp(conn, status, body)
    end)
  end

  defp deliveries(endpoint) do
    Delivery |> where(endpoint_id: ^endpoint.id) |> order_by(:id) |> Repo.all()
  end

  describe "a generic endpoint" do
    test "a 2xx sends the signed envelope and records a succeeded delivery", ctx do
      stub(204)

      assert :ok = perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))

      assert_received {:request, conn, body}
      assert conn.method == "POST"
      assert Plug.Conn.get_req_header(conn, "x-stride-event") == ["task.moved"]
      assert Plug.Conn.get_req_header(conn, "x-stride-delivery") == ["dlv-1"]
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

      [signature] = Plug.Conn.get_req_header(conn, "x-stride-signature")
      {:ok, secret} = Webhooks.signing_secret(ctx.endpoint)
      assert Signer.verify(signature, body, secret) == :ok

      decoded = Jason.decode!(body)
      assert Map.keys(decoded) |> Enum.sort() == ~w(board event id occurred_at task version)
      assert decoded["task"]["identifier"] == ctx.task.identifier
      refute body =~ "secret notes"

      assert [%Delivery{status: :succeeded, response_status: 204, attempt: 1} = delivery] =
               deliveries(ctx.endpoint)

      assert delivery.delivered_at
      assert delivery.event == "task.moved"
    end

    test "connects to the address UrlGuard approved, keeping the host header", ctx do
      stub(200)

      perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))

      assert_received {:request, conn, _body}
      assert conn.host == "93.184.216.34"
      assert conn.request_path == "/stride"
      assert Plug.Conn.get_req_header(conn, "host") == ["hooks.example.com"]
    end

    test "a non-2xx records a failed delivery and returns an error so Oban retries", ctx do
      stub(500, "boom")

      assert {:error, {:http_status, 500}} =
               perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload), attempt: 3)

      assert [%Delivery{status: :failed, response_status: 500, attempt: 3, error: error}] =
               deliveries(ctx.endpoint)

      assert error == "HTTP 500: boom"
    end

    test "a redirect is a failure and is not followed", ctx do
      test = self()

      Req.Test.stub(Transport, fn conn ->
        send(test, :requested)

        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, {:http_status, 302}} =
               perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))

      assert_received :requested
      refute_received :requested
      assert [%Delivery{status: :failed, response_status: 302}] = deliveries(ctx.endpoint)
    end

    test "a transport error records the failure and returns an error", ctx do
      Req.Test.stub(Transport, &Req.Test.transport_error(&1, :econnrefused))

      assert {:error, {:transport, :econnrefused}} =
               perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))

      assert [%Delivery{status: :failed, response_status: nil, error: "transport: :econnrefused"}] =
               deliveries(ctx.endpoint)
    end

    test "a response body over 64KB is cut, and invalid UTF-8 and NUL are cleaned", ctx do
      stub(500, String.duplicate("a", 70_000))
      perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))
      [%Delivery{error: long}] = deliveries(ctx.endpoint)
      assert byte_size(long) == byte_size("HTTP 500: ") + Transport.max_body()

      Repo.delete_all(Delivery)
      stub(500, <<"bad", 0xFF, 0, "end">>)
      perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))
      [%Delivery{error: cleaned}] = deliveries(ctx.endpoint)
      assert String.valid?(cleaned)
      refute cleaned =~ <<0>>
      assert cleaned =~ "end"
    end
  end

  describe "UrlGuard runs before every attempt" do
    test "a host that now resolves to a blocked address is recorded and never sent", ctx do
      for host <- ["internal.example.com", "rebind.example.com"] do
        Repo.delete_all(Delivery)
        endpoint = webhook_endpoint_fixture(ctx.board, url: "https://#{host}/hook")
        stub(200)

        assert {:cancel, :blocked_address} =
                 perform_job(DeliveryWorker, args(endpoint, ctx.payload))

        refute_received {:request, _, _}

        assert [%Delivery{status: :failed, error: "blocked_address", response_status: nil}] =
                 deliveries(endpoint)
      end
    end

    test "a host that does not resolve is recorded and retried", ctx do
      endpoint = webhook_endpoint_fixture(ctx.board, url: "https://gone.example.com/hook")

      assert {:error, :unresolvable} = perform_job(DeliveryWorker, args(endpoint, ctx.payload))
      assert [%Delivery{status: :failed, error: "unresolvable"}] = deliveries(endpoint)
    end
  end

  describe "endpoints that cannot receive" do
    test "a deleted endpoint ends the job without sending", ctx do
      stub(200)
      Repo.delete!(ctx.endpoint)

      assert :ok = perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))
      refute_received {:request, _, _}
    end

    test "an endpoint deleted while the request is in flight is logged, not raised", ctx do
      Req.Test.stub(Transport, fn conn ->
        Repo.delete!(ctx.endpoint)
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      log =
        capture_log([level: :warning], fn ->
          assert :ok = perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))
        end)

      assert log =~ "webhook delivery for endpoint #{ctx.endpoint.id} could not be recorded"
      refute log =~ "hooks.example.com"
      assert Repo.aggregate(Delivery, :count) == 0
    end

    test "a disabled endpoint ends the job without sending or recording", ctx do
      stub(200)

      Endpoint
      |> where(id: ^ctx.endpoint.id)
      |> Repo.update_all(set: [enabled: false])

      assert :ok = perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))
      refute_received {:request, _, _}
      assert deliveries(ctx.endpoint) == []
    end

    test "an undecryptable signing secret is recorded and cancelled", ctx do
      stub(200)

      Endpoint
      |> where(id: ^ctx.endpoint.id)
      |> Repo.update_all(set: [encrypted_secret: "not ciphertext"])

      assert {:cancel, :signing_secret_unavailable} =
               perform_job(DeliveryWorker, args(ctx.endpoint, ctx.payload))

      refute_received {:request, _, _}
      assert [%Delivery{error: "signing_secret_unavailable"}] = deliveries(ctx.endpoint)
    end
  end

  describe "a slack endpoint" do
    setup ctx do
      %{slack: webhook_endpoint_fixture(ctx.board, kind: :slack, url: @slack_url)}
    end

    test "posts text and blocks and never the X-Stride headers", ctx do
      stub(200)

      assert :ok = perform_job(DeliveryWorker, args(ctx.slack, ctx.payload))

      assert_received {:request, conn, body}
      assert conn.host == "54.1.2.3"
      assert Plug.Conn.get_req_header(conn, "host") == ["hooks.slack.com"]

      for header <- ~w(x-stride-signature x-stride-event x-stride-delivery) do
        assert Plug.Conn.get_req_header(conn, header) == []
      end

      assert %{"text" => text, "blocks" => [_ | _]} = Jason.decode!(body)
      assert text =~ ctx.task.identifier
      assert text =~ "Ship &lt;it&gt; &amp; more"
      assert [%Delivery{status: :succeeded}] = deliveries(ctx.slack)
    end

    test "a stored URL that is not a Slack incoming webhook is cancelled", ctx do
      stub(200)
      # update_all skips the changeset (and its Slack check) but still
      # encrypts through the field's type.
      Endpoint
      |> where(id: ^ctx.slack.id)
      |> Repo.update_all(set: [url: "https://hooks.example.com/x"])

      assert {:cancel, :not_slack_url} = perform_job(DeliveryWorker, args(ctx.slack, ctx.payload))
      refute_received {:request, _, _}
      assert [%Delivery{error: "not_slack_url"}] = deliveries(ctx.slack)
    end
  end

  test "a ping is delivered", ctx do
    stub(200)
    ping = Payload.ping(ctx.board)

    assert :ok = perform_job(DeliveryWorker, args(ctx.endpoint, ping, "ping"))

    assert_received {:request, conn, body}
    assert Plug.Conn.get_req_header(conn, "x-stride-event") == ["ping"]
    assert %{"event" => "ping", "task" => nil} = Jason.decode!(body)
    assert [%Delivery{event: "ping", status: :succeeded}] = deliveries(ctx.endpoint)
  end

  describe "enqueue" do
    test "enqueue/3 and enqueue_all/3 queue :webhooks jobs with a fresh delivery id each", ctx do
      assert {:ok, %Oban.Job{queue: "webhooks", max_attempts: 8}} =
               DeliveryWorker.enqueue(ctx.endpoint.id, "task.moved", ctx.payload)

      assert :ok =
               DeliveryWorker.enqueue_all(
                 [ctx.endpoint.id, ctx.endpoint.id],
                 "task.moved",
                 ctx.payload
               )

      ids = [worker: DeliveryWorker] |> all_enqueued() |> Enum.map(& &1.args["delivery_id"])
      assert length(ids) == 3
      assert ids == Enum.uniq(ids)
    end
  end

  test "backoff/1 grows exponentially with bounded jitter and is capped at an hour" do
    for attempt <- 1..20 do
      base = min(15 * Integer.pow(2, min(attempt, 8)), 3_600)
      delay = DeliveryWorker.backoff(%Oban.Job{attempt: attempt})

      assert is_integer(delay)
      assert delay >= base
      assert delay <= min(round(base * 1.2) + 1, 3_600)
    end

    assert DeliveryWorker.backoff(%Oban.Job{attempt: 1}) <
             DeliveryWorker.backoff(%Oban.Job{attempt: 5})
  end
end
