defmodule KanbanWeb.BoardLive.ApiTokensTest do
  @moduledoc """
  Unit tests for the extracted API-token lifecycle handlers (W1447). The full
  LiveView flows (access gating, tab visibility) remain covered by show_test.exs;
  these pin the plaintext-shown-once assign and the revoke handler's behavior
  (including the previously-uncovered already-revoked case) directly.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias KanbanWeb.BoardLive.ApiTokens

  @create_params %{
    "api_token" => %{
      "name" => "Test Token",
      "agent_model" => "claude-3-opus",
      "agent_version" => "v1.0",
      "agent_purpose" => "Task automation"
    }
  }

  @attrs %{
    name: "Test Token",
    agent_model: "claude-3-opus",
    agent_version: "v1.0",
    agent_purpose: "Task automation"
  }

  defp socket(assigns) do
    base = %{__changed__: %{}, flash: %{}}
    %{%Phoenix.LiveView.Socket{} | assigns: Map.merge(base, assigns)}
  end

  setup do
    user = user_fixture()
    board = ai_optimized_board_fixture(user)
    %{user: user, board: board}
  end

  describe "do_create_token/2" do
    test "assigns the created token once, wrapped so inspect hides it", %{
      user: user,
      board: board
    } do
      s = socket(%{current_scope: %{user: user}, board: board})

      {:noreply, s} = ApiTokens.do_create_token(s, @create_params)

      assert %KanbanWeb.ShownSecret{value: plain} = s.assigns.new_token
      assert is_binary(plain) and plain != ""
      refute inspect(s.assigns) =~ plain
      assert [_one] = s.assigns.api_tokens

      shown = s.assigns.new_token
      {:noreply, s} = ApiTokens.do_create_token(s, %{"api_token" => nil})
      assert s.assigns.new_token == shown
      assert [_one] = Kanban.ApiTokens.list_api_tokens(board)

      fresh = socket(%{current_scope: %{user: user}, board: board, new_token: nil})
      assert {:noreply, %{assigns: %{new_token: nil}}} = ApiTokens.do_create_token(fresh, %{})
    end
  end

  describe "malformed token params (D449)" do
    test "a map-valued name is dropped before the changeset", %{user: user, board: board} do
      s = socket(%{current_scope: %{user: user}, board: board})
      params = %{"api_token" => Map.put(@create_params["api_token"], "name", %{"a" => 1})}

      {:noreply, s} = ApiTokens.do_create_token(s, params)

      assert %{errors: [name: {"can't be blank", _}]} = s.assigns.token_form.source
      refute Map.has_key?(s.assigns.token_form.params, "name")
      assert Kanban.ApiTokens.list_api_tokens(board) == []
    end
  end

  describe "do_revoke_token/2" do
    test "revokes a token and flashes success", %{user: user, board: board} do
      {:ok, {token, _plain}} = Kanban.ApiTokens.create_api_token(user, board, @attrs)
      s = socket(%{board: board})

      {:noreply, s} = ApiTokens.do_revoke_token(s, token.id)

      assert s.assigns.flash["info"] == "API token revoked successfully"
    end

    test "revoking an already-revoked token stays robust (idempotent handler)", %{
      user: user,
      board: board
    } do
      {:ok, {token, _plain}} = Kanban.ApiTokens.create_api_token(user, board, @attrs)
      {:ok, _} = Kanban.ApiTokens.revoke_api_token(token)

      s = socket(%{board: board})

      assert {:noreply, revoked} = ApiTokens.do_revoke_token(s, token.id)
      assert revoked.assigns.flash["info"] == "API token revoked successfully"
    end

    test "rejects revoking a token from a different board", %{board: board} do
      other_user = user_fixture()
      other_board = ai_optimized_board_fixture(other_user)

      {:ok, {foreign_token, _plain}} =
        Kanban.ApiTokens.create_api_token(other_user, other_board, @attrs)

      s = socket(%{board: board})

      {:noreply, s} = ApiTokens.do_revoke_token(s, foreign_token.id)

      assert s.assigns.flash["error"] == "Unauthorized"
    end
  end
end
