defmodule Kanban.Boards.MemberCapTest do
  @moduledoc """
  The free-board member cap in `Kanban.Boards.add_user_to_board/4` and the
  `Kanban.Boards.member_cap_status/1` read (W2400).

  async: false - these tests switch the global `:plans_enforced` application
  env through `Kanban.PlansHelpers`. The race between two adds is covered with a
  real second Postgres session in `Kanban.Boards.MemberCapLockTest`.
  """
  use Kanban.DataCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo

  @cap_event [:kanban, :board, :member_cap_reached]

  setup do
    previous = Application.fetch_env(:kanban, :plans_enforced)
    on_exit(fn -> restore_plans_enforced(previous) end)
    Application.put_env(:kanban, :plans_enforced, false)
    :ok
  end

  # A free board (in its owner's personal workspace) with the owner row plus
  # `extra` added members, so it has `extra + 1` board_users rows.
  defp free_board_with_members(extra) do
    owner = user_fixture()
    board = board_fixture(owner)
    members = add_members(board, owner, extra)
    %{owner: owner, board: board, members: members}
  end

  defp add_members(board, owner, count) do
    for _ <- List.duplicate(nil, count) do
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      member
    end
  end

  defp member_count(board) do
    from(bu in BoardUser, where: bu.board_id == ^board.id)
    |> Repo.aggregate(:count)
  end

  defp member?(board, user) do
    from(bu in BoardUser, where: bu.board_id == ^board.id and bu.user_id == ^user.id)
    |> Repo.exists?()
  end

  # A board in an Organization workspace, with the user who owns it.
  defp org_board_with_owner do
    board = organization_fixture() |> org_workspace_fixture() |> place_board_in_workspace()
    owner_row = Repo.get_by!(BoardUser, board_id: board.id, access: :owner)
    %{board: board, owner: Repo.preload(owner_row, :user).user}
  end

  describe "add_user_to_board/4 with enforcement on" do
    setup :enforce_plans

    test "a board with 2 members accepts a third and refuses a fourth, inserting nothing" do
      %{owner: owner, board: board} = free_board_with_members(1)
      assert member_count(board) == 2

      assert {:ok, %BoardUser{}} = Boards.add_user_to_board(board, user_fixture(), :modify, owner)
      assert member_count(board) == 3

      fourth = user_fixture()

      assert {:error, :member_cap_reached} =
               Boards.add_user_to_board(board, fourth, :read_only, owner)

      assert member_count(board) == 3
      refute member?(board, fourth)
    end

    test "the owner row counts as a member" do
      %{owner: owner, board: board} = free_board_with_members(2)

      assert {:error, :member_cap_reached} =
               Boards.add_user_to_board(board, user_fixture(), :modify, owner)
    end

    test "API tokens on the board are not members" do
      %{owner: owner, board: board, members: [member]} = free_board_with_members(1)
      {:ok, _} = ApiTokens.create_api_token(owner, board, %{name: "Owner agent"})
      {:ok, _} = ApiTokens.create_api_token(member, board, %{name: "Member agent"})

      assert {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :modify, owner)
      assert member_count(board) == 3
    end

    test "a grandfathered board keeps its 5 members, refuses additions, and accepts one at 2" do
      Application.put_env(:kanban, :plans_enforced, false)
      %{owner: owner, board: board, members: members} = free_board_with_members(4)
      enforce_plans()
      assert member_count(board) == 5

      assert {:error, :member_cap_reached} =
               Boards.add_user_to_board(board, user_fixture(), :modify, owner)

      assert member_count(board) == 5

      for member <- Enum.take(members, 3) do
        assert {:ok, _} = Boards.remove_user_from_board(board, member, owner)
      end

      assert member_count(board) == 2
      assert {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :modify, owner)
      assert member_count(board) == 3
    end

    test "a board in an org workspace accepts a tenth member" do
      %{board: board, owner: owner} = org_board_with_owner()
      add_members(board, owner, 9)

      assert member_count(board) == 10
    end

    test "decides from the board's current workspace, not the struct the caller loaded" do
      %{owner: owner, board: board} = free_board_with_members(2)
      stale = Repo.preload(board, :workspace)
      org_workspace = org_workspace_fixture(organization_fixture())

      {1, _} =
        Board
        |> where([b], b.id == ^board.id)
        |> Repo.update_all(set: [workspace_id: org_workspace.id])

      assert {:ok, _} = Boards.add_user_to_board(stale, user_fixture(), :modify, owner)
    end

    test "a user already on a full board gets the duplicate error, not the cap refusal" do
      %{owner: owner, board: board, members: [member | _]} = free_board_with_members(2)
      attach_telemetry(@cap_event)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Boards.add_user_to_board(board, member, :read_only, owner)

      assert %{board_id: [_ | _]} = errors_on(changeset)
      assert member_count(board) == 3
      refute_received {:telemetry_event, @cap_event, _, _}
    end

    test "a caller who does not own a full board is refused as unauthorized first" do
      %{board: board, members: [member | _]} = free_board_with_members(2)
      attach_telemetry(@cap_event)

      assert {:error, :unauthorized} =
               Boards.add_user_to_board(board, user_fixture(), :modify, member)

      refute_received {:telemetry_event, @cap_event, _, _}
    end

    test "each refusal emits member_cap_reached once, with via :direct_add" do
      %{owner: owner, board: board} = free_board_with_members(2)
      attach_telemetry(@cap_event)

      assert {:error, :member_cap_reached} =
               Boards.add_user_to_board(board, user_fixture(), :modify, owner)

      assert_received {:telemetry_event, @cap_event, %{count: 1}, metadata}
      assert metadata == %{board_id: board.id, actor_user_id: owner.id, via: :direct_add}
      refute_received {:telemetry_event, @cap_event, _, _}

      assert {:error, :member_cap_reached} =
               Boards.add_user_to_board(board, user_fixture(), :read_only, owner)

      assert_received {:telemetry_event, @cap_event, %{count: 1}, _}
      refute_received {:telemetry_event, @cap_event, _, _}
    end

    test "an accepted addition emits no cap event" do
      %{owner: owner, board: board} = free_board_with_members(1)
      attach_telemetry(@cap_event)

      assert {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :modify, owner)
      refute_received {:telemetry_event, @cap_event, _, _}
    end

    test "a refusal sends no members_changed broadcast" do
      %{owner: owner, board: board} = free_board_with_members(2)
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")

      assert {:error, :member_cap_reached} =
               Boards.add_user_to_board(board, user_fixture(), :modify, owner)

      refute_received {Kanban.Boards, :members_changed, _}
    end

    test "update_user_access/4 and remove_user_from_board/3 are never capped" do
      Application.put_env(:kanban, :plans_enforced, false)
      %{owner: owner, board: board, members: [a, b, c]} = free_board_with_members(3)
      enforce_plans()

      assert {:ok, %BoardUser{access: :read_only}} =
               Boards.update_user_access(board, a, :read_only, owner)

      assert {:ok, %BoardUser{access: :modify}} =
               Boards.update_user_access(board, a, :modify, owner)

      assert {:ok, %BoardUser{}} = Boards.remove_user_from_board(board, b, owner)
      assert {:ok, %BoardUser{}} = Boards.remove_user_from_board(board, c, owner)
      assert member_count(board) == 2

      # Re-fill the board, then change the owner's own row, the first half of
      # an ownership transfer: still not capped.
      add_members(board, owner, 1)
      assert Boards.member_cap_status(board).reached?

      assert {:ok, %BoardUser{access: :modify}} =
               Boards.update_user_access(board, owner, :modify, owner)

      assert member_count(board) == 3
    end
  end

  describe "add_user_to_board/4 with enforcement off" do
    test "nothing is capped" do
      %{owner: owner, board: board} = free_board_with_members(5)
      attach_telemetry(@cap_event)

      assert {:ok, _} = Boards.add_user_to_board(board, user_fixture(), :modify, owner)
      assert member_count(board) == 7
      refute_received {:telemetry_event, @cap_event, _, _}
    end
  end

  describe "member_cap_status/1" do
    test "with enforcement on, a free board reports its count, the cap and whether it is full" do
      enforce_plans()
      %{owner: owner, board: board} = free_board_with_members(1)

      assert Boards.member_cap_status(board) == %{count: 2, cap: 3, reached?: false}

      add_members(board, owner, 1)
      assert Boards.member_cap_status(board) == %{count: 3, cap: 3, reached?: true}
    end

    test "a grandfathered free board reports a count above the cap" do
      %{board: board} = free_board_with_members(4)
      enforce_plans()

      assert Boards.member_cap_status(board) == %{count: 5, cap: 3, reached?: true}
    end

    test "a board in an org workspace has no cap" do
      enforce_plans()
      %{board: board, owner: owner} = org_board_with_owner()
      add_members(board, owner, 3)

      assert Boards.member_cap_status(board) == %{count: 4, cap: nil, reached?: false}
    end

    test "with enforcement off, no board has a cap" do
      %{board: board} = free_board_with_members(3)

      assert Boards.member_cap_status(board) == %{count: 4, cap: nil, reached?: false}
    end
  end
end
