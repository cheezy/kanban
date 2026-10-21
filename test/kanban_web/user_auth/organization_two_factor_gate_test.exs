defmodule KanbanWeb.UserAuth.OrganizationTwoFactorGateTest do
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Organizations
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy
  alias Kanban.Repo
  alias KanbanWeb.UserAuth.OrganizationTwoFactorGate

  @day 24 * 60 * 60

  setup do
    org = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(org, admin, :org_admin)
    member = user_fixture()
    organization_member_fixture(org, member)

    %{org: org, admin: admin, member: member}
  end

  defp require!(admin),
    do: SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})

  defp overdue!(org) do
    past = :second |> DateTime.utc_now() |> DateTime.add(-30 * @day, :second)

    from(p in SecurityPolicy, where: p.organization_id == ^org.id)
    |> Repo.update_all(set: [two_factor_enforced_at: past])

    from(m in Kanban.Organizations.OrganizationMember, where: m.organization_id == ^org.id)
    |> Repo.update_all(set: [inserted_at: past])
  end

  defp scope(user) do
    user
    |> Scope.for_user()
    |> Scope.put_organization_membership(Organizations.get_membership(user))
  end

  defp socket(scope) do
    %Phoenix.LiveView.Socket{
      router: KanbanWeb.Router,
      assigns: %{__changed__: %{}, current_scope: scope, flash: %{}},
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
    }
  end

  defp gate_conn(user, session \\ %{}) do
    build_conn()
    |> init_test_session(session)
    |> fetch_flash()
    |> assign(:current_scope, user && scope(user))
    |> OrganizationTwoFactorGate.call(OrganizationTwoFactorGate.init([]))
  end

  describe "evaluate/2" do
    test "is :ok without a member, without a policy, with SSO and once enrolled",
         %{admin: admin, member: member} do
      assert OrganizationTwoFactorGate.evaluate(nil, false) == :ok
      assert nil |> Scope.for_user() |> OrganizationTwoFactorGate.evaluate(false) == :ok
      assert member |> scope() |> OrganizationTwoFactorGate.evaluate(false) == :ok
      assert user_fixture() |> scope() |> OrganizationTwoFactorGate.evaluate(false) == :ok

      {:ok, _} = require!(admin)

      assert {:grace, %DateTime{}} =
               member |> scope() |> OrganizationTwoFactorGate.evaluate(false)

      assert member |> scope() |> OrganizationTwoFactorGate.evaluate(true) == :ok

      Kanban.TwoFactorHelpers.enroll(member)
      assert member |> scope() |> OrganizationTwoFactorGate.evaluate(false) == :ok
    end
  end

  describe "the plug" do
    test "marks the scope during grace and redirects once overdue",
         %{org: org, admin: admin, member: member} do
      {:ok, _} = require!(admin)

      conn = gate_conn(member)
      refute conn.halted
      assert %DateTime{} = conn.assigns.current_scope.two_factor_deadline

      overdue!(org)
      conn = gate_conn(member)
      assert conn.halted
      assert redirected_to(conn) == OrganizationTwoFactorGate.redirect_path()

      conn = gate_conn(member, %{OrganizationTwoFactorGate.sso_session_key() => true})
      refute conn.halted
      assert conn.assigns.current_scope.two_factor_deadline == nil
    end

    test "passes a visitor and a user outside any Organization untouched" do
      refute gate_conn(nil).halted
      refute gate_conn(user_fixture()).halted
    end

    test "only the literal true session value counts as SSO", %{
      org: org,
      admin: admin,
      member: member
    } do
      {:ok, _} = require!(admin)
      overdue!(org)

      assert gate_conn(member, %{OrganizationTwoFactorGate.sso_session_key() => "true"}).halted
    end
  end

  describe "on_mount" do
    test ":enforce halts an overdue member and marks one in grace", %{
      org: org,
      admin: admin,
      member: member
    } do
      {:ok, _} = require!(admin)

      assert {:cont, socket} =
               OrganizationTwoFactorGate.on_mount(:enforce, %{}, %{}, socket(scope(member)))

      assert %DateTime{} = socket.assigns.current_scope.two_factor_deadline

      overdue!(org)

      assert {:halt, socket} =
               OrganizationTwoFactorGate.on_mount(:enforce, %{}, %{}, socket(scope(member)))

      assert {:redirect, %{to: "/users/settings?section=two_factor"}} = socket.redirected

      assert {:cont, _socket} =
               OrganizationTwoFactorGate.on_mount(
                 :enforce,
                 %{},
                 %{"sso_authenticated" => true},
                 socket(scope(member))
               )
    end

    test ":banner never redirects and shows the passed deadline", %{
      org: org,
      admin: admin,
      member: member
    } do
      {:ok, _} = require!(admin)
      overdue!(org)

      assert {:cont, socket} =
               OrganizationTwoFactorGate.on_mount(:banner, %{}, %{}, socket(scope(member)))

      assert socket.redirected == nil
      deadline = socket.assigns.current_scope.two_factor_deadline
      assert DateTime.compare(deadline, DateTime.utc_now()) == :lt

      assert {:cont, socket} =
               OrganizationTwoFactorGate.on_mount(
                 :banner,
                 %{},
                 %{},
                 socket(scope(user_fixture()))
               )

      assert socket.assigns.current_scope.two_factor_deadline == nil
    end
  end

  describe "recheck_params/3" do
    test "redirects once the deadline shown at mount has passed and the member is overdue",
         %{org: org, admin: admin, member: member} do
      {:ok, _} = require!(admin)
      overdue!(org)
      past = DateTime.add(DateTime.utc_now(), -1, :second)
      socket = socket(%{scope(member) | two_factor_deadline: past})

      assert {:halt, socket} = OrganizationTwoFactorGate.recheck_params(%{}, "/boards", socket)
      assert {:redirect, %{to: "/users/settings?section=two_factor"}} = socket.redirected
    end

    test "clears the banner when the member enrolled in the meantime, and does nothing before the deadline",
         %{admin: admin, member: member} do
      {:ok, _} = require!(admin)
      Kanban.TwoFactorHelpers.enroll(member)
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      assert {:cont, socket} =
               OrganizationTwoFactorGate.recheck_params(
                 %{},
                 "/boards",
                 socket(%{scope(member) | two_factor_deadline: past})
               )

      assert socket.assigns.current_scope.two_factor_deadline == nil

      future = DateTime.add(DateTime.utc_now(), @day, :second)
      scoped = socket(%{scope(member) | two_factor_deadline: future})
      assert {:cont, ^scoped} = OrganizationTwoFactorGate.recheck_params(%{}, "/boards", scoped)
    end
  end
end
