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
end
