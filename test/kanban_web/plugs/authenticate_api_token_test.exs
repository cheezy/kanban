defmodule KanbanWeb.Plugs.AuthenticateApiTokenTest do
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens
  alias KanbanWeb.Plugs.AuthenticateApiToken

  setup do
    user = user_fixture()
    board = board_fixture(user)

    {:ok, {api_token, plain_text_token}} =
      ApiTokens.create_api_token(user, board, %{
        name: "Test Token"
      })

    %{user: user, board: board, api_token: api_token, plain_text_token: plain_text_token}
  end

  describe "call/2" do
    test "authenticates valid Bearer token and assigns current_user and api_token", %{
      conn: conn,
      user: user,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
      assert conn.assigns.api_token.id == api_token.id
    end

    test "returns 401 for missing Authorization header", %{conn: conn} do
      conn = AuthenticateApiToken.call(conn, [])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end

    test "returns 401 for invalid token format", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "InvalidFormat token123")
        |> AuthenticateApiToken.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 for non-existent token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer invalid_token_12345")
        |> AuthenticateApiToken.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "Invalid API token"}
    end

    test "returns the uniform 401 body for a revoked token", %{
      conn: conn,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      {:ok, _revoked} = ApiTokens.revoke_api_token(api_token)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "Invalid API token"}
    end

    test "not_found, revoked, and expired all return an identical 401 body", %{
      conn: base_conn,
      user: user,
      board: board,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      # not_found
      not_found_conn =
        base_conn
        |> put_req_header("authorization", "Bearer does_not_exist")
        |> AuthenticateApiToken.call([])

      # revoked
      {:ok, _} = ApiTokens.revoke_api_token(api_token)

      revoked_conn =
        base_conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      # expired (fresh token pushed past its expiry)
      {:ok, {expired_token, expired_plain}} =
        ApiTokens.create_api_token(user, board, %{name: "Expiring Token"})

      expire_token(expired_token)

      expired_conn =
        base_conn
        |> put_req_header("authorization", "Bearer #{expired_plain}")
        |> AuthenticateApiToken.call([])

      uniform = %{"error" => "Invalid API token"}
      assert json_response(not_found_conn, 401) == uniform
      assert json_response(revoked_conn, 401) == uniform
      assert json_response(expired_conn, 401) == uniform
    end

    test "telemetry still carries the distinct reason for each failure mode", %{
      conn: base_conn,
      user: user,
      board: board,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      test_pid = self()
      handler_id = "auth-failed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:kanban, :api, :auth_failed],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:auth_failed, metadata.reason})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      base_conn
      |> put_req_header("authorization", "Bearer does_not_exist")
      |> AuthenticateApiToken.call([])

      assert_receive {:auth_failed, "token_not_found"}

      {:ok, _} = ApiTokens.revoke_api_token(api_token)

      base_conn
      |> put_req_header("authorization", "Bearer #{plain_text_token}")
      |> AuthenticateApiToken.call([])

      assert_receive {:auth_failed, "token_revoked"}

      {:ok, {expired_token, expired_plain}} =
        ApiTokens.create_api_token(user, board, %{name: "Expiring Token"})

      expire_token(expired_token)

      base_conn
      |> put_req_header("authorization", "Bearer #{expired_plain}")
      |> AuthenticateApiToken.call([])

      assert_receive {:auth_failed, "token_expired"}
    end

    # The response must stay the generic invalid-token error rather than report
    # the owner's account state back to the caller.
    test "returns 401 for a valid token whose owner is disabled", %{
      conn: conn,
      user: user,
      plain_text_token: plain_text_token
    } do
      {:ok, _} = Kanban.Accounts.disable_user(user, admin_fixture())

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      assert conn.halted
      assert conn.status == 401
      assert json_response(conn, 401) == %{"error" => "Invalid API token"}
      refute conn.assigns[:current_user]
    end

    test "authenticates again once a disabled owner is re-enabled", %{
      conn: conn,
      user: user,
      plain_text_token: plain_text_token
    } do
      {:ok, disabled} = Kanban.Accounts.disable_user(user, admin_fixture())
      {:ok, _} = Kanban.Accounts.enable_user(disabled)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "updates last_used_at timestamp on successful authentication", %{
      conn: conn,
      api_token: api_token,
      plain_text_token: plain_text_token
    } do
      assert api_token.last_used_at == nil

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{plain_text_token}")
        |> AuthenticateApiToken.call([])

      refute conn.halted

      updated_token = ApiTokens.get_api_token!(api_token.id)
      assert updated_token.last_used_at != nil
    end
  end

  # Pushes a token past its expiry directly in the DB — create_api_token offers
  # no way to backdate expires_at.
  defp expire_token(api_token) do
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    query = from(t in Kanban.ApiTokens.ApiToken, where: t.id == ^api_token.id)
    {1, _} = Kanban.Repo.update_all(query, set: [expires_at: past])

    :ok
  end
end
