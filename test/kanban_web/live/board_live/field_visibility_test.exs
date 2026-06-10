defmodule KanbanWeb.BoardLive.FieldVisibilityTest do
  @moduledoc """
  Direct unit tests for the shared field-visibility toggle flow extracted
  in W1082, including the W401 allow-list guard and the on_success
  callback that lets LiveComponent callers notify their parent.
  """
  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Boards.Board
  alias KanbanWeb.BoardLive.FieldVisibility

  defp setup_board(_) do
    owner = user_fixture()
    board = board_fixture(owner, %{name: "Toggles Board"})
    %{owner: owner, board: board}
  end

  defp build_socket(board) do
    base = %{%Phoenix.LiveView.Socket{} | assigns: %{flash: %{}, __changed__: %{}}}

    base
    |> Phoenix.Component.assign(:board, board)
    |> Phoenix.Component.assign(:field_visibility, board.field_visibility || %{})
  end

  describe "toggle_field/4" do
    setup [:setup_board]

    test "rejects a field name not on the allow-list (W401)", %{owner: owner, board: board} do
      socket = build_socket(board)
      before_visibility = socket.assigns.field_visibility

      {:noreply, socket} = FieldVisibility.toggle_field(socket, owner, "not_a_real_field")

      assert socket.assigns.field_visibility == before_visibility
      assert socket.assigns.flash["error"] == "Invalid field name"
    end

    test "owner toggles an allow-listed field and the callback fires with the new map",
         %{owner: owner, board: board} do
      field = hd(Board.toggleable_fields())
      socket = build_socket(board)
      before_value = Map.get(socket.assigns.field_visibility, field, false)
      test_pid = self()

      {:noreply, socket} =
        FieldVisibility.toggle_field(socket, owner, field, fn visibility ->
          send(test_pid, {:toggled, visibility})
        end)

      assert socket.assigns.field_visibility[field] == not before_value
      assert_received {:toggled, visibility}
      assert visibility[field] == not before_value
    end

    test "default arity works without a callback", %{owner: owner, board: board} do
      field = hd(Board.toggleable_fields())
      socket = build_socket(board)
      before_value = Map.get(socket.assigns.field_visibility, field, false)

      {:noreply, socket} = FieldVisibility.toggle_field(socket, owner, field)

      assert socket.assigns.field_visibility[field] == not before_value
    end

    test "toggling twice restores the original value", %{owner: owner, board: board} do
      field = hd(Board.toggleable_fields())
      socket = build_socket(board)
      before_value = Map.get(socket.assigns.field_visibility, field, false)

      {:noreply, socket} = FieldVisibility.toggle_field(socket, owner, field)
      {:noreply, socket} = FieldVisibility.toggle_field(socket, owner, field)

      assert socket.assigns.field_visibility[field] == before_value
    end

    test "non-owner is denied and the callback does not fire", %{board: board} do
      field = hd(Board.toggleable_fields())
      socket = build_socket(board)
      test_pid = self()

      {:noreply, socket} =
        FieldVisibility.toggle_field(socket, user_fixture(), field, fn visibility ->
          send(test_pid, {:toggled, visibility})
        end)

      assert socket.assigns.flash["error"] == "Only board owners can change field visibility"
      refute_received {:toggled, _}
    end
  end
end
