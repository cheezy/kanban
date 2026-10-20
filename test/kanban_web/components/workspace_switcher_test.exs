defmodule KanbanWeb.WorkspaceSwitcherTest do
  # Not async: some tests switch plan enforcement on for the VM.
  use KanbanWeb.ConnCase, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.PlansHelpers

  alias Kanban.Accounts.Scope
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Workspaces.Workspace
  alias KanbanWeb.SideNav
  alias KanbanWeb.WorkspaceSwitcher

  defp member_scope(workspaces, current) do
    user_fixture()
    |> Scope.for_user()
    |> Scope.put_organization_membership(%OrganizationMember{role: :member})
    |> Map.put(:workspaces, workspaces)
    |> Scope.put_workspace(current)
  end

  defp render_nav(scope) do
    assigns = %{current_scope: scope}

    rendered_to_string(~H"""
    <SideNav.side_nav current_scope={@current_scope} />
    """)
  end

  test "lists the Organization's workspaces as forms posting to /workspace/switch with a CSRF token" do
    alpha = %Workspace{id: 11, name: "Alpha", personal: false}
    beta = %Workspace{id: 12, name: "Beta", personal: false}

    html = render_nav(member_scope([alpha, beta], beta))

    assert html =~ ~s(<form action="/workspace/switch" method="post" id="workspace-switch-11">)
    assert html =~ ~s(<form action="/workspace/switch" method="post" id="workspace-switch-12">)
    assert [_, _] = Regex.scan(~r/name="_csrf_token"/, html)
    assert html =~ ~s(name="workspace_id" value="11")
    assert html =~ ~r/title="Beta" aria-current="true"/
    refute html =~ ~r/title="Alpha" aria-current/
    assert html =~ ~r/data-workspace-current title="Beta"/
    assert html =~ ~s(href="/workspace/settings")
  end

  test "truncates a long workspace name with an ellipsis and keeps the full name as a title" do
    long = String.duplicate("Very long workspace name ", 6)
    workspace = %Workspace{id: 21, name: long, personal: false}

    html = render_nav(member_scope([workspace], workspace))

    assert html =~ "text-overflow: ellipsis"
    assert html =~ ~s(title="#{long}")
  end

  test "an Organization member with no workspaces sees a prompt and no settings link" do
    html = render_nav(member_scope([], nil))

    assert html =~ "No workspaces yet"
    assert html =~ "Choose a workspace"
    refute html =~ ~s(href="/workspace/settings")
  end

  test "a user without an Organization sees the locked slot while plans are enforced" do
    enforce_plans()
    html = render_nav(Scope.for_user(user_fixture()))

    assert html =~ ~s(id="workspace-switcher-locked")
    assert html =~ ~s(data-locked-feature="workspaces")
    refute html =~ ~s(id="workspace-switcher")
  end

  test "a user without an Organization sees nothing while plans are not enforced" do
    html = render_nav(Scope.for_user(user_fixture()))

    refute html =~ "workspace-switcher"
    refute html =~ "data-locked-feature"
  end

  test "mode/1 covers every scope shape" do
    assert [] |> member_scope(nil) |> WorkspaceSwitcher.mode() == :list
    assert user_fixture() |> Scope.for_user() |> WorkspaceSwitcher.mode() == :none
    assert WorkspaceSwitcher.mode(nil) == :none

    enforce_plans()
    assert user_fixture() |> Scope.for_user() |> WorkspaceSwitcher.mode() == :locked
  end
end
