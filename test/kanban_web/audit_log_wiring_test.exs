defmodule KanbanWeb.AuditLogWiringTest do
  @moduledoc """
  Verifies the security audit events fire through the real code paths. Telemetry
  handlers are global, so this module is async: false and each assertion filters
  by a value unique to its own fixture to avoid cross-test bleed.
  """
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.ApiTokens

  defp attach(action) do
    test_pid = self()
    event = [:kanban, :audit, action]
    handler_id = "audit-wiring-#{action}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn ^event, _measurements, metadata, _config ->
        send(test_pid, {:audit, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "an invalid-credentials login emits :login_failed", %{conn: conn} do
    attach(:login_failed)
    email = unique_user_email()

    post(conn, ~p"/users/log-in", %{"user" => %{"email" => email, "password" => "wrong"}})

    assert_receive {:audit, %{email: ^email}}
  end

  test "creating an API token emits :api_token_created" do
    attach(:api_token_created)
    user = user_fixture()
    board = board_fixture(user)

    {:ok, {token, _plain}} = ApiTokens.create_api_token(user, board, %{name: "Audit"})

    assert_receive {:audit, %{token_id: token_id}}
    assert token_id == token.id
  end

  test "revoking an API token emits :api_token_revoked" do
    attach(:api_token_revoked)
    user = user_fixture()
    board = board_fixture(user)
    {:ok, {token, _plain}} = ApiTokens.create_api_token(user, board, %{name: "Audit"})

    {:ok, _} = ApiTokens.revoke_api_token(token)

    assert_receive {:audit, %{token_id: token_id}}
    assert token_id == token.id
  end

  test "an invalid Bearer token emits :api_token_auth_failed", %{conn: conn} do
    attach(:api_token_auth_failed)

    conn
    |> put_req_header("authorization", "Bearer definitely-not-a-real-token")
    |> get(~p"/api/tasks/next")

    assert_receive {:audit, %{reason: :not_found}}
  end
end
