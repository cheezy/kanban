defmodule KanbanWeb.UserLive.SettingsSSOLockTest do
  @moduledoc """
  The settings page's single sign-on section while paid plans are enforced:
  a user without an Organization sees the `:sso` lock, an Organization member
  sees the section itself.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use KanbanWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers

  setup :enforce_plans

  test "a user without an Organization sees the single sign-on lock", %{conn: conn} do
    {:ok, lv, _html} = live(log_in_user(conn, user_fixture()), ~p"/users/settings?section=sso")

    assert has_element?(lv, "#sso #sso-locked")
    refute has_element?(lv, "#sso-not-linked")
  end

  test "an Organization member sees the section, not the lock", %{conn: conn} do
    user = user_fixture()
    organization_member_fixture(organization_fixture(), user)

    {:ok, lv, _html} = live(log_in_user(conn, user), ~p"/users/settings?section=sso")

    assert has_element?(lv, "#sso-not-linked")
    refute has_element?(lv, "#sso-locked")
  end
end
