defmodule Kanban.Workspaces.GrandfatherMigrationTest do
  # Not async: seeding legacy rows needs boards.workspace_id nullable again, and
  # that ALTER TABLE holds a lock on boards until this test's sandbox
  # transaction rolls back.
  use Kanban.DataCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Accounts.User
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias Kanban.Workspaces.Workspace
  alias Kanban.Workspaces.WorkspaceMember

  @backfill "priv/repo/migrations/20261018134655_backfill_personal_workspaces.exs"
  @require "priv/repo/migrations/20261018134657_require_board_workspace.exs"

  setup_all do
    [{backfill, _bytecode}] = Code.require_file(@backfill)
    [{require_workspace, _bytecode}] = Code.require_file(@require)
    %{backfill: backfill, require_workspace: require_workspace}
  end

  setup do
    Repo.query!("ALTER TABLE boards ALTER COLUMN workspace_id DROP NOT NULL")
    :ok
  end

  # Puts every row this test can see back into its pre-workspace shape: no
  # board has a workspace and no personal workspace exists.
  defp make_legacy! do
    Repo.update_all(Board, set: [workspace_id: nil])
    Workspace |> where([w], w.personal == true) |> Repo.delete_all()
  end

  defp run(migration), do: Enum.each(migration.backfill_statements(), &Repo.query!/1)

  defp add_member(board, user, access, inserted_at \\ nil) do
    board_user =
      %BoardUser{}
      |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
      |> Repo.insert!()

    if inserted_at do
      BoardUser
      |> where([bu], bu.id == ^board_user.id)
      |> Repo.update_all(set: [inserted_at: inserted_at])
    end

    board_user
  end

  defp remove_owner(board) do
    BoardUser
    |> where([bu], bu.board_id == ^board.id and bu.access == :owner)
    |> Repo.delete_all()
  end

  defp remove_members(board),
    do: BoardUser |> where([bu], bu.board_id == ^board.id) |> Repo.delete_all()

  defp board_member_count(board),
    do: BoardUser |> where([bu], bu.board_id == ^board.id) |> Repo.aggregate(:count)

  defp set_user(user, fields) do
    User |> where([u], u.id == ^user.id) |> Repo.update_all(set: fields)
    user
  end

  defp personal_workspace_id(user) do
    WorkspaceMember
    |> join(:inner, [m], w in assoc(m, :workspace))
    |> where([m, w], m.user_id == ^user.id and m.role == :owner and w.personal == true)
    |> select([_m, w], w.id)
    |> Repo.one!()
  end

  defp workspace_rows,
    do: Workspace |> order_by(:id) |> select([w], {w.id, w.slug}) |> Repo.all()

  defp member_rows,
    do: WorkspaceMember |> order_by(:id) |> select([m], {m.id, m.user_id, m.role}) |> Repo.all()

  defp workspace_id(board), do: Repo.get!(Board, board.id).workspace_id

  defp board_user_rows do
    BoardUser
    |> order_by(:id)
    |> select([bu], {bu.id, bu.board_id, bu.user_id, bu.access, bu.inserted_at, bu.updated_at})
    |> Repo.all()
  end

  defp access_matrix(boards, users) do
    for board <- boards, user <- users, into: %{} do
      {{board.id, user.id}, Boards.get_user_access(board.id, user.id)}
    end
  end

  describe "backfill_statements/0" do
    test "gives every user one personal workspace with a single owner row and keeps all access",
         %{backfill: backfill} do
      owner = user_fixture()
      other_owner = user_fixture()
      no_boards = user_fixture()
      disabled = set_user(user_fixture(), disabled_at: DateTime.utc_now(:second))
      editor = user_fixture()
      reader = user_fixture()

      # The editor's row is older than the owner's, so only the owner rule,
      # not the earliest-member rule, puts this board with its owner.
      board = board_fixture(owner)
      add_member(board, editor, :modify, ~N[2020-01-01 00:00:00])
      add_member(board, reader, :read_only)

      other_board = ai_optimized_board_fixture(other_owner)
      add_member(other_board, editor, :read_only)
      add_member(other_board, reader, :modify)

      disabled_board = board_fixture(disabled)

      users = [owner, other_owner, no_boards, disabled, editor, reader]
      boards = [board, other_board, disabled_board]

      make_legacy!()
      rows_before = board_user_rows()
      access_before = access_matrix(boards, users)

      run(backfill)

      for user <- users do
        assert [%WorkspaceMember{role: :owner, workspace_id: workspace_id}] =
                 WorkspaceMember |> where([m], m.user_id == ^user.id) |> Repo.all()

        assert %Workspace{personal: true, organization_id: nil} =
                 Repo.get!(Workspace, workspace_id)

        assert WorkspaceMember
               |> where([m], m.workspace_id == ^workspace_id)
               |> Repo.aggregate(:count) == 1
      end

      assert workspace_id(board) == personal_workspace_id(owner)
      assert workspace_id(other_board) == personal_workspace_id(other_owner)
      assert workspace_id(disabled_board) == personal_workspace_id(disabled)

      assert WorkspaceMember |> where([m], m.role != :owner) |> Repo.aggregate(:count) == 0
      assert board_user_rows() == rows_before
      assert access_matrix(boards, users) == access_before
    end

    test "a board above the free member cap keeps every member", %{backfill: backfill} do
      owner = user_fixture()
      members = for _ <- 1..4, do: user_fixture()
      board = board_fixture(owner)
      Enum.each(members, &add_member(board, &1, :modify))

      make_legacy!()
      access_before = access_matrix([board], [owner | members])

      run(backfill)

      assert board_member_count(board) == 5
      assert access_matrix([board], [owner | members]) == access_before
      assert workspace_id(board) == personal_workspace_id(owner)
    end

    test "an ownerless board goes to its earliest remaining member", %{backfill: backfill} do
      reader_only = board_fixture(user_fixture())
      reader = user_fixture()
      add_member(reader_only, reader, :read_only)
      remove_owner(reader_only)

      # The later row by id has the earlier inserted_at, so it wins.
      by_time = board_fixture(user_fixture())
      first_by_id = user_fixture()
      earliest = user_fixture()
      add_member(by_time, first_by_id, :modify, ~N[2025-01-02 00:00:00])
      add_member(by_time, earliest, :read_only, ~N[2025-01-01 00:00:00])
      remove_owner(by_time)

      # Same inserted_at: the lower id wins.
      tied = board_fixture(user_fixture())
      lower_id = user_fixture()
      higher_id = user_fixture()
      add_member(tied, lower_id, :modify, ~N[2025-01-01 00:00:00])
      add_member(tied, higher_id, :modify, ~N[2025-01-01 00:00:00])
      remove_owner(tied)

      make_legacy!()
      run(backfill)

      assert workspace_id(reader_only) == personal_workspace_id(reader)
      assert workspace_id(by_time) == personal_workspace_id(earliest)
      assert workspace_id(tied) == personal_workspace_id(lower_id)
      assert Boards.get_user_access(reader_only.id, reader.id) == :read_only
    end

    test "a member of several owners' boards gets an empty personal workspace",
         %{backfill: backfill} do
      member = user_fixture()

      boards =
        for _ <- 1..3 do
          board = board_fixture(user_fixture())
          add_member(board, member, :modify)
          board
        end

      make_legacy!()
      run(backfill)

      workspace_id = personal_workspace_id(member)
      refute Board |> where([b], b.workspace_id == ^workspace_id) |> Repo.exists?()
      assert Enum.all?(boards, &(Boards.get_user_access(&1.id, member.id) == :modify))
    end

    test "a disabled earliest member still receives an ownerless board", %{backfill: backfill} do
      board = board_fixture(user_fixture())
      disabled = set_user(user_fixture(), disabled_at: DateTime.utc_now(:second))
      later = user_fixture()
      add_member(board, disabled, :read_only, ~N[2025-01-01 00:00:00])
      add_member(board, later, :modify, ~N[2025-01-02 00:00:00])
      remove_owner(board)

      make_legacy!()
      run(backfill)

      assert workspace_id(board) == personal_workspace_id(disabled)
    end

    test "a memberless board goes to the earliest enabled site admin", %{backfill: backfill} do
      _disabled_admin =
        admin_fixture()
        |> set_user(disabled_at: DateTime.utc_now(:second), inserted_at: ~U[2025-01-01 00:00:00Z])

      earliest_enabled = set_user(admin_fixture(), inserted_at: ~U[2025-01-02 00:00:00Z])
      _later_admin = set_user(admin_fixture(), inserted_at: ~U[2025-01-03 00:00:00Z])

      board = board_fixture(user_fixture())
      remove_members(board)

      make_legacy!()
      run(backfill)

      assert workspace_id(board) == personal_workspace_id(earliest_enabled)
      assert board_member_count(board) == 0
    end

    test "raises when a memberless board exists and no enabled site admin does",
         %{backfill: backfill} do
      _disabled_admin = admin_fixture()
      board = board_fixture(user_fixture())
      remove_members(board)

      User
      |> where([u], u.type == :admin)
      |> Repo.update_all(set: [disabled_at: DateTime.utc_now(:second)])

      make_legacy!()

      error = assert_raise Postgrex.Error, fn -> run(backfill) end

      assert error.postgres.message =~
               "1 board(s) have no members and there is no enabled site admin"
    end

    test "running it again creates no duplicate workspaces or members", %{backfill: backfill} do
      owner = user_fixture()
      member = user_fixture()
      board = board_fixture(owner)
      add_member(board, member, :modify)

      make_legacy!()
      run(backfill)

      workspaces = workspace_rows()
      members = member_rows()

      placed = workspace_id(board)

      run(backfill)

      assert workspace_rows() == workspaces
      assert member_rows() == members

      assert workspace_id(board) == placed
    end

    test "leaves users who already have a personal workspace and placed boards alone",
         %{backfill: backfill} do
      owner = user_fixture()
      board = board_fixture(owner)
      workspace_id = personal_workspace_id(owner)

      run(backfill)

      assert personal_workspace_id(owner) == workspace_id
      assert workspace_id(board) == workspace_id
    end
  end

  describe "require_statements/0" do
    test "refuses to add NOT NULL while a board has no workspace", ctx do
      board_fixture(user_fixture())
      make_legacy!()

      error =
        assert_raise Postgrex.Error, fn ->
          Enum.each(ctx.require_workspace.require_statements(), &Repo.query!/1)
        end

      assert error.postgres.message =~ "1 board(s) still have no workspace"
    end

    test "makes boards.workspace_id NOT NULL once every board is placed", ctx do
      board_fixture(user_fixture())
      make_legacy!()
      run(ctx.backfill)

      Enum.each(ctx.require_workspace.require_statements(), &Repo.query!/1)

      assert %{rows: [["NO"]]} =
               Repo.query!(
                 "SELECT is_nullable FROM information_schema.columns WHERE table_name = 'boards' AND column_name = 'workspace_id'"
               )
    end
  end
end
