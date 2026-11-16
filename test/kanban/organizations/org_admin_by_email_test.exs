defmodule Kanban.Organizations.OrgAdminByEmailTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations.OrgAdminByEmail
  alias Kanban.Organizations.OrgAdminProvisioning
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  # The caller, Kanban.Organizations.appoint_org_admin_by_email/4, validates
  # the URLs before calling appoint/4, so the tests do the same.
  defp urls do
    OrgAdminProvisioning.validate_urls!(
      confirmation_url: &"https://stride.test/users/confirm/#{&1}",
      reset_password_url: &"https://stride.test/users/reset-password/#{&1}"
    )
  end

  defp role_of(%User{id: user_id}) do
    OrganizationMember
    |> where([m], m.user_id == ^user_id)
    |> select([m], {m.organization_id, m.role})
    |> Repo.one()
  end

  defp users_with_email(email), do: from(u in User, where: u.email == ^email)

  defp email_subjects(acc \\ []) do
    receive do
      {:email, %Swoosh.Email{subject: subject}} -> email_subjects([subject | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Runs `fun` once, in the test process, right after the first query that
  # matches `match?`.
  defp after_first_query(match?, fun) do
    test_pid = self()
    handler_id = "org-admin-by-email-test-#{System.unique_integer([:positive])}"
    fired = :counters.new(1, [])

    :telemetry.attach(
      handler_id,
      [:kanban, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and :counters.get(fired, 1) == 0 and match?.(metadata) do
          :counters.add(fired, 1, 1)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp email_lookup?(%{source: "users", query: query}),
    do: String.starts_with?(query, "SELECT") and query =~ ~s|u0."email" = $1|

  defp email_lookup?(_metadata), do: false

  describe "appoint/4" do
    setup do
      %{admin: admin_fixture(), organization: organization_fixture()}
    end

    test "appoints an existing enabled account and emails it, given the Organization's id",
         ctx do
      user = user_fixture()
      email_subjects()

      assert {:ok, %OrganizationMember{role: :org_admin} = membership} =
               OrgAdminByEmail.appoint(ctx.admin, ctx.organization.id, user.email, urls())

      assert membership.user_id == user.id
      assert role_of(user) == {ctx.organization.id, :org_admin}

      assert email_subjects() == [
               "You're now an org-admin of #{ctx.organization.name} on Stride"
             ]
    end

    test "refuses a disabled account with :user_disabled and writes nothing", ctx do
      user =
        user_fixture()
        |> User.disabled_changeset(DateTime.utc_now(:second))
        |> Repo.update!()

      email_subjects()

      assert {:error, :user_disabled} =
               OrgAdminByEmail.appoint(ctx.admin, ctx.organization, user.email, urls())

      assert role_of(user) == nil
      assert email_subjects() == []
    end

    test "creates an account for an unknown email and appoints it", ctx do
      email = unique_user_email()

      assert {:ok, %OrganizationMember{role: :org_admin} = membership} =
               OrgAdminByEmail.appoint(ctx.admin, ctx.organization, email, urls())

      assert %User{} = user = Accounts.get_user_by_email(email)
      assert membership.user_id == user.id
      assert email |> users_with_email() |> Repo.aggregate(:count) == 1
    end

    test "appoints, rather than duplicates, an account registered after the lookup", ctx do
      email = unique_user_email()

      after_first_query(&email_lookup?/1, fn ->
        attrs = valid_user_attributes(email: email)
        {:ok, _user} = Accounts.register_user(attrs)
      end)

      assert {:ok, %OrganizationMember{role: :org_admin} = membership} =
               OrgAdminByEmail.appoint(ctx.admin, ctx.organization, email, urls())

      assert membership.user_id == Accounts.get_user_by_email(email).id
      assert email |> users_with_email() |> Repo.aggregate(:count) == 1
    end
  end

  describe "callers" do
    # It checks no actor, so only the facade that does may call it.
    test "only Kanban.Organizations calls appoint/4" do
      callers =
        for path <- Path.wildcard("lib/**/*.ex"),
            path != "lib/kanban/organizations/org_admin_by_email.ex",
            File.read!(path) =~ "OrgAdminByEmail",
            do: path

      assert callers == ["lib/kanban/organizations.ex"]
    end
  end
end
