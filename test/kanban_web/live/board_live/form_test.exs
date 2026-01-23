defmodule KanbanWeb.BoardLive.FormTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.AccountsFixtures

  describe "BoardLive.Form (new)" do
    setup :register_and_log_in_user

    test "displays new board form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/boards/new")

      assert html =~ "New Board"
      assert html =~ "Name"
      assert html =~ "Description"
    end

    test "creates new board with valid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/boards/new")

      form =
        form(lv, "#board-form", board: %{name: "Test Board", description: "Test description"})

      assert {:ok, _, html} = form |> render_submit() |> follow_redirect(conn)

      assert html =~ "Board created successfully"
    end

    test "validates required name field", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/boards/new")

      form = form(lv, "#board-form", board: %{name: "", description: "Test"})
      render_submit(form)

      assert render(lv) =~ "can&#39;t be blank"
    end
  end

  describe "BoardLive.Form (edit)" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = board_fixture(user)
      %{board: board}
    end

    test "displays edit board form for owner", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "Edit Board"
      assert html =~ board.name
      assert html =~ "Field Visibility Settings"
      assert html =~ "Manage Users"
    end

    test "non-owner cannot access edit board page", %{conn: conn, board: board} do
      # Create another user who is not on the board
      other_user = user_fixture()

      # Add them to the board with read-only access
      Kanban.Boards.add_user_to_board(board, other_user, :read_only)

      # Login as the other user
      conn = log_in_user(conn, other_user)

      # Try to access the edit page - should redirect
      assert {:error, {:live_redirect, %{to: "/boards", flash: %{"error" => error}}}} =
               live(conn, ~p"/boards/#{board}/edit")

      assert error =~ "Only the board owner can edit this board"
    end

    test "updates board with valid data", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      form =
        form(lv, "#board-form",
          board: %{name: "Updated Name", description: "Updated description"}
        )

      assert {:ok, _, html} = form |> render_submit() |> follow_redirect(conn)

      assert html =~ "Board updated successfully"
    end

    test "displays field visibility checkboxes", %{conn: conn, board: board} do
      {:ok, _lv, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "Acceptance Criteria"
      assert html =~ "Complexity &amp; Scope"
      assert html =~ "Context (Why/What/Where)"
      assert html =~ "Key Files"
      assert html =~ "Verification Steps"
      assert html =~ "Technical Notes"
      assert html =~ "Observability"
      assert html =~ "Error Handling"
      assert html =~ "Technology Requirements"
      assert html =~ "Pitfalls"
      assert html =~ "Out of Scope"
      assert html =~ "Required Agent Capabilities"
    end

    test "toggles field visibility", %{conn: conn, board: board, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      # Toggle complexity field visibility
      lv |> element("input[phx-value-field='complexity']") |> render_click()

      # Verify the board was updated
      updated_board = Kanban.Boards.get_board!(board.id, user)
      assert updated_board.field_visibility["complexity"] == true
    end

    test "displays current board users", %{conn: conn, board: board, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "Current Users"
      assert html =~ user.email
      assert html =~ "Owner"
    end

    test "searches for user by email", %{conn: conn, board: board} do
      other_user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      lv
      |> form("form[phx-submit='search_user']", %{email: other_user.email})
      |> render_submit()

      assert render(lv) =~ other_user.email
      assert render(lv) =~ "Add as Read Only"
      assert render(lv) =~ "Add with Edit Access"
    end

    test "shows error when user not found", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      lv
      |> form("form[phx-submit='search_user']", %{email: "nonexistent@example.com"})
      |> render_submit()

      assert render(lv) =~ "User not found with email"
    end

    test "prevents adding yourself to board", %{conn: conn, board: board, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      lv
      |> form("form[phx-submit='search_user']", %{email: user.email})
      |> render_submit()

      assert render(lv) =~ "You cannot add yourself to the board"
    end

    test "adds user with read-only access", %{conn: conn, board: board} do
      other_user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      # Search for user
      lv
      |> form("form[phx-submit='search_user']", %{email: other_user.email})
      |> render_submit()

      # Add user as read-only
      lv |> element("button", "Add as Read Only") |> render_click()

      assert render(lv) =~ "User added successfully"
      assert render(lv) =~ other_user.email
      assert render(lv) =~ "Read Only"
    end

    test "adds user with modify access", %{conn: conn, board: board} do
      other_user = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      # Search for user
      lv
      |> form("form[phx-submit='search_user']", %{email: other_user.email})
      |> render_submit()

      # Add user with edit access
      lv |> element("button", "Add with Edit Access") |> render_click()

      assert render(lv) =~ "User added successfully"
      assert render(lv) =~ other_user.email
      assert render(lv) =~ "Can Edit"
    end

    test "removes user from board", %{conn: conn, board: board} do
      other_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, other_user, :read_only)

      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      lv |> element("button[phx-value-user_id='#{other_user.id}']", "Remove") |> render_click()

      assert render(lv) =~ "User removed successfully"
      refute render(lv) =~ other_user.email
    end

    test "prevents adding duplicate user", %{conn: conn, board: board} do
      other_user = user_fixture()
      Kanban.Boards.add_user_to_board(board, other_user, :read_only)

      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      lv
      |> form("form[phx-submit='search_user']", %{email: other_user.email})
      |> render_submit()

      assert render(lv) =~ "User is already added to the board"
    end

    test "does not show remove button for board owner", %{conn: conn, board: board, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ user.email
      assert html =~ "Owner"
      # The remove button should not appear for the owner
      refute html =~ ~r/phx-value-user_id="#{user.id}".*Remove/
    end

    test "validates board form with invalid data", %{conn: conn, board: board} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      form = form(lv, "#board-form", board: %{name: ""})
      render_submit(form)

      assert render(lv) =~ "can&#39;t be blank"
    end

    test "creates board and validates invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/boards/new")

      form = form(lv, "#board-form", board: %{name: "abc"})
      render_submit(form)

      assert render(lv) =~ "should be at least 5 character(s)"
    end

    test "new board form does not display read-only checkbox", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/boards/new")

      refute html =~ "Make board publicly readable"
      refute html =~ "anyone with the direct link can view this board"
    end
  end

  describe "BoardLive.Form (read-only toggle)" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = board_fixture(user)
      %{board: board}
    end

    test "edit form displays read-only checkbox", %{conn: conn, board: board} do
      {:ok, _view, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "Make board publicly readable"
      assert html =~ "anyone with the direct link can view this board"
    end

    test "read-only checkbox is unchecked by default", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}/edit")

      # The checkbox should exist but not be checked
      assert view |> has_element?("input[name='board[read_only]'][type='checkbox']")
      refute view |> has_element?("input[name='board[read_only]'][checked]")
    end

    test "can toggle read-only on via form submission", %{conn: conn, board: board, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      form =
        form(lv, "#board-form",
          board: %{name: board.name, description: board.description, read_only: true}
        )

      assert {:ok, _, html} = form |> render_submit() |> follow_redirect(conn)

      assert html =~ "Board updated successfully"

      # Verify the board was updated
      updated_board = Kanban.Boards.get_board!(board.id, user)
      assert updated_board.read_only == true
    end

    test "can toggle read-only off via form submission", %{conn: conn, user: user} do
      # Create a board with read_only set to true
      {:ok, board} =
        Kanban.Boards.create_board(user, %{
          name: "Public Board",
          description: "Test",
          read_only: true
        })

      {:ok, lv, _html} = live(conn, ~p"/boards/#{board}/edit")

      form =
        form(lv, "#board-form",
          board: %{name: board.name, description: board.description, read_only: false}
        )

      assert {:ok, _, html} = form |> render_submit() |> follow_redirect(conn)

      assert html =~ "Board updated successfully"

      # Verify the board was updated
      updated_board = Kanban.Boards.get_board!(board.id, user)
      assert updated_board.read_only == false
    end
  end
end
