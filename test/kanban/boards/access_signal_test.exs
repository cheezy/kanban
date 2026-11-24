defmodule Kanban.Boards.AccessSignalTest do
  @moduledoc """
  Tests for `Kanban.Boards.AccessSignal`, the per-user signal for a
  board-access gain that sends no `board_access_changed` notification (D466),
  and for the paths that send it.
  """
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.AccessSignal
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.Telemetry.AfterCommit

  setup do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    workspace = org_workspace_fixture(organization)

    {:ok, org_board} =
      Boards.create_board(org_admin, %{name: "Org board"}, workspace: workspace)

    %{
      organization: organization,
      org_admin: org_admin,
      workspace: workspace,
      org_board: org_board
    }
  end

  defp grant(board, user, access) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
    |> Repo.insert!()
  end

  describe "topic/1 and subscribe/1" do
    test "names one user's topic from a scope, a user or an id" do
      user = user_fixture()
      topic = "user:#{user.id}:board_access"

      assert AccessSignal.topic(user.id) == topic
      assert AccessSignal.topic(user) == topic
      assert user |> Scope.for_user() |> AccessSignal.topic() == topic
    end

    test "is not the notification topic" do
      user = user_fixture()

      refute AccessSignal.topic(user) == Kanban.Notifications.topic(user)
    end

    test "subscribe/1 subscribes the caller to that topic" do
      user = user_fixture()

      assert :ok = AccessSignal.subscribe(user)
      assert AccessSignal.topic(user) in Registry.keys(Kanban.PubSub, self())
    end
  end

  describe "board_audience/1" do
    test "is the board's rows and the Organization's org-admins, and nobody else", ctx do
      reader = user_fixture()
      organization_member_fixture(ctx.organization, reader)
      grant(ctx.org_board, reader, :read_only)
      other_admin = user_fixture()
      organization_member_fixture(ctx.organization, other_admin, :org_admin)
      plain_member = user_fixture()
      organization_member_fixture(ctx.organization, plain_member)

      assert AccessSignal.board_audience(ctx.org_board.id) ==
               Enum.sort([ctx.org_admin.id, reader.id, other_admin.id])
    end

    test "is only the rows for a board in a personal workspace" do
      owner = user_fixture()
      board = board_fixture(owner)

      assert AccessSignal.board_audience(board.id) == [owner.id]
    end

    test "is empty for a board that does not exist" do
      assert AccessSignal.board_audience(-1) == []
    end
  end

  describe "organization_board_ids/1" do
    test "lists the boards in the Organization's workspaces only", ctx do
      {:ok, second} =
        Boards.create_board(ctx.org_admin, %{name: "Second board"}, workspace: ctx.workspace)

      _personal = board_fixture(ctx.org_admin)

      assert AccessSignal.organization_board_ids(ctx.organization.id) ==
               Enum.sort([ctx.org_board.id, second.id])
    end

    test "is empty for an Organization without boards" do
      assert AccessSignal.organization_board_ids(organization_fixture().id) == []
    end
  end

  describe "board_gained/1" do
    test "gain signal carries only ids", ctx do
      AccessSignal.subscribe(ctx.org_admin)

      assert :ok = AccessSignal.board_gained(ctx.org_board.id)

      assert_receive {Kanban.Boards, :access_gained, board_ids} = message
      assert board_ids == [ctx.org_board.id]
      assert tuple_size(message) == 3
      assert Enum.all?(board_ids, &is_integer/1)
    end

    test "reaches nobody outside the board's audience", ctx do
      stranger = user_fixture()
      AccessSignal.subscribe(stranger)

      assert :ok = AccessSignal.board_gained(ctx.org_board.id)

      refute_receive {Kanban.Boards, :access_gained, _board_ids}, 50
    end

    test "is held until the wrapping transaction commits, and dropped on a rollback", ctx do
      AccessSignal.subscribe(ctx.org_admin)
      board_id = ctx.org_board.id

      AfterCommit.after_commit(fn ->
        Repo.transact(fn ->
          AccessSignal.board_gained(board_id)
          refute_received {Kanban.Boards, :access_gained, _board_ids}
          {:ok, :done}
        end)
      end)

      assert_receive {Kanban.Boards, :access_gained, [^board_id]}

      AfterCommit.after_commit(fn ->
        Repo.transact(fn ->
          AccessSignal.board_gained(board_id)
          {:error, :rolled_back}
        end)
      end)

      refute_receive {Kanban.Boards, :access_gained, _board_ids}, 50
    end
  end

  describe "organization_gained/2" do
    test "sends the user every board of the Organization", ctx do
      user = user_fixture()
      AccessSignal.subscribe(user)

      assert :ok = AccessSignal.organization_gained(user.id, ctx.organization.id)

      board_ids = [ctx.org_board.id]
      assert_receive {Kanban.Boards, :access_gained, ^board_ids}
    end

    test "sends nothing for an Organization without boards" do
      user = user_fixture()
      AccessSignal.subscribe(user)

      assert :ok = AccessSignal.organization_gained(user.id, organization_fixture().id)

      refute_receive {Kanban.Boards, :access_gained, _board_ids}, 50
    end
  end

  describe "appointing an org-admin" do
    test "signals a new org-admin and a promoted member", ctx do
      newcomer = user_fixture()
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      board_ids = [ctx.org_board.id]

      AccessSignal.subscribe(newcomer)

      assert {:ok, _} =
               Organizations.appoint_org_admin(admin_fixture(), ctx.organization, newcomer)

      assert_receive {Kanban.Boards, :access_gained, ^board_ids}

      AccessSignal.subscribe(member)
      assert {:ok, _} = Organizations.appoint_org_admin(admin_fixture(), ctx.organization, member)
      assert_receive {Kanban.Boards, :access_gained, ^board_ids}
    end

    test "signals nothing for an existing org-admin or a refusal", ctx do
      AccessSignal.subscribe(ctx.org_admin)

      assert {:ok, _} =
               Organizations.appoint_org_admin(admin_fixture(), ctx.organization, ctx.org_admin)

      elsewhere = user_fixture()
      organization_member_fixture(organization_fixture(), elsewhere)
      AccessSignal.subscribe(elsewhere)

      assert {:error, :already_in_another_organization} =
               Organizations.appoint_org_admin(admin_fixture(), ctx.organization, elsewhere)

      assert {:error, :unauthorized} =
               Organizations.appoint_org_admin(user_fixture(), ctx.organization, user_fixture())

      refute_receive {Kanban.Boards, :access_gained, _board_ids}, 50
    end
  end

  describe "creating a board" do
    test "signals its owner", _ctx do
      owner = user_fixture()
      AccessSignal.subscribe(owner)

      {:ok, board} = Boards.create_board(owner, %{name: "Personal board"})

      board_id = board.id
      assert_receive {Kanban.Boards, :access_gained, [^board_id]}
    end

    test "in an org workspace signals the Organization's org-admins", ctx do
      other_admin = user_fixture()
      organization_member_fixture(ctx.organization, other_admin, :org_admin)
      AccessSignal.subscribe(other_admin)

      {:ok, board} =
        Boards.create_ai_optimized_board(ctx.org_admin, %{name: "AI org board"},
          workspace: ctx.workspace
        )

      board_id = board.id
      assert_receive {Kanban.Boards, :access_gained, [^board_id]}
    end

    test "that fails signals nobody" do
      owner = user_fixture()
      AccessSignal.subscribe(owner)

      assert {:error, %Ecto.Changeset{}} = Boards.create_board(owner, %{name: nil})

      refute_receive {Kanban.Boards, :access_gained, _board_ids}, 50
    end
  end
end
