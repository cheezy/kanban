defmodule KanbanWeb.BoardLive.FormTest do
  use KanbanWeb.ConnCase

  import Phoenix.LiveViewTest
  import Kanban.BoardsFixtures
  import Kanban.AccountsFixtures

  @create_attrs %{name: "some name", description: "some description"}
  @update_attrs %{name: "some updated name", description: "some updated description"}
  @invalid_attrs %{name: nil, description: nil}

  describe "New Board" do
    setup [:register_and_log_in_user]

    test "renders new board form", %{conn: conn} do
      {:ok, _form_live, html} = live(conn, ~p"/boards/new")

      assert html =~ "New Board"
      assert html =~ "Use this form to manage board records in your database"
    end

    test "validates board name is required", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/boards/new")

      assert form_live
             |> form("#board-form", board: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"
    end

    test "creates board successfully", %{conn: conn} do
      {:ok, form_live, _html} = live(conn, ~p"/boards/new")

      {:ok, _index_live, html} =
        form_live
        |> form("#board-form", board: @create_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/boards")

      assert html =~ "Board created successfully"
      assert html =~ "some name"
    end

    test "does not show user management section on new board form", %{conn: conn} do
      {:ok, _form_live, html} = live(conn, ~p"/boards/new")

      refute html =~ "Manage Users"
      refute html =~ "Add User by Email"
    end
  end

  describe "Edit Board" do
    setup [:register_and_log_in_user]

    test "renders edit board form", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "Edit Board"
      assert html =~ board.name
    end

    test "validates board name is required when editing", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      assert form_live
             |> form("#board-form", board: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"
    end

    test "updates board successfully", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      {:ok, _index_live, html} =
        form_live
        |> form("#board-form", board: @update_attrs)
        |> render_submit()
        |> follow_redirect(conn, ~p"/boards")

      assert html =~ "Board updated successfully"
      assert html =~ "some updated name"
    end

    test "cannot edit other user's board", %{conn: conn} do
      other_user = user_fixture()
      other_board = board_fixture(other_user)

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/boards/#{other_board}/edit")
      end
    end

    test "shows user management section on edit board form", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "Manage Users"
      assert html =~ "Add User by Email"
      assert html =~ "Current Users"
    end

    test "displays current user as owner in user list", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ user.email
      assert html =~ "Owner"
    end

    test "owner does not have remove button", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "Owner"
      # Owner row should not have a Remove button next to it
      refute has_element?(form_live, "button", "Remove")
    end
  end

  describe "User Search" do
    setup [:register_and_log_in_user]

    test "renders email search input and button", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "Add User by Email"
      assert html =~ "Enter user email"
      assert html =~ "Search"
    end

    test "finds user by email successfully", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      html =
        form_live
        |> form("form[phx-submit='search_user']", email: other_user.email)
        |> render_submit()

      assert html =~ other_user.name
      assert html =~ other_user.email
      assert html =~ "Add as Read Only"
      assert html =~ "Add with Modify Access"
    end

    test "shows error when user not found", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      html =
        form_live
        |> form("form[phx-submit='search_user']", email: "nonexistent@example.com")
        |> render_submit()

      assert html =~ "User not found with email"
      refute html =~ "Add as Read Only"
      refute html =~ "Add with Modify Access"
    end

    test "shows error when trying to add yourself", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      html =
        form_live
        |> form("form[phx-submit='search_user']", email: user.email)
        |> render_submit()

      assert html =~ "You cannot add yourself to the board"
      refute html =~ "Add as Read Only"
    end

    test "shows error when user already added to board", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture()
      {:ok, _} = Kanban.Boards.add_user_to_board(board, other_user, :read_only)

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      html =
        form_live
        |> form("form[phx-submit='search_user']", email: other_user.email)
        |> render_submit()

      assert html =~ "User is already added to the board"
      refute html =~ "Add as Read Only"
    end

    test "trims whitespace from email search", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      html =
        form_live
        |> form("form[phx-submit='search_user']", email: "  #{other_user.email}  ")
        |> render_submit()

      assert html =~ other_user.name
      assert html =~ "Add as Read Only"
    end

    test "clears search results after successful add", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      form_live
      |> form("form[phx-submit='search_user']", email: other_user.email)
      |> render_submit()

      html = form_live |> element("button", "Add as Read Only") |> render_click()

      refute html =~ "Add as Read Only"
      refute html =~ "Add with Modify Access"
      assert html =~ "User added successfully"
    end
  end

  describe "Add User to Board" do
    setup [:register_and_log_in_user]

    test "adds user with read_only access", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      form_live
      |> form("form[phx-submit='search_user']", email: other_user.email)
      |> render_submit()

      html = form_live |> render_click("add_user", %{"access" => "read_only"})

      assert html =~ "User added successfully"
      assert html =~ other_user.name
      assert html =~ "Read Only"
    end

    test "adds user with modify access", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      form_live
      |> form("form[phx-submit='search_user']", email: other_user.email)
      |> render_submit()

      html = form_live |> render_click("add_user", %{"access" => "modify"})

      assert html =~ "User added successfully"
      assert html =~ other_user.name
      assert html =~ "Can Modify"
    end

    test "displays remove button for non-owner users", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      form_live
      |> form("form[phx-submit='search_user']", email: other_user.email)
      |> render_submit()

      form_live |> render_click("add_user", %{"access" => "read_only"})

      assert has_element?(form_live, "button", "Remove")
    end
  end

  describe "Remove User from Board" do
    setup [:register_and_log_in_user]

    test "removes user successfully", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, other_user, :read_only)

      {:ok, form_live, html} = live(conn, ~p"/boards/#{board}/edit")
      assert html =~ other_user.name

      html = form_live |> render_click("remove_user", %{"user_id" => "#{other_user.id}"})

      assert html =~ "User removed successfully"
      refute html =~ other_user.name
    end

    test "shows error when removal fails", %{conn: conn, user: user} do
      board = board_fixture(user)

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      html = form_live |> render_click("remove_user", %{"user_id" => "99999"})

      assert html =~ "User not found"
    end
  end

  describe "User List Sorting" do
    setup [:register_and_log_in_user]

    test "displays users sorted by access level", %{conn: conn, user: user} do
      board = board_fixture(user)

      user1 = user_fixture(%{email: "readonly@example.com", name: "Read User"})
      user2 = user_fixture(%{email: "modify@example.com", name: "Modify User"})
      user3 = user_fixture(%{email: "anotherreadonly@example.com", name: "Another Read User"})

      {:ok, _} = Kanban.Boards.add_user_to_board(board, user1, :read_only)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user2, :modify)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user3, :read_only)

      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      # Verify owner is first, followed by modify users, then read only
      assert html =~ ~r/Owner.*Can Modify.*Read Only/s

      # Verify the specific order by finding positions
      owner_pos = :binary.match(html, user.email) |> elem(0)
      modify_pos = :binary.match(html, "modify@example.com") |> elem(0)
      readonly1_pos = :binary.match(html, "anotherreadonly@example.com") |> elem(0)
      readonly2_pos = :binary.match(html, "readonly@example.com") |> elem(0)

      assert owner_pos < modify_pos
      assert modify_pos < readonly1_pos
      assert modify_pos < readonly2_pos
      # Read only users sorted alphabetically by email
      assert readonly1_pos < readonly2_pos
    end

    test "owner is always listed first", %{conn: conn, user: user} do
      board = board_fixture(user)

      user1 = user_fixture(%{email: "aaa@example.com", name: "AAA User"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user1, :modify)

      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      owner_pos = :binary.match(html, user.email) |> elem(0)
      other_pos = :binary.match(html, "aaa@example.com") |> elem(0)

      assert owner_pos < other_pos
    end

    test "modify users are listed before read_only users", %{conn: conn, user: user} do
      board = board_fixture(user)

      user1 = user_fixture(%{email: "readonly@example.com", name: "Read User"})
      user2 = user_fixture(%{email: "modify@example.com", name: "Modify User"})

      {:ok, _} = Kanban.Boards.add_user_to_board(board, user1, :read_only)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user2, :modify)

      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      modify_pos = :binary.match(html, "modify@example.com") |> elem(0)
      readonly_pos = :binary.match(html, "readonly@example.com") |> elem(0)

      assert modify_pos < readonly_pos
    end

    test "users within same access level sorted alphabetically by email", %{
      conn: conn,
      user: user
    } do
      board = board_fixture(user)

      user1 = user_fixture(%{email: "zzz@example.com", name: "ZZZ User"})
      user2 = user_fixture(%{email: "aaa@example.com", name: "AAA User"})
      user3 = user_fixture(%{email: "mmm@example.com", name: "MMM User"})

      {:ok, _} = Kanban.Boards.add_user_to_board(board, user1, :read_only)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user2, :read_only)
      {:ok, _} = Kanban.Boards.add_user_to_board(board, user3, :read_only)

      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      aaa_pos = :binary.match(html, "aaa@example.com") |> elem(0)
      mmm_pos = :binary.match(html, "mmm@example.com") |> elem(0)
      zzz_pos = :binary.match(html, "zzz@example.com") |> elem(0)

      assert aaa_pos < mmm_pos
      assert mmm_pos < zzz_pos
    end
  end

  describe "Access Level Badges" do
    setup [:register_and_log_in_user]

    test "owner badge has purple styling", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "bg-purple-100 text-purple-800"
      assert html =~ "Owner"
    end

    test "modify badge has blue styling", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{email: "modify@example.com"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, other_user, :modify)

      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "bg-blue-100 text-blue-800"
      assert html =~ "Can Modify"
    end

    test "read_only badge has gray styling", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{email: "readonly@example.com"})
      {:ok, _} = Kanban.Boards.add_user_to_board(board, other_user, :read_only)

      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "bg-gray-100 text-gray-800"
      assert html =~ "Read Only"
    end
  end

  describe "User Management UI State" do
    setup [:register_and_log_in_user]

    test "shows empty current users section when only owner exists", %{conn: conn, user: user} do
      board = board_fixture(user)
      {:ok, _form_live, html} = live(conn, ~p"/boards/#{board}/edit")

      assert html =~ "Current Users"
      # Should show only the owner
      assert html =~ user.email
      assert html =~ "Owner"
    end

    test "search form clears after adding user", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      form_live
      |> form("form[phx-submit='search_user']", email: other_user.email)
      |> render_submit()

      html = form_live |> render_click("add_user", %{"access" => "read_only"})

      # Search input should be cleared
      assert html =~ ~s(value="")
      # User should now appear in Current Users section
      assert html =~ other_user.email
      assert html =~ "Current Users"
      # But the "Add as Read Only" and "Add with Modify Access" buttons should be gone
      refute html =~ "Add as Read Only"
      refute html =~ "Add with Modify Access"
      assert html =~ "User added successfully"
    end

    test "shows both add buttons when user is found", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      html =
        form_live
        |> form("form[phx-submit='search_user']", email: other_user.email)
        |> render_submit()

      assert html =~ "Add as Read Only"
      assert html =~ "Add with Modify Access"
    end

    test "user info card has proper styling", %{conn: conn, user: user} do
      board = board_fixture(user)
      other_user = user_fixture(%{name: "Test User"})

      {:ok, form_live, _html} = live(conn, ~p"/boards/#{board}/edit")

      html =
        form_live
        |> form("form[phx-submit='search_user']", email: other_user.email)
        |> render_submit()

      assert html =~ "bg-blue-50 border border-blue-200"
      assert html =~ other_user.name
      assert html =~ other_user.email
    end
  end
end
