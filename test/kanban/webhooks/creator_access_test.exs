defmodule Kanban.Webhooks.CreatorAccessTest do
  @moduledoc """
  Webhook endpoints are disabled when their creator can no longer open the
  board (decided 2026-10-20): `Kanban.Webhooks.pause_creator_endpoints/2`,
  `pause_former_member_endpoints/2` and `pause_outside_endpoints/2`, and the
  removal, move and deletion paths that call them.
  """
  use Kanban.DataCase, async: true
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query, only: [from: 2]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TasksFixtures
  import Kanban.WebhooksFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Organizations.MemberRemoval
  alias Kanban.Repo
  alias Kanban.Webhooks
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint
  alias Kanban.Webhooks.Events
  alias Kanban.Workspaces

  @opts [resolver: &__MODULE__.public_resolver/1, allow_http: false]

  def public_resolver(_host), do: {:ok, [{93, 184, 216, 34}]}

  defp grant(board, user, access) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
    |> Repo.insert!()
  end

  defp endpoint(board, creator),
    do: webhook_endpoint_fixture(board, %{created_by_id: creator && creator.id})

  defp enabled?(endpoint), do: Repo.get!(Endpoint, endpoint.id).enabled

  defp put_in_workspace(board, workspace) do
    board |> Ecto.Changeset.change(workspace_id: workspace.id) |> Repo.update!()
  end

  defp org_with_admin do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    {organization, org_admin}
  end

  describe "pause_creator_endpoints/2" do
    setup do
      creator = user_fixture()
      board = board_fixture(creator)
      other_board = board_fixture(creator)
      %{creator: creator, board: board, other_board: other_board}
    end

    test "disables the creator's endpoints on the listed boards only and counts them", ctx do
      paused = endpoint(ctx.board, ctx.creator)
      elsewhere = endpoint(ctx.other_board, ctx.creator)
      someone_elses = endpoint(ctx.board, user_fixture())

      assert Webhooks.pause_creator_endpoints(ctx.creator.id, [ctx.board.id]) == 1

      refute enabled?(paused)
      assert enabled?(elsewhere)
      assert enabled?(someone_elses)
    end

    test "takes a query of board ids or :all", ctx do
      first = endpoint(ctx.board, ctx.creator)
      second = endpoint(ctx.other_board, ctx.creator)
      query = from(b in Board, where: b.id == ^ctx.board.id, select: b.id)

      assert Webhooks.pause_creator_endpoints(ctx.creator.id, query) == 1
      refute enabled?(first)
      assert enabled?(second)

      assert Webhooks.pause_creator_endpoints(ctx.creator.id, :all) == 1
      refute enabled?(second)
    end

    test "skips disabled endpoints and bumps the lock version of the ones it pauses", ctx do
      paused = endpoint(ctx.board, ctx.creator)

      already =
        webhook_endpoint_fixture(ctx.board, %{created_by_id: ctx.creator.id, enabled: false})

      assert Webhooks.pause_creator_endpoints(ctx.creator.id, :all) == 1
      assert Repo.get!(Endpoint, paused.id).lock_version == paused.lock_version + 1
      assert Repo.get!(Endpoint, already.id).lock_version == already.lock_version
    end

    test "an empty board list pauses nothing", ctx do
      paused = endpoint(ctx.board, ctx.creator)

      assert Webhooks.pause_creator_endpoints(ctx.creator.id, []) == 0
      assert enabled?(paused)
    end
  end

  describe "pause_former_member_endpoints/2" do
    test "keeps the endpoints on boards the creator can still open" do
      owner = user_fixture()
      kept_board = board_fixture(owner)
      lost_board = board_fixture(owner)
      creator = user_fixture()
      grant(kept_board, creator, :read_only)
      kept = endpoint(kept_board, creator)
      lost = endpoint(lost_board, creator)

      assert Webhooks.pause_former_member_endpoints(creator.id, [kept_board.id, lost_board.id]) ==
               1

      assert enabled?(kept)
      refute enabled?(lost)
    end

    test "keeps an org-admin's endpoints on their Organization's boards, which they reach without a row" do
      {organization, org_admin} = org_with_admin()

      board =
        user_fixture() |> board_fixture() |> put_in_workspace(org_workspace_fixture(organization))

      kept = endpoint(board, org_admin)

      assert Webhooks.pause_former_member_endpoints(org_admin.id, [board.id]) == 0
      assert enabled?(kept)
    end
  end

  describe "pause_outside_endpoints/2" do
    test "disables endpoints created by a non-member or a deleted user, and keeps members' ones" do
      {organization, org_admin} = org_with_admin()
      board = board_fixture(org_admin)
      other_board = board_fixture(org_admin)
      outsiders = endpoint(board, user_fixture())
      orphaned = endpoint(board, nil)
      members = endpoint(board, org_admin)
      other_boards = endpoint(other_board, user_fixture())

      assert Webhooks.pause_outside_endpoints(board.id, organization.id) == 2

      refute enabled?(outsiders)
      refute enabled?(orphaned)
      assert enabled?(members)
      assert enabled?(other_boards)
    end
  end

  describe "update_endpoint/4 re-enabling" do
    setup do
      owner = user_fixture()
      board = board_fixture(owner)
      former = user_fixture()

      paused =
        webhook_endpoint_fixture(board, %{created_by_id: former.id, enabled: false})

      %{owner_scope: Scope.for_user(owner), owner: owner, paused: paused, former: former}
    end

    test "makes the owner the creator of an endpoint they enable", ctx do
      assert {:ok, updated} =
               Webhooks.update_endpoint(ctx.owner_scope, ctx.paused, %{"enabled" => true}, @opts)

      assert updated.enabled
      assert Repo.get!(Endpoint, ctx.paused.id).created_by_id == ctx.owner.id
    end

    test "keeps the creator on an edit that does not enable it", ctx do
      assert {:ok, _} =
               Webhooks.update_endpoint(
                 ctx.owner_scope,
                 ctx.paused,
                 %{"event_types" => ["task.moved"]},
                 @opts
               )

      assert Repo.get!(Endpoint, ctx.paused.id).created_by_id == ctx.former.id
    end
  end

  describe "board member removal" do
    setup do
      owner = user_fixture()
      board = board_fixture(owner)
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      %{owner: owner, board: board, member: member}
    end

    test "disables the removed member's endpoints on the board and nobody else's", ctx do
      removed = endpoint(ctx.board, ctx.member)
      owners = endpoint(ctx.board, ctx.owner)

      assert {:ok, _} = Boards.remove_user_from_board(ctx.board, ctx.member, ctx.owner)

      refute enabled?(removed)
      assert enabled?(owners)
    end

    test "an access change that keeps the member on the board pauses nothing", ctx do
      kept = endpoint(ctx.board, ctx.member)

      assert {:ok, _} = Boards.update_user_access(ctx.board, ctx.member, :read_only, ctx.owner)
      assert enabled?(kept)
    end
  end

  describe "a board handed over and moved into an Organization" do
    test "the former owner's endpoint stops delivering once they are removed, before the move" do
      {organization, org_admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      outsider = user_fixture()
      board = board_fixture(outsider)
      outsiders = endpoint(board, outsider)
      grant(board, org_admin, :modify)

      assert {:ok, _} = Boards.transfer_board_ownership(board, org_admin, outsider)
      assert enabled?(outsiders), "a demoted owner can still open the board"

      assert {:ok, _} = Boards.remove_user_from_board(board, outsider, org_admin)
      refute enabled?(outsiders)

      assert {:ok, _} = Workspaces.move_board_to_workspace(org_admin, board, workspace)

      task = board |> column_fixture() |> task_fixture()
      Events.emit(board.id, :task_created, task)
      refute_enqueued(worker: DeliveryWorker)
    end

    test "the move disables an endpoint an outsider left enabled, and keeps an Organization member's" do
      {organization, org_admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      board = board_fixture(org_admin)
      left_behind = endpoint(board, user_fixture())
      own = endpoint(board, org_admin)

      assert {:ok, _} = Workspaces.move_board_to_workspace(org_admin, board, workspace)

      refute enabled?(left_behind)
      assert enabled?(own)
    end

    test "a refused move pauses nothing" do
      {organization, org_admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      board = board_fixture(org_admin)
      grant(board, user_fixture(), :read_only)
      left_behind = endpoint(board, user_fixture())

      assert {:error, {:non_members, _}} =
               Workspaces.move_board_to_workspace(org_admin, board, workspace)

      assert enabled?(left_behind)
    end
  end

  describe "leaving an Organization" do
    setup do
      {organization, org_admin} = org_with_admin()
      workspace = org_workspace_fixture(organization)
      board = org_admin |> board_fixture() |> put_in_workspace(workspace)
      %{organization: organization, org_admin: org_admin, workspace: workspace, board: board}
    end

    test "a removed member's endpoints on the Organization's boards are disabled", ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      grant(ctx.board, member, :modify)
      personal_board = board_fixture(member)
      removed = endpoint(ctx.board, member)
      personal = endpoint(personal_board, member)

      assert {:ok, _} = MemberRemoval.remove_member(ctx.org_admin, ctx.organization.id, member.id)

      refute enabled?(removed)
      assert enabled?(personal)
    end

    test "a removed org-admin's endpoints are disabled though they held no row", ctx do
      other_admin = user_fixture()
      organization_member_fixture(ctx.organization, other_admin, :org_admin)
      removed = endpoint(ctx.board, other_admin)

      assert {:ok, _} =
               Organizations.remove_org_admin(admin_fixture(), ctx.organization, other_admin)

      refute enabled?(removed)
    end

    test "removal from one workspace disables the member's endpoints on that workspace's boards only",
         ctx do
      member = user_fixture()
      organization_member_fixture(ctx.organization, member)
      workspace_member_fixture(ctx.workspace, member)

      other_board =
        ctx.org_admin
        |> board_fixture()
        |> put_in_workspace(org_workspace_fixture(ctx.organization))

      grant(ctx.board, member, :modify)
      grant(other_board, member, :modify)
      removed = endpoint(ctx.board, member)
      kept = endpoint(other_board, member)

      assert {:ok, _} = Workspaces.remove_member(ctx.org_admin, ctx.workspace, member)

      refute enabled?(removed)
      assert enabled?(kept)
    end
  end

  describe "account deletion" do
    test "deleting your own account disables your endpoints on boards that outlive you" do
      owner = user_fixture()
      board = board_fixture(owner)
      leaver = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, leaver, :modify, owner)
      leavers = endpoint(board, leaver)

      assert {:ok, _} =
               leaver
               |> Scope.for_user()
               |> Accounts.delete_own_account(valid_user_password(), "delete my account")

      refute enabled?(leavers)
    end

    test "a site admin deleting a user disables their endpoints" do
      board = board_fixture(user_fixture())
      user = user_fixture()
      theirs = endpoint(board, user)

      assert {:ok, _} = Accounts.delete_user(user, admin_fixture())

      refute enabled?(theirs)
    end
  end
end
