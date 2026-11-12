defmodule KanbanWeb.UserAuth.ReplacedSessionWorkerTest do
  use KanbanWeb.ConnCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Kanban.AccountsFixtures

  alias Kanban.Accounts
  alias KanbanWeb.UserAuth
  alias KanbanWeb.UserAuth.ReplacedSessionWorker

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, KanbanWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    user = user_fixture()
    token = Accounts.generate_user_session_token(user)
    offset_user_token(token, -10, :day)
    %{conn: conn, user: user, token: token}
  end

  test "a reissue schedules the replaced token's revocation five minutes before its grace hour ends",
       %{
         conn: conn,
         token: token
       } do
    conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

    assert [%{args: %{"token_id" => _id}, scheduled_at: at}] =
             all_enqueued(worker: ReplacedSessionWorker)

    assert DateTime.diff(at, DateTime.utc_now(), :second) in 3290..3300
  end

  test "a replay handed an existing successor schedules nothing more", %{conn: conn, token: token} do
    conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])
    conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

    assert length(all_enqueued(worker: ReplacedSessionWorker)) == 1
  end

  test "at the end of the grace hour the replaced token is deleted and its pages disconnected",
       %{conn: conn, token: token} do
    reissued =
      conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])

    successor = get_session(reissued, :user_token)
    [%{args: args}] = all_enqueued(worker: ReplacedSessionWorker)
    KanbanWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(token)}")

    assert :ok = perform_job(ReplacedSessionWorker, args)

    refute Accounts.get_user_by_session_token(token)
    assert Accounts.get_user_by_session_token(successor)
    assert_received %Phoenix.Socket.Broadcast{event: "disconnect"}
  end

  test "does nothing when the replaced token was already revoked", %{conn: conn, token: token} do
    conn |> put_session(:user_token, token) |> UserAuth.fetch_current_scope_for_user([])
    [%{args: args}] = all_enqueued(worker: ReplacedSessionWorker)
    Accounts.delete_user_session_token(token)
    KanbanWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(token)}")

    assert :ok = perform_job(ReplacedSessionWorker, args)
    refute_received %Phoenix.Socket.Broadcast{event: "disconnect"}
  end
end
