defmodule Kanban.Workspaces.CurrentTest do
  # Not async: some tests switch plan enforcement on for the VM.
  use Kanban.DataCase, async: false

  import Ecto.Query, only: [where: 3]
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.Workspaces.Current
  alias Kanban.Workspaces.Workspace

  defp grant(board, user, access) do
    %BoardUser{}
    |> BoardUser.changeset(%{board_id: board.id, user_id: user.id, access: access})
    |> Repo.insert!()
  end

  defp scope(user) do
    user
    |> Scope.for_user()
    |> Scope.put_organization_membership(Organizations.get_membership(user))
  end

  setup do
    organization = organization_fixture()
    member = user_fixture()
    organization_member_fixture(organization, member, :member)
    alpha = org_workspace_fixture(organization, name: "Alpha")
    beta = org_workspace_fixture(organization, name: "Beta")
    workspace_member_fixture(alpha, member, :member)
    workspace_member_fixture(beta, member, :guest)

    %{organization: organization, member: member, alpha: alpha, beta: beta}
  end

  describe "put_current/2" do
    test "uses a reachable session id and lists the switcher workspaces", ctx do
      scope = ctx.member |> scope() |> Current.put_current(ctx.beta.id)

      assert scope.workspace.id == ctx.beta.id
      assert Enum.map(scope.workspaces, & &1.id) == [ctx.alpha.id, ctx.beta.id]

      assert (ctx.member |> scope() |> Current.put_current("#{ctx.beta.id}")).workspace.id ==
               ctx.beta.id
    end

    test "falls back to the first workspace for a missing, stale, foreign, archived, personal or garbage id",
         ctx do
      foreign = org_workspace_fixture(organization_fixture())
      archived = org_workspace_fixture(ctx.organization, archived_at: DateTime.utc_now(:second))
      workspace_member_fixture(archived, ctx.member, :member)
      personal = personal_workspace_fixture(ctx.member)
      removed = org_workspace_fixture(ctx.organization, name: "Removed")

      for id <- [nil, foreign.id, archived.id, personal.id, removed.id, "abc", -3, %{}] do
        assert (ctx.member |> scope() |> Current.put_current(id)).workspace.id == ctx.alpha.id
      end
    end

    test "a workspace archived after it was chosen falls back", ctx do
      ctx.beta |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()

      scope = ctx.member |> scope() |> Current.put_current(ctx.beta.id)

      assert scope.workspace.id == ctx.alpha.id
      refute Enum.any?(scope.workspaces, &(&1.id == ctx.beta.id))
    end

    test "archiving hides a workspace and clearing archived_at restores it", ctx do
      ctx.beta |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update!()

      refute Enum.any?(
               Current.put_current(scope(ctx.member), nil).workspaces,
               &(&1.id == ctx.beta.id)
             )

      Repo.get!(Workspace, ctx.beta.id)
      |> Ecto.Changeset.change(archived_at: nil)
      |> Repo.update!()

      assert Enum.any?(
               Current.put_current(scope(ctx.member), nil).workspaces,
               &(&1.id == ctx.beta.id)
             )
    end

    test "a member of an Organization with no reachable workspaces gets none" do
      lonely = user_fixture()
      organization_member_fixture(organization_fixture(), lonely, :member)

      scope = lonely |> scope() |> Current.put_current(nil)

      assert scope.workspace == nil
      assert scope.workspaces == []
    end

    test "a user without an Organization gets none, with no query", ctx do
      free = user_fixture()
      base = scope(free)
      parent = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:kanban, :repo, :query],
        fn _, _, _, _ -> if self() == parent, do: send(parent, :query) end,
        nil
      )

      scope = Current.put_current(base, ctx.alpha.id)
      :telemetry.detach(handler)

      assert scope.workspace == nil
      assert scope.workspaces == []
      refute_received :query
    end

    test "an org-admin's list holds every unarchived workspace of their Organization", ctx do
      admin = user_fixture()
      organization_member_fixture(ctx.organization, admin, :org_admin)
      unjoined = org_workspace_fixture(ctx.organization, name: "Gamma")

      scope = admin |> scope() |> Current.put_current(unjoined.id)

      assert scope.workspace.id == unjoined.id
      assert length(scope.workspaces) == 3
    end
  end

  describe "switchable/2" do
    test "accepts a reachable, unarchived org workspace", ctx do
      assert {:ok, workspace} = ctx.member |> scope() |> Current.switchable(ctx.beta.id)
      assert workspace.id == ctx.beta.id
    end

    test "refuses archived, personal, foreign, unreachable and garbage ids", ctx do
      foreign = org_workspace_fixture(organization_fixture())
      archived = org_workspace_fixture(ctx.organization, archived_at: DateTime.utc_now(:second))
      workspace_member_fixture(archived, ctx.member, :member)
      unjoined = org_workspace_fixture(ctx.organization)
      personal = personal_workspace_fixture(ctx.member)

      for id <- [foreign.id, archived.id, unjoined.id, personal.id, "abc", nil] do
        assert ctx.member |> scope() |> Current.switchable(id) == :error
      end

      assert Current.switchable(nil, ctx.alpha.id) == :error
    end

    test "refuses a user without paid access whether or not plans are enforced", ctx do
      free = user_fixture()
      assert free |> scope() |> Current.switchable(ctx.alpha.id) == :error

      enforce_plans()
      assert free |> scope() |> Current.switchable(ctx.alpha.id) == :error
      assert {:ok, _} = ctx.member |> scope() |> Current.switchable(ctx.alpha.id)
    end
  end

  describe "group_boards/2" do
    test "is nil without a current workspace", ctx do
      assert Current.group_boards([], Scope.for_user(ctx.member)) == nil
    end

    test "splits boards into the workspace, personal and other shared groups", ctx do
      in_alpha = board_fixture(user_fixture())

      {1, _} =
        Board
        |> where([b], b.id == ^in_alpha.id)
        |> Repo.update_all(set: [workspace_id: ctx.alpha.id])

      grant(in_alpha, ctx.member, :read_only)

      personal = board_fixture(ctx.member)
      shared = board_fixture(user_fixture())

      grant(shared, ctx.member, :modify)

      backfilled = ctx.member |> personal_workspace_fixture() |> place_board_in_workspace()

      scope = ctx.member |> scope() |> Current.put_current(ctx.alpha.id)
      groups = ctx.member |> Boards.list_boards() |> Current.group_boards(scope)

      assert Enum.map(groups.workspace, & &1.id) == [in_alpha.id]
      assert Enum.map(groups.personal, & &1.id) == [personal.id]
      assert Enum.map(groups.shared, & &1.id) == [shared.id]

      refute Enum.any?(
               groups.workspace ++ groups.personal ++ groups.shared,
               &(&1.id == backfilled.id)
             )
    end
  end
end
