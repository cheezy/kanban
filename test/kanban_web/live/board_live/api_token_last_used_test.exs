defmodule KanbanWeb.BoardLive.ApiTokenLastUsedTest do
  @moduledoc """
  The board's API-token list shows each token's last-used time in the
  viewer's timezone and UI language, with an ISO 8601 UTC datetime attribute.
  """
  use KanbanWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures

  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Boards
  alias Kanban.Repo

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, board} = Boards.create_ai_optimized_board(user, %{name: "Local time board"})
    {:ok, {token, _plain}} = ApiTokens.create_api_token(user, board, %{name: "Local time token"})

    from(t in ApiToken, where: t.id == ^token.id)
    |> Repo.update_all(set: [last_used_at: ~U[2026-11-11 04:56:00Z]])

    %{conn: log_in_user(conn, user), board: board}
  end

  test "renders last_used_at in the viewer's timezone", %{conn: conn, board: board} do
    conn = init_test_session(conn, %{"timezone" => "America/Toronto"})
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/api_tokens")

    assert html =~ "November 10, 2026 at 11:56 PM"
    assert html =~ ~s(datetime="2026-11-11T04:56:00Z")
    assert html =~ ~s(title="November 10, 2026 at 11:56 PM EST")
    refute html =~ "2026-11-11 04:56"
  end

  test "renders last_used_at in the UI language", %{conn: conn, board: board} do
    conn = init_test_session(conn, %{"timezone" => "America/Toronto", "locale" => "fr"})
    {:ok, _view, html} = live(conn, ~p"/boards/#{board}/api_tokens")

    assert html =~ "10 novembre 2026 à 23:56"
  end
end
