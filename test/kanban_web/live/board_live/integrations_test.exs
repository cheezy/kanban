defmodule KanbanWeb.BoardLive.IntegrationsTest do
  @moduledoc """
  Unit tests for the Integrations route gate (W2228). The full flows are in
  integrations_component_test.exs.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias KanbanWeb.BoardLive.Integrations

  defp socket(assigns) do
    base = %{__changed__: %{}, flash: %{}}
    %{%Phoenix.LiveView.Socket{} | assigns: Map.merge(base, assigns)}
  end

  test "resolve_integrations_view/3 sends anyone but the owner back to the board" do
    board = board_fixture(user_fixture())

    for access <- [:modify, :read_only, nil] do
      assert {:noreply, socket} =
               %{} |> socket() |> Integrations.resolve_integrations_view(board, access)

      assert socket.redirected == {:live, :patch, %{kind: :push, to: "/boards/#{board.id}"}}
      assert socket.assigns.flash["error"] == "Only the board owner can manage integrations"
    end
  end

  describe "track_opening/3" do
    defp track(id, assigns) do
      assert {:cont, socket} =
               Integrations.track_opening(%{"id" => id}, "/", socket(assigns))

      socket.assigns.integrations_opening
    end

    test "opening the view from another view makes a new opening every time" do
      closed = %{live_action: :integrations, integrations_opening: nil}

      assert {"7", first} = track("7", closed)
      assert {"7", second} = track("7", closed)
      assert is_reference(first)
      refute first == second
    end

    test "a patch that stays on the open view keeps its opening" do
      opening = {"7", make_ref()}

      assert track("7", %{live_action: :integrations, integrations_opening: opening}) == opening
    end

    test "another board's view is a new opening" do
      opening = {"7", make_ref()}

      assert {"8", ref} =
               track("8", %{live_action: :integrations, integrations_opening: opening})

      refute ref == elem(opening, 1)
    end

    test "any other view ends the opening" do
      for action <- [:show, :api_tokens, :new_goal] do
        assert track("7", %{live_action: action, integrations_opening: {"7", make_ref()}}) == nil
      end
    end
  end

  describe "end_opening/1" do
    test "an open view gets a new opening" do
      opening = {"7", make_ref()}
      socket = %{integrations_opening: opening} |> socket() |> Integrations.end_opening()

      assert {"7", ref} = socket.assigns.integrations_opening
      refute ref == elem(opening, 1)
    end

    test "a closed view stays closed, and a page without the view is left alone" do
      closed = socket(%{integrations_opening: nil})
      other_page = socket(%{})

      assert Integrations.end_opening(closed) == closed
      assert Integrations.end_opening(other_page) == other_page
    end
  end
end
