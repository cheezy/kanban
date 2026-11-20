defmodule Kanban.Devices.SsoExemptionTest do
  @moduledoc """
  The web gate's single sign-on exemption from an Organization's two-factor
  requirement, carried to a device (decided 2026-11-19): recorded on the
  authorization code at Allow, copied onto the device at the exchange, and
  re-checked against the member's current Organization at every refresh.
  """
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Devices
  alias Kanban.Devices.Device
  alias Kanban.Devices.DeviceToken
  alias Kanban.Devices.SsoExemption
  alias Kanban.Organizations
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Organizations.SecurityPolicies
  alias Kanban.Organizations.SecurityPolicy

  doctest Kanban.Devices.SsoExemption

  @t0 ~U[2026-11-18 12:00:00Z]
  @overdue_since_days 30

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)
  defp days(n), do: DateTime.add(@t0, n, :day)

  # An Organization requiring two-factor whose requirement started `since`,
  # with a member who has not turned it on and joined then too.
  defp requiring_organization(since) do
    org = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(org, admin, :org_admin)
    {:ok, _} = SecurityPolicies.update_policy(admin, %{"require_two_factor" => "true"})

    from(p in SecurityPolicy, where: p.organization_id == ^org.id)
    |> Repo.update_all(set: [two_factor_enforced_at: since])

    org
  end

  defp add_member(org, user, since) do
    organization_member_fixture(org, user)

    from(m in OrganizationMember, where: m.organization_id == ^org.id and m.user_id == ^user.id)
    |> Repo.update_all(set: [inserted_at: since])
  end

  defp member_scope(user) do
    user
    |> Scope.for_user()
    |> Scope.put_organization_membership(Organizations.get_membership(user))
  end

  # Allow, then the token exchange: the path a real device takes, with the
  # web session's single sign-on mark handed to Allow.
  defp sign_in_device(user, sso_mark) do
    code = authorization_code_fixture_with_mark(member_scope(user), sso_mark)

    grant = %{
      code: code.code,
      client_id: code.client_id,
      redirect_uri: code.redirect_uri,
      code_verifier: valid_code_verifier()
    }

    details = %{
      "platform" => "ios",
      "device_class" => "phone",
      "approval_public_key" => valid_approval_public_key()
    }

    {:ok, issued} = Devices.exchange_authorization_code(grant, details, at(1))
    issued
  end

  defp authorization_code_fixture_with_mark(scope, sso_mark) do
    {:ok, code} =
      Devices.create_authorization_code(
        scope,
        valid_authorization_code_attributes(),
        @t0,
        sso_mark: sso_mark
      )

    code
  end

  defp unused?(plain),
    do: is_nil(Repo.get_by!(DeviceToken, token_hash: DeviceToken.hash_token(plain)).used_at)

  describe "authorized_organization_id/2" do
    test "is the mark only when it names the scope's own Organization" do
      org = organization_fixture()
      user = user_fixture()
      organization_member_fixture(org, user)
      scope = member_scope(user)

      assert SsoExemption.authorized_organization_id(scope, org.id) == org.id
      assert SsoExemption.authorized_organization_id(scope, organization_fixture().id) == nil
      assert SsoExemption.authorized_organization_id(scope, nil) == nil
      assert SsoExemption.authorized_organization_id(scope, Integer.to_string(org.id)) == nil
      assert SsoExemption.authorized_organization_id(scope, true) == nil
    end

    test "is nil for a scope without a membership or without a scope" do
      assert SsoExemption.authorized_organization_id(user_scope_fixture(), 1) == nil
      assert SsoExemption.authorized_organization_id(nil, 1) == nil
    end
  end

  describe "the mark through Allow and the exchange" do
    test "an SSO session's mark is recorded on the code and copied onto the device" do
      org = organization_fixture()
      user = user_fixture()
      organization_member_fixture(org, user)

      code = authorization_code_fixture_with_mark(member_scope(user), org.id)
      assert code.sso_organization_id == org.id

      issued = sign_in_device(user, org.id)
      assert Repo.get!(Device, issued.device.id).sso_organization_id == org.id
    end

    test "a password session, or another Organization's mark, records nothing" do
      org = organization_fixture()
      user = user_fixture()
      organization_member_fixture(org, user)

      assert authorization_code_fixture_with_mark(member_scope(user), nil).sso_organization_id ==
               nil

      other = organization_fixture()

      assert authorization_code_fixture_with_mark(member_scope(user), other.id).sso_organization_id ==
               nil

      issued = sign_in_device(user, other.id)
      assert Repo.get!(Device, issued.device.id).sso_organization_id == nil
    end

    test "the mark is never cast from the code or device attributes" do
      org = organization_fixture()
      user = user_fixture()
      organization_member_fixture(org, user)
      scope = member_scope(user)

      {:ok, code} =
        Devices.create_authorization_code(
          scope,
          valid_authorization_code_attributes(%{sso_organization_id: org.id}),
          @t0
        )

      assert code.sso_organization_id == nil

      device = device_fixture(scope, %{sso_organization_id: org.id}, @t0)
      assert Repo.get!(Device, device.id).sso_organization_id == nil
    end
  end

  describe "refresh after the grace period" do
    setup do
      org = requiring_organization(days(-@overdue_since_days))
      user = user_fixture()
      add_member(org, user, days(-@overdue_since_days))
      %{org: org, user: user}
    end

    test "an SSO-authorized device refreshes", %{org: org, user: user} do
      issued = sign_in_device(user, org.id)

      assert {:ok, rotated} = Devices.rotate_refresh_token(issued.refresh_token, at(60))
      # Each refresh re-checks, and keeps passing while it holds.
      assert {:ok, _again} = Devices.rotate_refresh_token(rotated.refresh_token, at(120))
    end

    test "a password-authorized device is refused and keeps its token", %{user: user} do
      issued = sign_in_device(user, nil)

      assert Devices.rotate_refresh_token(issued.refresh_token, at(60)) ==
               {:error, :invalid_token}

      assert unused?(issued.refresh_token)
      assert is_nil(Repo.get!(Device, issued.device.id).revoked_at)
    end

    test "an SSO-authorized device is refused once its Organization stops exempting it", %{
      org: org,
      user: user
    } do
      issued = sign_in_device(user, org.id)
      assert {:ok, rotated} = Devices.rotate_refresh_token(issued.refresh_token, at(60))

      # The member leaves the Organization whose single sign-on signed the
      # device in and joins another that requires two-factor, where they are
      # overdue: the web session's mark no longer exempts them, nor does the
      # device's.
      from(m in OrganizationMember, where: m.user_id == ^user.id) |> Repo.delete_all()
      other = requiring_organization(days(-@overdue_since_days))
      add_member(other, user, days(-@overdue_since_days))

      assert Devices.rotate_refresh_token(rotated.refresh_token, at(120)) ==
               {:error, :invalid_token}

      assert unused?(rotated.refresh_token)
    end
  end

  describe "refresh during the grace period" do
    test "an SSO-authorized and a password-authorized device both refresh" do
      org = requiring_organization(@t0)
      sso_user = user_fixture()
      password_user = user_fixture()
      add_member(org, sso_user, @t0)
      add_member(org, password_user, @t0)

      sso = sign_in_device(sso_user, org.id)
      password = sign_in_device(password_user, nil)

      assert {:ok, _} = Devices.rotate_refresh_token(sso.refresh_token, at(60))
      assert {:ok, _} = Devices.rotate_refresh_token(password.refresh_token, at(60))
    end
  end

  describe "two_factor_refused?/3" do
    test "follows the member's Organization as it is now" do
      org = requiring_organization(days(-@overdue_since_days))
      user = user_fixture()
      add_member(org, user, days(-@overdue_since_days))

      refute SsoExemption.two_factor_refused?(user, org.id, @t0)
      assert SsoExemption.two_factor_refused?(user, nil, @t0)
      assert SsoExemption.two_factor_refused?(user, organization_fixture().id, @t0)

      # Outside any Organization there is no requirement at all.
      refute SsoExemption.two_factor_refused?(user_fixture(), nil, @t0)
    end
  end
end
