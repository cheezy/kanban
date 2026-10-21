defmodule Kanban.Workspaces.PersonalCleanupTest do
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.AuditLog
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.Notification
  alias Kanban.Workspaces

  setup do
    user = user_fixture()
    workspace = Workspaces.get_personal_workspace(user)

    # A board in the user's personal workspace with no board_users rows; each
    # test adds the rows it needs, in the order they should be read.
    board = place_board_in_workspace(workspace)
    from(bu in BoardUser, where: bu.board_id == ^board.id) |> Repo.delete_all()

    %{user: user, board: board}
  end

  defp add_member(board, user, access \\ :modify) do
    Repo.insert!(%BoardUser{board_id: board.id, user_id: user.id, access: access})
  end

  defp disabled_user_fixture(attrs \\ %{}) do
    attrs
    |> user_fixture()
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp disable(user) do
    user |> Ecto.Changeset.change(disabled_at: DateTime.utc_now(:second)) |> Repo.update!()
  end

  defp home_of(board), do: Repo.get!(Board, board.id).workspace_id

  defp personal_workspace_id(user), do: Workspaces.get_personal_workspace(user).id

  defp access_of(board, user) do
    from(bu in BoardUser, where: bu.board_id == ^board.id and bu.user_id == ^user.id)
    |> Repo.one()
    |> then(&(&1 && &1.access))
  end

  defp access_notices(user) do
    from(n in Notification,
      where: n.user_id == ^user.id and n.event_type == :board_access_changed
    )
    |> Repo.all()
  end

  test "gives the board to another enabled owner before an earlier member", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    add_member(board, user_fixture())
    owner = user_fixture()
    add_member(board, owner, :owner)

    assert {:ok, %{rehomed: [{board_id, owner_id}], deleted: [], given_to_admin: []}} =
             Workspaces.clear_personal_boards(user)

    assert {board_id, owner_id} == {board.id, owner.id}
    assert home_of(board) == personal_workspace_id(owner)
    assert access_of(board, owner) == :owner
  end

  test "skips a disabled owner and gives the board to the earliest enabled member", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    disabled = disabled_user_fixture()
    add_member(board, disabled, :owner)
    member = user_fixture()
    add_member(board, member)

    assert {:ok, %{rehomed: [{_board_id, member_id}], given_to_admin: []}} =
             Workspaces.clear_personal_boards(user)

    assert member_id == member.id
    assert home_of(board) == personal_workspace_id(member)
    assert access_of(board, member) == :modify
    assert access_of(board, disabled) == :owner
  end

  test "skips a disabled member listed before an enabled one", %{user: user, board: board} do
    add_member(board, user)
    disabled = disabled_user_fixture()
    add_member(board, disabled)
    enabled = user_fixture()
    add_member(board, enabled)

    assert {:ok, %{rehomed: [{_board_id, target_id}]}} = Workspaces.clear_personal_boards(user)

    assert target_id == enabled.id
    assert home_of(board) == personal_workspace_id(enabled)
    refute home_of(board) == personal_workspace_id(disabled)
  end

  test "gives a board whose other members are all disabled to the earliest enabled admin", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    old_owner = disabled_user_fixture()
    add_member(board, old_owner, :owner)
    member = disabled_user_fixture()
    add_member(board, member)
    admin_fixture() |> disable()
    admin = admin_fixture()

    assert {:ok, %{rehomed: [{_board_id, target_id}], given_to_admin: [grant]}} =
             Workspaces.clear_personal_boards(user)

    assert target_id == admin.id
    assert home_of(board) == personal_workspace_id(admin)

    assert %{board: %Board{id: board_id}, owner_row: owner_row, demoted_row: demoted} = grant
    assert board_id == board.id
    assert {owner_row.user_id, owner_row.access} == {admin.id, :owner}
    assert {demoted.user_id, demoted.access} == {old_owner.id, :modify}
  end

  test "makes the admin the owner, so they can reach the board, and keeps the members", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    old_owner = disabled_user_fixture()
    add_member(board, old_owner, :owner)
    member = disabled_user_fixture()
    add_member(board, member, :read_only)
    admin = admin_fixture()

    assert {:ok, _result} = Workspaces.clear_personal_boards(user)

    assert access_of(board, admin) == :owner
    assert Boards.get_user_access(board.id, admin.id) == :owner
    assert {:ok, %Board{}} = Boards.get_board(board.id, admin)
    assert access_of(board, old_owner) == :modify
    assert access_of(board, member) == :read_only
  end

  test "an owner demoted by the grant gets write access back once enabled", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    old_owner = disabled_user_fixture()
    add_member(board, old_owner, :owner)
    admin_fixture()

    assert {:ok, _result} = Workspaces.clear_personal_boards(user)

    old_owner |> Ecto.Changeset.change(disabled_at: nil) |> Repo.update!()
    assert Boards.get_user_access(board.id, old_owner.id) == :modify
  end

  test "deletes a board whose other members are all disabled when no enabled admin exists", %{
    user: user,
    board: board
  } do
    add_member(board, user)
    add_member(board, disabled_user_fixture())
    admin_fixture() |> disable()

    assert {:ok, %{deleted: [%Board{id: board_id}], rehomed: []}} =
             Workspaces.clear_personal_boards(user)

    assert board_id == board.id
    refute Repo.get(Board, board.id)
  end

  test "skips a disabled admin for a board with no members", %{user: user, board: board} do
    admin_fixture() |> disable()
    admin = admin_fixture()

    assert {:ok, %{rehomed: [{_board_id, target_id}], given_to_admin: [grant]}} =
             Workspaces.clear_personal_boards(user)

    assert target_id == admin.id
    assert home_of(board) == personal_workspace_id(admin)
    assert grant.demoted_row == nil
    assert access_of(board, admin) == :owner
  end

  test "deletes a board only the user uses, even when an enabled admin exists", %{
    user: user,
    board: board
  } do
    add_member(board, user, :owner)
    admin_fixture()

    assert {:ok, %{deleted: [%Board{}], rehomed: [], given_to_admin: []}} =
             Workspaces.clear_personal_boards(user)

    refute Repo.get(Board, board.id)
  end

  describe "report_admin_grants/2" do
    setup %{user: user, board: board} do
      add_member(board, user)
      old_owner = disabled_user_fixture()
      add_member(board, old_owner, :owner)
      admin = admin_fixture()
      {:ok, %{given_to_admin: grants}} = Workspaces.clear_personal_boards(user)

      %{old_owner: old_owner, admin: admin, grants: grants}
    end

    test "records the audit event with the deleted account, the board and the admin", ctx do
      attach_telemetry([[:kanban, :audit, :board_given_to_site_admin]])
      %{user: %{id: user_id}, board: %{id: board_id}, admin: %{id: admin_id}} = ctx

      assert Workspaces.report_admin_grants(ctx.grants, ctx.user) == :ok

      assert_received {:telemetry_event, [:kanban, :audit, :board_given_to_site_admin], _,
                       %{user_id: ^user_id, board_id: ^board_id, member_user_id: ^admin_id}}

      assert [event] = AuditLog.list_events(action: :board_given_to_site_admin)
      assert event.metadata["member_user_id"] == admin_id
    end

    test "emits membership telemetry for the added admin and the demoted owner", ctx do
      attach_telemetry([
        [:kanban, :board, :member_added],
        [:kanban, :board, :member_access_changed]
      ])

      %{admin: %{id: admin_id}, old_owner: %{id: old_owner_id}} = ctx

      Workspaces.report_admin_grants(ctx.grants, ctx.user)

      assert_received {:telemetry_event, [:kanban, :board, :member_added], _,
                       %{user_id: ^admin_id, access: :owner}}

      assert_received {:telemetry_event, [:kanban, :board, :member_access_changed], _,
                       %{user_id: ^old_owner_id, from_access: :owner, to_access: :modify}}
    end

    test "tells the admin they were added as owner, and the old owner of the change", ctx do
      Workspaces.report_admin_grants(ctx.grants, ctx.user)

      assert [added] = access_notices(ctx.admin)
      assert added.board_id == ctx.board.id
      assert added.metadata["change"] == "added"
      assert added.metadata["access"] == "owner"
      assert added.actor_name == nil

      assert [changed] = access_notices(ctx.old_owner)
      assert changed.metadata["change"] == "access_changed"
      assert changed.metadata["access"] == "modify"
    end

    test "reports nothing for no grants", %{user: user} do
      attach_telemetry([[:kanban, :audit, :board_given_to_site_admin]])

      assert Workspaces.report_admin_grants([], user) == :ok

      refute_received {:telemetry_event, _, _, _}
    end
  end
end
