defmodule KanbanWeb.WorkspaceSessionControllerTest do
  # Not async: some tests switch plan enforcement on for the VM.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.WorkspacesFixtures

  @refusal "That workspace is not available."

  setup %{conn: conn} do
    organization = organization_fixture()
    member = user_fixture()
    organization_member_fixture(organization, member, :member)
    alpha = org_workspace_fixture(organization, name: "Alpha")
    beta = org_workspace_fixture(organization, name: "Beta")
    workspace_member_fixture(alpha, member, :member)
    workspace_member_fixture(beta, member, :member)

    %{
      conn: log_in_user(conn, member),
      organization: organization,
      member: member,
      alpha: alpha,
      beta: beta
    }
  end

  test "stores a reachable workspace and redirects to /boards, which then uses it", ctx do
    conn = post(ctx.conn, ~p"/workspace/switch", %{"workspace_id" => ctx.beta.id})

    assert redirected_to(conn) == ~p"/boards"
    assert get_session(conn, :current_workspace_id) == ctx.beta.id

    conn = conn |> recycle() |> get(~p"/boards")
    assert conn.assigns.current_scope.workspace.id == ctx.beta.id
    assert html_response(conn, 200) =~ ~s(id="workspace-boards")
  end

  test "refuses another Organization's, an archived, a personal and an unknown workspace",
       ctx do
    foreign = org_workspace_fixture(organization_fixture())
    archived = org_workspace_fixture(ctx.organization, archived_at: DateTime.utc_now(:second))
    workspace_member_fixture(archived, ctx.member, :member)
    personal = personal_workspace_fixture(ctx.member)

    for id <- [foreign.id, archived.id, personal.id, 999_999_999, "abc"] do
      conn = post(ctx.conn, ~p"/workspace/switch", %{"workspace_id" => id})

      assert redirected_to(conn) == ~p"/boards"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == @refusal
      assert get_session(conn, :current_workspace_id) == nil
    end
  end

  test "refuses a request without a workspace id", ctx do
    conn = post(ctx.conn, ~p"/workspace/switch", %{})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) == @refusal
    assert get_session(conn, :current_workspace_id) == nil
  end

  test "refuses a free user while plans are enforced and while they are not",
       %{conn: conn} = ctx do
    free_conn = log_in_user(conn, user_fixture())

    conn = post(free_conn, ~p"/workspace/switch", %{"workspace_id" => ctx.alpha.id})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == @refusal
    assert get_session(conn, :current_workspace_id) == nil

    enforce_plans()
    conn = post(free_conn, ~p"/workspace/switch", %{"workspace_id" => ctx.alpha.id})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == @refusal
    assert get_session(conn, :current_workspace_id) == nil
  end

  test "keeps the previous workspace when a later switch is refused", ctx do
    conn = post(ctx.conn, ~p"/workspace/switch", %{"workspace_id" => ctx.beta.id})
    foreign = org_workspace_fixture(organization_fixture())

    conn =
      conn
      |> recycle()
      |> post(~p"/workspace/switch", %{"workspace_id" => foreign.id})

    assert get_session(conn, :current_workspace_id) == ctx.beta.id
  end

  test "requires a signed-in user", ctx do
    conn = post(build_conn(), ~p"/workspace/switch", %{"workspace_id" => ctx.alpha.id})

    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
