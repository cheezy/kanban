defmodule KanbanWeb.UserSocketTest do
  @moduledoc """
  Tests for `KanbanWeb.UserSocket` at `/api/socket` and the single-use
  socket tokens `POST /api/me/socket_token` issues for it (W2765,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.7).
  """
  # async: false - the racing-connect test runs connects in other processes,
  # which share the test's sandbox connection.
  use KanbanWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]
  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Phoenix.ConnTest, only: [build_conn: 0, post: 2, json_response: 2]
  import Plug.Conn, only: [put_req_header: 3]

  alias Kanban.Accounts.User
  alias Kanban.Devices
  alias Kanban.Devices.Nonce
  alias Kanban.Devices.Nonces
  alias Kanban.Repo
  alias KanbanWeb.SocketToken
  alias KanbanWeb.UnsubscribeToken
  alias KanbanWeb.UserSocket

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {device, issued} = device_with_tokens_fixture(scope, %{device_class: :phone})

    %{user: user, scope: scope, device: device, access_token: issued.access_token}
  end

  defp now_unix, do: System.system_time(:second)

  defp socket_token(device, opts \\ []) do
    {token, _expires_at} = SocketToken.sign(device, opts)
    token
  end

  defp socket_token_rows do
    from(n in Nonce, where: n.kind == :socket_token) |> Repo.all()
  end

  defp issue_over_http(access_token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> access_token)
    |> post("/api/me/socket_token")
  end

  describe "connect/3" do
    test "connects with a fresh socket token and assigns the scope", ctx do
      token = socket_token(ctx.device)

      assert {:ok, socket} = connect(UserSocket, %{"token" => token})
      assert socket.assigns.current_scope.user.id == ctx.user.id
      assert socket.assigns.current_device.id == ctx.device.id
      assert socket.id == "device:#{ctx.device.id}"
      refute Map.has_key?(socket.assigns, :current_user)
      refute Map.has_key?(socket.assigns, :api_token)

      # Only the hash of the token id is stored, never the token or the id.
      {:ok, %{token_id: token_id}} = SocketToken.verify(token)
      assert [row] = socket_token_rows()
      assert row.device_id == ctx.device.id
      assert row.key_hash == Nonces.socket_token_hash(token_id)
      refute row.key_hash in [token, token_id]
      refute String.contains?(row.key_hash, token_id)
    end

    test "connects with a token 59 seconds old", ctx do
      token = socket_token(ctx.device, signed_at: now_unix() - 59)
      assert {:ok, _socket} = connect(UserSocket, %{"token" => token})
    end

    test "refuses a token after 60 seconds", ctx do
      token = socket_token(ctx.device, signed_at: now_unix() - 61)

      assert SocketToken.verify(token) == {:error, :expired}
      assert connect(UserSocket, %{"token" => token}) == :error
      assert socket_token_rows() == []
    end

    test "refuses a reused token", ctx do
      token = socket_token(ctx.device)

      assert {:ok, _socket} = connect(UserSocket, %{"token" => token})
      assert connect(UserSocket, %{"token" => token}) == :error
      assert length(socket_token_rows()) == 1
    end

    test "refuses a missing token" do
      assert connect(UserSocket, %{}) == :error
      assert connect(UserSocket, %{"token" => ""}) == :error
      assert connect(UserSocket, %{"token" => "not-a-socket-token"}) == :error
      assert connect(UserSocket, %{"token" => ["a", "list"]}) == :error
      assert socket_token_rows() == []
    end

    test "two connects racing with one token: one wins", ctx do
      # The test serialises the two connects on the shared sandbox
      # connection; the guarantee itself is the single
      # INSERT ... ON CONFLICT DO NOTHING on the unique index
      # (Kanban.Devices.Nonces.use_socket_token/3), which lets exactly one of
      # two concurrent inserts in.
      for _round <- 1..5 do
        token = socket_token(ctx.device)
        unconnected = socket(UserSocket)
        parent = self()

        tasks =
          for _ <- 1..2 do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> UserSocket.connect(%{"token" => token}, unconnected, %{})
              end
            end)
          end

        pids =
          for _ <- 1..2 do
            assert_receive {:ready, pid}
            pid
          end

        Enum.each(pids, &send(&1, :go))
        results = Task.await_many(tasks)

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &(&1 == :error)) == 1
      end

      assert length(socket_token_rows()) == 5
    end

    test "revoking the device disconnects its socket", ctx do
      assert {:ok, socket} = connect(UserSocket, %{"token" => socket_token(ctx.device)})
      topic = UserSocket.id(socket)
      assert topic == Devices.device_topic(ctx.device.id)

      # ChannelTest.connect subscribes this process to the socket's id, as
      # the transport does; revoking the device broadcasts its disconnect.
      {:ok, _revoked} = Devices.revoke_device(ctx.scope, ctx.device)

      assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"} = message
      assert {:stop, {:shutdown, :disconnected}, :state} = UserSocket.handle_info(message, :state)
    end

    test "refuses a token issued before the device was revoked", ctx do
      token = socket_token(ctx.device)
      {:ok, _revoked} = Devices.revoke_device(ctx.scope, ctx.device)

      assert connect(UserSocket, %{"token" => token}) == :error
      assert socket_token_rows() == []
    end

    test "refuses a token of a disabled user", ctx do
      token = socket_token(ctx.device)

      from(u in User, where: u.id == ^ctx.user.id)
      |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

      assert connect(UserSocket, %{"token" => token}) == :error
    end

    test "refuses a token naming another user's device", ctx do
      other = user_scope_fixture(user_fixture())
      other_device = device_fixture(other, %{device_class: :phone})
      forged = %{other_device | user_id: ctx.user.id}

      assert connect(UserSocket, %{"token" => socket_token(forged)}) == :error
    end

    test "refuses a device access token, and other signed tokens", ctx do
      assert connect(UserSocket, %{"token" => ctx.access_token}) == :error

      unsubscribe = UnsubscribeToken.sign(ctx.user.id, :task_completed)
      assert connect(UserSocket, %{"token" => unsubscribe}) == :error

      tampered = socket_token(ctx.device) <> "x"
      assert connect(UserSocket, %{"token" => tampered}) == :error
      assert socket_token_rows() == []
    end

    test "keeps the token out of the logs" do
      assert Phoenix.Logger.filter_values(%{"token" => "a-socket-token"}) == %{
               "token" => "[FILTERED]"
             }
    end
  end

  describe "POST /api/me/socket_token" do
    test "the socket_token response matches the schema", ctx do
      spec = "priv/openapi/stride-api.json" |> File.read!() |> Jason.decode!()

      body = ctx.access_token |> issue_over_http() |> json_response(201)

      assert_schema(spec, body, "MeSocketTokenResponse")
      assert_schema(spec, body["data"], "MeSocketToken")
      assert body["data"]["expires_in"] == 60

      {:ok, expires_at, 0} = DateTime.from_iso8601(body["data"]["expires_at"])
      assert_in_delta DateTime.to_unix(expires_at), now_unix() + 60, 2

      assert {:ok, socket} = connect(UserSocket, %{"token" => body["data"]["token"]})
      assert socket.assigns.current_device.id == ctx.device.id
    end
  end

  defp assert_schema(spec, value, schema) do
    properties = get_in(spec, ["components", "schemas", schema, "properties"])

    assert value |> Map.keys() |> MapSet.new() == properties |> Map.keys() |> MapSet.new(),
           "#{schema} does not match the rendered keys"

    for {key, rendered} <- value do
      assert type_allowed?(rendered, properties[key]),
             "#{schema}.#{key} is #{inspect(rendered)}, not #{inspect(properties[key])}"
    end
  end

  # A property with a $ref is checked by its own schema.
  defp type_allowed?(_value, %{"$ref" => _}), do: true

  defp type_allowed?(value, %{"type" => types} = property) do
    types |> List.wrap() |> Enum.any?(&json_type?(value, &1)) and
      (not Map.has_key?(property, "enum") or value in property["enum"])
  end

  defp json_type?(nil, "null"), do: true
  defp json_type?(value, "string"), do: is_binary(value)
  defp json_type?(value, "integer"), do: is_integer(value)
  defp json_type?(value, "object"), do: is_map(value)
  defp json_type?(_value, _type), do: false
end
