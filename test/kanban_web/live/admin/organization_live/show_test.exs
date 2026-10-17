defmodule KanbanWeb.Admin.OrganizationLive.ShowTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo
  alias KanbanWeb.Admin.OrganizationLive.Show

  defp register_and_log_in_admin(%{conn: conn}) do
    admin = admin_fixture()
    %{conn: log_in_user(conn, admin), user: admin}
  end

  defp demote_in_db(admin), do: {:ok, _} = Accounts.update_user_type(admin, :user)

  defp disable_in_db(user) do
    user
    |> User.disabled_changeset(DateTime.utc_now(:second))
    |> Repo.update!()
  end

  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp membership(user), do: Repo.get_by(OrganizationMember, user_id: user.id)

  defp submit_appoint(view, params) do
    view
    |> form("#appoint-org-admin-form", params)
    |> render_submit()
  end

  defp appoint(view, email), do: submit_appoint(view, appoint: %{email: email})

  defp remove(view, user) do
    view
    |> element("#remove-org-admin-#{user.id}")
    |> render_click()
  end

  describe "access control" do
    test "a regular user is redirected", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      organization = organization_fixture()

      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/admin/organizations/#{organization}")

      assert flash["error"] =~ "admin"
    end

    test "an org-admin of the Organization who is not a site admin is redirected", %{conn: conn} do
      org_admin = user_fixture()
      organization = organization_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)

      assert {:error, {:redirect, %{to: "/"}}} =
               live(log_in_user(conn, org_admin), ~p"/admin/organizations/#{organization}")
    end

    test "an unauthenticated visitor is redirected to the login page" do
      organization = organization_fixture()

      assert {:error, {:redirect, %{to: to}}} =
               live(Phoenix.ConnTest.build_conn(), ~p"/admin/organizations/#{organization}")

      assert to == ~p"/users/log-in"
    end

    test "the route is in live_session :admin and the LiveView re-declares the admin hook" do
      info = Phoenix.Router.route_info(KanbanWeb.Router, "GET", "/admin/organizations/1", "")

      assert {Show, :show, _opts, %{name: :admin}} = info.phoenix_live_view

      assert {KanbanWeb.UserAuth, :require_admin} in Enum.map(
               Show.__live__().lifecycle.mount,
               & &1.id
             )
    end
  end

  describe "unknown and malformed ids" do
    setup :register_and_log_in_admin

    test "an org-admin of the Organization demoted from site admin is not shown it" do
      admin = admin_fixture()
      organization = organization_fixture()
      organization_member_fixture(organization, admin, :org_admin)
      demote_in_db(admin)

      # The router's on_mount refuses a demoted admin before the LiveView mounts,
      # so handle_params/3's own re-read is reached only by calling it directly.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_scope: Kanban.Accounts.Scope.for_user(admin)
        }
      }

      assert {:noreply, socket} =
               Show.handle_params(%{"id" => to_string(organization.id)}, "", socket)

      refute Map.has_key?(socket.assigns, :organization)
      assert {:live, :redirect, %{to: "/admin/organizations"}} = socket.redirected
    end

    test "an unknown id redirects to the list with a flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/organizations", flash: flash}}} =
               live(conn, ~p"/admin/organizations/999999999")

      assert flash["error"] == "Organization not found."
    end

    for bad_id <- ["abc", "1x", "0", "-1", "99999999999999999999"] do
      test "the malformed id #{inspect(bad_id)} redirects to the list", %{conn: conn} do
        assert {:error, {:live_redirect, %{to: "/admin/organizations"}}} =
                 live(conn, "/admin/organizations/#{unquote(bad_id)}")
      end
    end
  end

  describe "details and members" do
    setup :register_and_log_in_admin

    test "shows the details, the org-admins and the members with their roles", %{conn: conn} do
      organization =
        organization_fixture(%{
          name: "Acme Widgets",
          address_line1: "1 Main Street",
          city: "Toronto",
          country: "Canada",
          contact_name: "Ada Lovelace",
          contact_phone: "+1 416 555 0100",
          contact_email: "ada@acme.test"
        })

      org_admin = user_fixture(%{email: "boss@acme.test"})
      member = user_fixture(%{email: "worker@acme.test"})
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization, member, :member)

      {:ok, view, html} = live(conn, ~p"/admin/organizations/#{organization}")

      assert html =~ "Acme Widgets"
      assert has_element?(view, "#organization-address-line1", "1 Main Street")
      assert has_element?(view, "#organization-location", "Toronto, Canada")
      assert has_element?(view, "#organization-contact-name", "Ada Lovelace")
      assert has_element?(view, "#organization-contact-phone", "+1 416 555 0100")
      assert has_element?(view, "#organization-contact-email", "ada@acme.test")

      assert has_element?(view, "#member-#{org_admin.id}", "boss@acme.test")
      assert has_element?(view, "#member-role-#{org_admin.id}", "Org-admin")
      assert has_element?(view, "#member-#{member.id}", "worker@acme.test")
      assert has_element?(view, "#member-role-#{member.id}", "Member")
    end

    test "the details are read-only and link to the edit form", %{conn: conn} do
      organization = organization_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      assert has_element?(
               view,
               ~s|#edit-organization[href="/admin/organizations/#{organization.id}/edit"]|
             )

      refute has_element?(view, "#organization-details input")
    end

    test "only org-admin rows have a Remove control, and nothing promotes or deletes",
         %{conn: conn} do
      organization = organization_fixture()
      org_admin = user_fixture()
      member = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization, member, :member)

      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      assert has_element?(view, "#remove-org-admin-#{org_admin.id}[data-confirm]")
      refute has_element?(view, "#remove-org-admin-#{member.id}")
      refute has_element?(view, "#member-#{member.id} button")
      refute has_element?(view, ~s|[phx-click="delete"]|)
      refute has_element?(view, ~s|[phx-click="promote"]|)

      # The member table's only event is Remove.
      events =
        Regex.scan(~r/phx-click="([^"]+)"/, render(element(view, "#members")),
          capture: :all_but_first
        )

      assert events |> List.flatten() |> Enum.uniq() == ["remove"]
    end

    test "an Organization with no members shows an empty state", %{conn: conn} do
      organization = organization_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      assert has_element?(view, "#members-empty")
      refute has_element?(view, "#members")
    end

    test "missing optional details render a placeholder", %{conn: conn} do
      organization = organization_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      assert has_element?(view, "#organization-location", "—")
      assert has_element?(view, "#organization-contact-phone", "—")
    end
  end

  describe "appoint event" do
    setup :register_and_log_in_admin

    test "appoints an existing user without sending any email", %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")
      flush_emails()

      html = appoint(view, "  #{String.upcase(user.email)} ")

      assert html =~ "Org-admin appointed."
      assert %OrganizationMember{role: :org_admin} = membership(user)
      assert has_element?(view, "#member-role-#{user.id}", "Org-admin")
      assert_no_email_sent()
      # The form is reset after a successful appointment.
      refute has_element?(view, ~s|#appoint-org-admin-form input[value="#{user.email}"]|)
    end

    test "promotes a member of this Organization", %{conn: conn} do
      organization = organization_fixture()
      member = user_fixture()
      organization_member_fixture(organization, member, :member)
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      appoint(view, member.email)

      assert %OrganizationMember{role: :org_admin} = membership(member)
      assert has_element?(view, "#member-role-#{member.id}", "Org-admin")
    end

    test "provisions an account for an unknown email and sends both emails", %{conn: conn} do
      organization = organization_fixture()
      email = unique_user_email()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")
      flush_emails()

      html = appoint(view, email)

      assert html =~ "Org-admin appointed."
      user = Accounts.get_user_by_email(email)
      assert %User{confirmed_at: nil} = user
      assert %OrganizationMember{role: :org_admin} = membership(user)
      assert has_element?(view, "#member-#{user.id}", email)

      assert_email_sent(fn sent ->
        assert sent.subject == "Confirm your Stride account"
        assert [{_name, ^email}] = sent.to
        assert sent.html_body =~ "/users/confirm/"
      end)

      assert_email_sent(fn sent ->
        assert sent.subject == "Reset your Stride password"
        assert [{_name, ^email}] = sent.to
        assert sent.html_body =~ "/users/reset-password/"
      end)
    end

    test "refuses a user in another Organization and changes nothing", %{conn: conn} do
      organization = organization_fixture()
      other = organization_fixture()
      user = user_fixture()
      organization_member_fixture(other, user, :member)
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      html = appoint(view, user.email)

      assert html =~ "That user already belongs to another Organization."
      assert %OrganizationMember{organization_id: other_id, role: :member} = membership(user)
      assert other_id == other.id
      refute has_element?(view, "#member-#{user.id}")
    end

    test "refuses a disabled user and changes nothing", %{conn: conn} do
      organization = organization_fixture()
      user = disable_in_db(user_fixture())
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")
      flush_emails()

      html = appoint(view, user.email)

      assert html =~ "That account is disabled."
      assert membership(user) == nil
      assert_no_email_sent()
    end

    test "refuses an invalid email, creates no account and keeps the input", %{conn: conn} do
      organization = organization_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")
      flush_emails()
      user_count = Repo.aggregate(User, :count)

      html = appoint(view, "not-an-email")

      assert html =~ "Enter a valid email address."
      assert Repo.aggregate(User, :count) == user_count
      assert has_element?(view, ~s|#appoint-org-admin-form input[value="not-an-email"]|)
      assert_no_email_sent()
    end

    test "a payload without the email is treated as an invalid email", %{conn: conn} do
      organization = organization_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")
      user_count = Repo.aggregate(User, :count)

      html = render_submit(view, "appoint", %{"something" => "else"})

      assert html =~ "Enter a valid email address."
      assert Repo.aggregate(User, :count) == user_count
    end

    test "an admin demoted after mount is refused and nothing is written",
         %{conn: conn, user: admin} do
      organization = organization_fixture()
      user = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      demote_in_db(admin)
      html = appoint(view, user.email)

      assert html =~ "You must be an admin to perform this action."
      assert membership(user) == nil
    end

    test "an admin disabled after mount is refused and no account is created",
         %{conn: conn, user: admin} do
      organization = organization_fixture()
      email = unique_user_email()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      disable_in_db(admin)
      html = appoint(view, email)

      assert html =~ "You must be an admin to perform this action."
      assert Accounts.get_user_by_email(email) == nil
    end

    test "re-reads the Organization, redirecting when it no longer exists", %{conn: conn} do
      organization = organization_fixture()
      user = user_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      Repo.delete!(organization)
      appoint(view, user.email)

      assert {"/admin/organizations", flash} = assert_redirect(view)
      assert flash["error"] == "Organization not found."
      assert membership(user) == nil
    end
  end

  describe "remove event" do
    setup :register_and_log_in_admin

    test "removes an org-admin after confirmation", %{conn: conn} do
      organization = organization_fixture()
      first = user_fixture()
      second = user_fixture()
      organization_member_fixture(organization, first, :org_admin)
      organization_member_fixture(organization, second, :org_admin)
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      html = remove(view, first)

      assert html =~ "Org-admin removed."
      assert membership(first) == nil
      refute has_element?(view, "#member-#{first.id}")
      assert has_element?(view, "#member-#{second.id}")
    end

    test "refuses to remove the last org-admin while members remain", %{conn: conn} do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      organization_member_fixture(organization, user_fixture(), :member)
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      html = remove(view, org_admin)

      assert html =~ "You cannot remove the last org-admin"
      assert %OrganizationMember{role: :org_admin} = membership(org_admin)
      assert has_element?(view, "#member-#{org_admin.id}")
    end

    test "removes the last org-admin of an Organization with no other members",
         %{conn: conn} do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      remove(view, org_admin)

      assert membership(org_admin) == nil
      assert has_element?(view, "#members-empty")
    end

    test "a stale row clicked twice reports the org-admin is gone", %{conn: conn} do
      organization = organization_fixture()
      first = user_fixture()
      organization_member_fixture(organization, first, :org_admin)
      organization_member_fixture(organization, user_fixture(), :org_admin)
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      remove(view, first)
      html = render_click(view, "remove", %{"user-id" => to_string(first.id)})

      assert html =~ "That person is no longer an org-admin of this Organization."
    end

    test "a site admin who is an org-admin elsewhere can remove themselves only there",
         %{conn: conn, user: admin} do
      here = organization_fixture()
      elsewhere = organization_fixture()
      organization_member_fixture(elsewhere, admin, :org_admin)
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{here}")

      html = render_click(view, "remove", %{"user-id" => to_string(admin.id)})

      assert html =~ "That person is no longer an org-admin of this Organization."
      assert %OrganizationMember{role: :org_admin} = membership(admin)
      assert membership(admin).organization_id == elsewhere.id
    end

    for bad_id <- ["abc", "0", "99999999999999999999", "999999999"] do
      test "the unknown or malformed user id #{inspect(bad_id)} is reported, not raised",
           %{conn: conn} do
        organization = organization_fixture()
        {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

        html = render_click(view, "remove", %{"user-id" => unquote(bad_id)})

        assert html =~ "That person is no longer an org-admin of this Organization."
      end
    end

    test "a payload without a user id is reported, not raised", %{conn: conn} do
      organization = organization_fixture()
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      assert render_click(view, "remove", %{}) =~
               "That person is no longer an org-admin of this Organization."
    end

    test "an admin disabled after mount is refused and nothing is removed",
         %{conn: conn, user: admin} do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      disable_in_db(admin)
      html = remove(view, org_admin)

      assert html =~ "You must be an admin to perform this action."
      assert %OrganizationMember{role: :org_admin} = membership(org_admin)
    end

    test "an admin demoted after mount is refused and nothing is removed",
         %{conn: conn, user: admin} do
      organization = organization_fixture()
      org_admin = user_fixture()
      organization_member_fixture(organization, org_admin, :org_admin)
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}")

      demote_in_db(admin)
      remove(view, org_admin)

      assert %OrganizationMember{role: :org_admin} = membership(org_admin)
    end
  end

  describe "appoint_error_message/1" do
    test "maps :not_found to the generic message, not the Remove wording" do
      assert Show.appoint_error_message(:not_found) == "Something went wrong. Please try again."
      refute Show.appoint_error_message(:not_found) == Show.error_message(:not_found)
    end

    test "maps every other refusal as error_message/1 does" do
      for reason <- [:unauthorized, :already_in_another_organization, :user_disabled, :other] do
        assert Show.appoint_error_message(reason) == Show.error_message(reason)
      end
    end
  end

  describe "error_message/1" do
    test "maps every refusal to a specific message" do
      assert Show.error_message(:unauthorized) == "You must be an admin to perform this action."

      assert Show.error_message(:already_in_another_organization) =~
               "already belongs to another Organization"

      assert Show.error_message(:user_disabled) =~ "That account is disabled."
      assert Show.error_message(:last_org_admin) =~ "You cannot remove the last org-admin"
      assert Show.error_message(:not_found) =~ "no longer an org-admin"
    end

    test "maps an email changeset to the invalid-email message" do
      changeset = Accounts.change_user_registration(%User{}, %{email: "nope"})
      changeset = %{changeset | action: :insert}

      assert Show.error_message(changeset) == "Enter a valid email address. Nothing was changed."
    end

    test "maps any other changeset or reason to the generic message" do
      changeset =
        %User{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:name, "bad")

      assert Show.error_message(changeset) == "Something went wrong. Please try again."
      assert Show.error_message(:something_else) == "Something went wrong. Please try again."
    end

    test "the context's refusals all have a message other than the generic one" do
      for reason <- [:already_in_another_organization, :user_disabled, :last_org_admin] do
        refute Show.error_message(reason) == Show.error_message(:something_else)
      end
    end
  end
end
