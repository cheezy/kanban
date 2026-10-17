defmodule KanbanWeb.Admin.OrganizationLive.FormTest do
  use KanbanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures

  alias Kanban.Accounts
  alias Kanban.Accounts.User
  alias Kanban.Organizations.Organization
  alias Kanban.Repo
  alias KanbanWeb.Admin.OrganizationLive.Form

  @valid_attrs %{
    "name" => "Acme Widgets",
    "address_line1" => "1 Main Street",
    "address_line2" => "Suite 200",
    "city" => "Toronto",
    "region" => "Ontario",
    "postal_code" => "M5V 2T6",
    "country" => "Canada",
    "contact_name" => "Ada Lovelace",
    "contact_phone" => "+1 416 555 0100",
    "contact_email" => "ada@acme.test"
  }

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

  defp organization_count, do: Repo.aggregate(Organization, :count)

  # A push_navigate carries its flash signed; this is the same decode
  # Phoenix.LiveViewTest applies to a plain redirect's flash.
  defp decode_flash(token), do: Phoenix.LiveView.Utils.verify_flash(@endpoint, token)

  describe "access control" do
    test "a regular user is redirected from the new form", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:error, {:redirect, %{to: "/", flash: flash}}} =
               live(conn, ~p"/admin/organizations/new")

      assert flash["error"] =~ "admin"
    end

    test "a regular user is redirected from the edit form", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      organization = organization_fixture()

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, ~p"/admin/organizations/#{organization}/edit")
    end

    test "an unauthenticated visitor is redirected to the login page" do
      conn = Phoenix.ConnTest.build_conn()

      assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/admin/organizations/new")
      assert to == ~p"/users/log-in"
    end
  end

  describe "new" do
    setup :register_and_log_in_admin

    test "renders every field", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/organizations/new")

      assert html =~ "New Organization"

      for field <- ~w(name address_line1 address_line2 city region postal_code country
                      contact_name contact_phone contact_email) do
        assert has_element?(view, "#organization-form [name='organization[#{field}]']")
      end

      refute has_element?(view, ~s|[phx-click="delete"]|)
    end

    test "creates an Organization and redirects to its detail page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")

      {:error, {:live_redirect, %{to: to, flash: flash}}} =
        view
        |> form("#organization-form", organization: @valid_attrs)
        |> render_submit()

      organization = Repo.get_by!(Organization, name: "Acme Widgets")
      assert to == "/admin/organizations/#{organization.id}"
      assert decode_flash(flash)["info"] == "Organization created."
      assert organization.city == "Toronto"
      assert organization.contact_email == "ada@acme.test"
    end

    test "accepts the optional address fields left blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")

      attrs = %{"name" => "Bare Org", "contact_name" => "Pat", "contact_email" => "pat@bare.test"}

      {:error, {:live_redirect, _}} =
        view
        |> form("#organization-form", organization: attrs)
        |> render_submit()

      organization = Repo.get_by!(Organization, name: "Bare Org")
      assert organization.address_line1 == nil
      assert organization.country == nil
    end

    test "renders validation errors inline and writes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")
      before = organization_count()

      html =
        view
        |> form("#organization-form",
          organization: %{@valid_attrs | "name" => "", "contact_email" => "not an email"}
        )
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert html =~ "must have the @ sign and no spaces"
      assert html =~ "The Organization could not be saved. Check the errors below."
      assert organization_count() == before
    end

    test "validate shows errors as the admin types", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")

      html =
        view
        |> form("#organization-form", organization: %{"name" => String.duplicate("a", 161)})
        |> render_change()

      assert html =~ "should be at most 160 character(s)"
    end

    test "a save without the organization params is treated as empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")
      before = organization_count()

      html = render_hook(view, "save", %{})

      assert html =~ "The Organization could not be saved. Check the errors below."
      assert organization_count() == before
    end

    test "a non-map organization payload is treated as empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")

      html = render_hook(view, "validate", %{"organization" => "tampered"})

      assert html =~ "organization-form"
      assert organization_count() == 0
    end
  end

  describe "edit" do
    setup :register_and_log_in_admin

    test "renders the Organization's current details", %{conn: conn} do
      organization = organization_fixture(%{name: "Old Name", city: "Lyon"})

      {:ok, view, html} = live(conn, ~p"/admin/organizations/#{organization}/edit")

      assert html =~ "Edit Organization"
      assert has_element?(view, ~s|input[name="organization[name]"][value="Old Name"]|)
      assert has_element?(view, ~s|input[name="organization[city]"][value="Lyon"]|)
    end

    test "updates the Organization and redirects to its detail page", %{conn: conn} do
      organization = organization_fixture(%{name: "Old Name"})
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}/edit")

      {:error, {:live_redirect, %{to: to, flash: flash}}} =
        view
        |> form("#organization-form", organization: %{"name" => "New Name", "city" => "Paris"})
        |> render_submit()

      assert to == "/admin/organizations/#{organization.id}"
      assert decode_flash(flash)["info"] == "Organization updated."
      updated = Repo.get!(Organization, organization.id)
      assert updated.name == "New Name"
      assert updated.city == "Paris"
    end

    test "renders validation errors inline and leaves the row unchanged", %{conn: conn} do
      organization = organization_fixture(%{name: "Old Name"})
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}/edit")

      html =
        view
        |> form("#organization-form", organization: %{"name" => "  "})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      assert Repo.get!(Organization, organization.id).name == "Old Name"
    end

    test "an unknown id shows a not-found flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/admin/organizations", flash: flash}}} =
               live(conn, ~p"/admin/organizations/999999999/edit")

      assert flash["error"] == "Organization not found."
    end

    for bad_id <- ["not-an-id", "12abc", "0", "-5", "99999999999999999999"] do
      test "a malformed or out-of-range id (#{bad_id}) shows a not-found flash", %{conn: conn} do
        assert {:error, {:live_redirect, %{to: "/admin/organizations", flash: flash}}} =
                 live(conn, "/admin/organizations/#{unquote(bad_id)}/edit")

        assert flash["error"] == "Organization not found."
      end
    end
  end

  # An open socket keeps the current_scope it mounted with. These change the
  # actor in the database behind the socket and assert the save is refused.
  describe "per-event actor re-authorization (stale socket)" do
    setup :register_and_log_in_admin

    test "a demoted admin cannot create an Organization", %{conn: conn, user: admin} do
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/new")
      demote_in_db(admin)

      html =
        view
        |> form("#organization-form", organization: @valid_attrs)
        |> render_submit()

      assert html =~ "You must be an admin to perform this action."
      assert organization_count() == 0
    end

    test "a disabled admin cannot edit an Organization", %{conn: conn, user: admin} do
      organization = organization_fixture(%{name: "Old Name"})
      {:ok, view, _html} = live(conn, ~p"/admin/organizations/#{organization}/edit")
      disable_in_db(admin)

      html =
        view
        |> form("#organization-form", organization: %{"name" => "New Name"})
        |> render_submit()

      assert html =~ "You must be an admin to perform this action."
      assert Repo.get!(Organization, organization.id).name == "Old Name"
    end
  end

  describe "error_message/1" do
    test "maps :unauthorized" do
      assert Form.error_message(:unauthorized) == "You must be an admin to perform this action."
    end

    test "maps a changeset error" do
      changeset = Ecto.Changeset.change(%Organization{})

      assert Form.error_message(changeset) ==
               "The Organization could not be saved. Check the errors below."
    end

    test "falls back for any other reason" do
      assert Form.error_message(:something_else) == "Something went wrong. Please try again."
    end
  end

  describe "detail_path/1" do
    test "returns the site-admin detail path" do
      assert Form.detail_path(%Organization{id: 42}) == "/admin/organizations/42"
    end
  end
end
