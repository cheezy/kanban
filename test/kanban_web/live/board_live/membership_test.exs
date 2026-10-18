defmodule KanbanWeb.BoardLive.MembershipTest do
  @moduledoc """
  Direct unit tests for the shared membership flows extracted in W1082.
  The full LiveView/LiveComponent behavior remains covered by
  form_test.exs and members_form_component_test.exs; these tests pin the
  shared functions themselves using the minimal-socket pattern those
  files established.

  async: false (the ConnCase default) is required: the member-cap tests switch
  the global :plans_enforced application env via Kanban.PlansHelpers.
  """
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.PlansHelpers

  alias Kanban.Boards
  alias KanbanWeb.BoardLive.Membership

  defp setup_board(_) do
    owner = user_fixture()
    board = board_fixture(owner, %{name: "Membership Board"})
    %{owner: owner, board: board}
  end

  defp build_socket(board) do
    base = %{%Phoenix.LiveView.Socket{} | assigns: %{flash: %{}, __changed__: %{}}}

    base
    |> Phoenix.Component.assign(:board, board)
    |> Phoenix.Component.assign(:board_users, Boards.list_board_users(board))
    |> Phoenix.Component.assign(:searched_user, nil)
    |> Phoenix.Component.assign(:search_email, "")
  end

  describe "search_user/3" do
    setup [:setup_board]

    test "stages a found user and clears the flash", %{owner: owner, board: board} do
      other = user_fixture()
      socket = build_socket(board)

      {:noreply, socket} = Membership.search_user(socket, owner, " #{other.email} ")

      assert socket.assigns.searched_user.id == other.id
      assert socket.assigns.search_email == other.email
    end

    test "non-owner is denied and cannot enumerate accounts (W1434)", %{board: board} do
      stranger = user_fixture()
      target = user_fixture()
      socket = build_socket(board)

      {:noreply, socket} = Membership.search_user(socket, stranger, target.email)

      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.flash["error"] == "Only the board owner can manage board membership"
    end

    test "read-only board member is denied (W1434)", %{owner: owner, board: board} do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
      target = user_fixture()
      socket = build_socket(board)

      {:noreply, socket} = Membership.search_user(socket, reader, target.email)

      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.flash["error"] == "Only the board owner can manage board membership"
    end

    test "flashes an error when no user matches", %{owner: owner, board: board} do
      socket = build_socket(board)

      {:noreply, socket} = Membership.search_user(socket, owner, "nobody@example.com")

      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.flash["error"] == "Could not find a user with that email address"
    end

    test "rejects adding yourself", %{owner: owner, board: board} do
      socket = build_socket(board)

      {:noreply, socket} = Membership.search_user(socket, owner, owner.email)

      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.flash["error"] == "You cannot add yourself to the board"
    end

    test "rejects a user who is already a member", %{owner: owner, board: board} do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :read_only, owner)
      socket = build_socket(board)

      {:noreply, socket} = Membership.search_user(socket, owner, member.email)

      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.flash["error"] == "User is already added to the board"
    end
  end

  describe "add_user/3" do
    setup [:setup_board]

    test "owner adds the staged user and resets the search state",
         %{owner: owner, board: board} do
      other = user_fixture()

      socket =
        board
        |> build_socket()
        |> Phoenix.Component.assign(:searched_user, other)

      {:noreply, socket} = Membership.add_user(socket, owner, "read_only")

      assert Enum.any?(socket.assigns.board_users, fn %{user: u} -> u.id == other.id end)
      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.search_email == ""
      assert socket.assigns.flash["info"] == "User added successfully"
    end

    test "non-owner is denied", %{board: board} do
      stranger = user_fixture()

      socket =
        board
        |> build_socket()
        |> Phoenix.Component.assign(:searched_user, user_fixture())

      {:noreply, socket} = Membership.add_user(socket, stranger, "read_only")

      assert socket.assigns.flash["error"] ==
               "Only the board owner can manage board membership"
    end
  end

  describe "remove_user/3" do
    setup [:setup_board]

    test "owner removes a member", %{owner: owner, board: board} do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :read_only, owner)
      socket = build_socket(board)

      {:noreply, socket} = Membership.remove_user(socket, owner, Integer.to_string(member.id))

      refute Enum.any?(socket.assigns.board_users, fn %{user: u} -> u.id == member.id end)
      assert socket.assigns.flash["info"] == "User removed successfully"
    end

    test "unknown user id flashes user not found", %{owner: owner, board: board} do
      socket = build_socket(board)

      {:noreply, socket} = Membership.remove_user(socket, owner, "999999999")

      assert socket.assigns.flash["error"] == "User not found"
    end

    test "non-owner is denied", %{owner: owner, board: board} do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :read_only, owner)
      socket = build_socket(board)

      {:noreply, socket} =
        Membership.remove_user(socket, user_fixture(), Integer.to_string(member.id))

      assert socket.assigns.flash["error"] ==
               "Only the board owner can manage board membership"
    end
  end

  describe "member cap helpers (W2401)" do
    test "member_cap_line/1 shows the count under, at and over the cap" do
      assert Membership.member_cap_line(%{count: 2, cap: 3, reached?: false}) ==
               "2 of 3 people"

      assert Membership.member_cap_line(%{count: 3, cap: 3, reached?: true}) == "3 of 3 people"
      assert Membership.member_cap_line(%{count: 5, cap: 3, reached?: true}) == "5 of 3 people"
    end

    test "member_cap_line/1 is nil for an uncapped board" do
      assert is_nil(Membership.member_cap_line(%{count: 7, cap: nil, reached?: false}))
    end

    test "member_cap_explanation/1 is nil under the cap and explains at or over it" do
      assert is_nil(Membership.member_cap_explanation(%{count: 2, cap: 3, reached?: false}))

      for count <- [3, 5] do
        assert Membership.member_cap_explanation(%{count: count, cap: 3, reached?: true}) ==
                 "Free boards hold 3 people. To add more, move this board to a paid plan."
      end

      assert is_nil(Membership.member_cap_explanation(%{count: 7, cap: nil, reached?: false}))
    end

    test "member_cap_flash/1 names the cap, and falls back when the board has none" do
      assert Membership.member_cap_flash(%{count: 3, cap: 3, reached?: true}) ==
               "This board is full. Free boards hold 3 people."

      assert Membership.member_cap_flash(%{count: 3, cap: nil, reached?: false}) ==
               "This board is full."
    end
  end

  describe "member cap assigns (W2401)" do
    setup [:setup_board]

    test "assign_member_cap/1 stores the board's cap status", %{owner: owner, board: board} do
      {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :modify, owner)

      socket = board |> build_socket() |> Membership.assign_member_cap()
      assert socket.assigns.member_cap == %{count: 2, cap: nil, reached?: false}

      enforce_plans()

      socket = board |> build_socket() |> Membership.assign_member_cap()
      assert socket.assigns.member_cap == %{count: 2, cap: 3, reached?: false}
    end

    test "add_user/3 at the cap flashes the cap message, not the generic failure",
         %{owner: owner, board: board} do
      for _ <- 1..2,
          do: {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :modify, owner)

      enforce_plans()
      candidate = user_fixture()

      socket =
        board
        |> build_socket()
        |> Phoenix.Component.assign(:searched_user, candidate)

      {:noreply, socket} = Membership.add_user(socket, owner, "modify")

      assert socket.assigns.flash["error"] == "This board is full. Free boards hold 3 people."
      assert socket.assigns.member_cap == %{count: 3, cap: 3, reached?: true}
      refute Enum.any?(socket.assigns.board_users, fn %{user: u} -> u.id == candidate.id end)
    end
  end
end
