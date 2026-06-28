defmodule KanbanWeb.BoardLive.MembersFormComponentTest do
  use KanbanWeb.ConnCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias KanbanWeb.BoardLive.MembersFormComponent

  defp setup_owner(_) do
    user = user_fixture()
    board = board_fixture(user, %{name: "Members Board"})
    scope = Scope.for_user(user)
    %{user: user, board: board, scope: scope}
  end

  describe "update/2" do
    setup [:setup_owner]

    test "loads the existing board users into board_users assign", %{board: board, scope: scope} do
      assigns = base_assigns(board, scope)
      {:ok, socket} = MembersFormComponent.update(assigns, %Phoenix.LiveView.Socket{})

      # The owner is automatically a board user (added during board creation).
      assert [%{user: %{}, access: :owner}] = socket.assigns.board_users
      assert socket.assigns.search_email == ""
      assert is_nil(socket.assigns.searched_user)
    end

    test "preserves search_email and searched_user when assigns_new is hit twice",
         %{board: board, scope: scope} do
      assigns = base_assigns(board, scope)
      {:ok, socket} = MembersFormComponent.update(assigns, %Phoenix.LiveView.Socket{})

      socket =
        socket
        |> Phoenix.Component.assign(:search_email, "preserved@example.com")
        |> Phoenix.Component.assign(:searched_user, %{
          id: 42,
          name: "Pre",
          email: "preserved@example.com"
        })

      {:ok, socket2} = MembersFormComponent.update(assigns, socket)

      assert socket2.assigns.search_email == "preserved@example.com"
      assert socket2.assigns.searched_user.email == "preserved@example.com"
    end
  end

  describe "render/1" do
    setup [:setup_owner]

    test "renders the search-by-email form", %{board: board, scope: scope} do
      html =
        render_component(
          &MembersFormComponent.render/1,
          render_assigns(board, scope)
        )

      assert html =~ "Add user by email"
      assert html =~ ~s|type="email"|
      assert html =~ "Search"
    end

    test "renders the candidate panel only when @searched_user is set", %{
      board: board,
      scope: scope
    } do
      html_without =
        render_component(
          &MembersFormComponent.render/1,
          render_assigns(board, scope)
        )

      refute html_without =~ "Add as Read Only"
      refute html_without =~ "Add with Edit Access"

      candidate = %{id: 99, name: "Jamie K.", email: "jamie@example.com"}

      html_with =
        render_component(
          &MembersFormComponent.render/1,
          render_assigns(board, scope, %{searched_user: candidate})
        )

      assert html_with =~ "Jamie K."
      assert html_with =~ "jamie@example.com"
      assert html_with =~ "Add as Read Only"
      assert html_with =~ "Add with Edit Access"

      # W1390: the two long-labelled add-user buttons must wrap rather than
      # overflow the modal content box on a narrow phone viewport.
      assert html_with =~ "flex-wrap: wrap"
    end

    test "renders the current users list with the Owner access chip", %{
      board: board,
      scope: scope,
      user: user
    } do
      html =
        render_component(
          &MembersFormComponent.render/1,
          render_assigns(board, scope)
        )

      assert html =~ "Current users"
      assert html =~ user.email
      assert html =~ "Owner"
      # The owner row must not show a Remove button.
      refute html =~ "Remove"
    end

    test "renders a Remove button for non-owner members", %{
      board: board,
      scope: scope,
      user: owner
    } do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)

      html =
        render_component(
          &MembersFormComponent.render/1,
          render_assigns(board, scope)
        )

      assert html =~ member.email
      assert html =~ "Can Edit"
      assert html =~ "Remove"
    end

    test "renders the Read Only access chip for read-only members", %{
      board: board,
      scope: scope,
      user: owner
    } do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :read_only, owner)

      html =
        render_component(
          &MembersFormComponent.render/1,
          render_assigns(board, scope)
        )

      assert html =~ member.email
      assert html =~ "Read Only"
      assert html =~ "Remove"
    end

    test "renders an unrecognized access level with fallback styling and no label", %{
      board: board,
      scope: scope
    } do
      # The chip helpers carry catch-all clauses so a future access level can
      # never crash the members list; an unknown atom renders the row with the
      # fallback colors and an empty label.
      stranger = user_fixture()

      board_users = [
        %{user: stranger, access: :future_access_level}
      ]

      html =
        render_component(
          &MembersFormComponent.render/1,
          render_assigns(board, scope, %{board_users: board_users})
        )

      assert html =~ stranger.email
      refute html =~ "Read Only"
      refute html =~ "Can Edit"
    end

    test "Close link points at @patch", %{board: board, scope: scope} do
      html =
        render_component(
          &MembersFormComponent.render/1,
          render_assigns(board, scope, %{patch: "/boards/#{board.id}"})
        )

      assert html =~ ~s|href="/boards/#{board.id}"|
      assert html =~ "Close"
    end
  end

  describe "handle_event search_user" do
    setup [:setup_owner]

    test "found and addable: assigns searched_user and clears flash",
         %{board: board, scope: scope} do
      candidate = user_fixture()
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        MembersFormComponent.handle_event(
          "search_user",
          %{"email" => candidate.email},
          socket
        )

      assert socket.assigns.searched_user.id == candidate.id
      assert socket.assigns.search_email == candidate.email
    end

    test "trims whitespace from the email", %{board: board, scope: scope} do
      candidate = user_fixture()
      socket = build_update_socket(board, scope)

      padded = "  " <> candidate.email <> "  "

      {:noreply, socket} =
        MembersFormComponent.handle_event("search_user", %{"email" => padded}, socket)

      assert socket.assigns.searched_user.id == candidate.id
    end

    test "unknown email: clears searched_user and flashes an error",
         %{board: board, scope: scope} do
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        MembersFormComponent.handle_event(
          "search_user",
          %{"email" => "nope@example.com"},
          socket
        )

      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.flash["error"] == "Could not find a user with that email address"
    end

    test "self: refuses to add the current user", %{board: board, scope: scope, user: user} do
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        MembersFormComponent.handle_event("search_user", %{"email" => user.email}, socket)

      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.flash["error"] == "You cannot add yourself to the board"
    end

    test "already a member: refuses to add again",
         %{board: board, scope: scope, user: owner} do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        MembersFormComponent.handle_event("search_user", %{"email" => member.email}, socket)

      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.flash["error"] == "User is already added to the board"
    end
  end

  describe "handle_event add_user" do
    setup [:setup_owner]

    test "owner: adds the searched user, refreshes the list, clears state",
         %{board: board, scope: scope} do
      candidate = user_fixture()
      socket = build_update_socket(board, scope)

      socket =
        socket
        |> Phoenix.Component.assign(:searched_user, candidate)
        |> Phoenix.Component.assign(:search_email, candidate.email)

      {:noreply, socket} =
        MembersFormComponent.handle_event("add_user", %{"access" => "modify"}, socket)

      assert socket.assigns.flash["info"] == "User added successfully"
      assert is_nil(socket.assigns.searched_user)
      assert socket.assigns.search_email == ""

      access_list = Enum.map(socket.assigns.board_users, & &1.access)
      assert :modify in access_list
    end

    test "owner: adds the searched user with read_only access",
         %{board: board, scope: scope} do
      candidate = user_fixture()
      socket = build_update_socket(board, scope)

      socket =
        socket
        |> Phoenix.Component.assign(:searched_user, candidate)
        |> Phoenix.Component.assign(:search_email, candidate.email)

      {:noreply, socket} =
        MembersFormComponent.handle_event("add_user", %{"access" => "read_only"}, socket)

      assert socket.assigns.flash["info"] == "User added successfully"

      access_list = Enum.map(socket.assigns.board_users, & &1.access)
      assert :read_only in access_list
    end

    test "boards-context error: flashes failure when add_user_to_board fails",
         %{board: board, scope: scope, user: owner} do
      already_added = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, already_added, :modify, owner)

      # Bypass the search step's duplicate check by stuffing the searched_user
      # assign directly — the add_user handler should still get a duplicate
      # constraint failure from the database and surface a "failed" flash.
      socket = build_update_socket(board, scope)

      socket =
        socket
        |> Phoenix.Component.assign(:searched_user, already_added)
        |> Phoenix.Component.assign(:search_email, already_added.email)

      {:noreply, socket} =
        MembersFormComponent.handle_event("add_user", %{"access" => "modify"}, socket)

      assert socket.assigns.flash["error"] == "Failed to add user to board"
    end

    test "non-owner: refuses to add", %{board: board} do
      stranger = user_fixture()
      stranger_scope = Scope.for_user(stranger)
      socket = build_update_socket(board, stranger_scope)

      candidate = user_fixture()

      socket =
        socket
        |> Phoenix.Component.assign(:searched_user, candidate)
        |> Phoenix.Component.assign(:search_email, candidate.email)

      {:noreply, socket} =
        MembersFormComponent.handle_event("add_user", %{"access" => "modify"}, socket)

      assert socket.assigns.flash["error"] == "Only the board owner can manage board membership"
    end
  end

  describe "handle_event remove_user" do
    setup [:setup_owner]

    test "owner: removes a non-owner member and refreshes the list",
         %{board: board, scope: scope, user: owner} do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        MembersFormComponent.handle_event(
          "remove_user",
          %{"user_id" => Integer.to_string(member.id)},
          socket
        )

      assert socket.assigns.flash["info"] == "User removed successfully"
      assert Enum.all?(socket.assigns.board_users, &(&1.user.id != member.id))
    end

    test "missing user id: flashes a not-found error", %{board: board, scope: scope} do
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        MembersFormComponent.handle_event(
          "remove_user",
          %{"user_id" => "0"},
          socket
        )

      assert socket.assigns.flash["error"] == "User not found"
    end

    test "user exists but is not on the board: flashes failure",
         %{board: board, scope: scope} do
      not_a_member = user_fixture()
      socket = build_update_socket(board, scope)

      {:noreply, socket} =
        MembersFormComponent.handle_event(
          "remove_user",
          %{"user_id" => Integer.to_string(not_a_member.id)},
          socket
        )

      assert socket.assigns.flash["error"] == "Failed to remove user from board"
    end

    test "non-owner: refuses to remove", %{board: board, user: owner} do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)

      stranger = user_fixture()
      stranger_scope = Scope.for_user(stranger)
      socket = build_update_socket(board, stranger_scope)

      {:noreply, socket} =
        MembersFormComponent.handle_event(
          "remove_user",
          %{"user_id" => Integer.to_string(member.id)},
          socket
        )

      assert socket.assigns.flash["error"] == "Only the board owner can manage board membership"
    end
  end

  defp build_update_socket(board, scope) do
    base = %{%Phoenix.LiveView.Socket{} | assigns: %{flash: %{}, __changed__: %{}}}
    assigns = base_assigns(board, scope)
    {:ok, socket} = MembersFormComponent.update(assigns, base)
    socket
  end

  # The map of assigns passed to live_component's update/2.
  defp base_assigns(board, scope) do
    %{
      id: "board-members-#{board.id}",
      board: board,
      current_scope: scope,
      patch: "/boards/#{board.id}"
    }
  end

  # The map of assigns render_component/2 needs after a (logical) update/2 run.
  defp render_assigns(board, scope, overrides \\ %{}) do
    base = %{
      id: "board-members-#{board.id}",
      board: board,
      current_scope: scope,
      scope: scope,
      patch: "/boards/#{board.id}",
      board_users: Boards.list_board_users(board),
      searched_user: nil,
      search_email: "",
      myself: %Phoenix.LiveComponent.CID{cid: 1}
    }

    Map.merge(base, overrides)
  end
end
