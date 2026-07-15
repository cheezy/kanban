defmodule KanbanWeb.Plugs.AuthenticateApiTokenTest do
  use KanbanWeb.ConnCase

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

    test "returns 401 for revoked token", %{
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
      assert json_response(conn, 401) == %{"error" => "API token has been revoked"}
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
end
