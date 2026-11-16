defmodule KanbanWeb.WorkspaceLive.SettingsLocalTimeTest do
  @moduledoc """
  Pins the local, localised dates of the workspace settings cards (W2733):
  the Tokens, Invitations and Export sections render every stored UTC instant
  in the viewer's timezone and UI language, and no "UTC" literal.
  """
  use KanbanWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens.ApiToken
  alias Kanban.Repo
  alias Kanban.Workspaces.Export.WorkspaceExport
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Invitations

  setup %{conn: conn} do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    workspace = org_workspace_fixture(organization, name: "Platform")

    %{conn: conn, org_admin: org_admin, workspace: workspace}
  end

  # The session keys are set before the workspace switch, whose response
  # writes the whole session (timezone and locale included) into the cookie
  # the recycled conn carries.
  defp settings_view(ctx, section, session) do
    conn =
      ctx.conn
      |> log_in_user(ctx.org_admin)
      |> Plug.Test.init_test_session(session)
      |> post(~p"/workspace/switch", %{"workspace_id" => ctx.workspace.id})
      |> recycle()

    {:ok, view, _html} = live(conn, ~p"/workspace/settings?section=#{section}")
    view
  end

  defp create_token(ctx) do
    view = settings_view(ctx, "tokens", %{})

    view
    |> form("#workspace-token-form",
      token: %{name: "Fleet", agent_capabilities: "code_generation"}
    )
    |> render_submit()

    from(t in ApiToken, where: t.workspace_id == ^ctx.workspace.id) |> Repo.one!()
  end

  # 03:00 UTC on 1 January, which is still 31 December in Toronto.
  defp new_year_utc(year), do: year |> Date.new!(1, 1) |> DateTime.new!(~T[03:00:00], "Etc/UTC")

  describe "tokens" do
    test "created, last-used and expiry dates render local and localised", ctx do
      token = create_token(ctx)
      expires_year = DateTime.utc_now().year + 1

      {1, _} =
        from(t in ApiToken, where: t.id == ^token.id)
        |> Repo.update_all(
          set: [
            inserted_at: ~U[2026-03-01 02:00:00Z],
            last_used_at: ~U[2026-03-01 02:00:00Z],
            expires_at: new_year_utc(expires_year)
          ]
        )

      view = settings_view(ctx, "tokens", %{"timezone" => "America/Toronto", "locale" => "es"})
      row = view |> element("#workspace-token-#{token.id}") |> render()

      # 02:00 UTC on 1 March is the evening of 28 February in Toronto.
      assert row =~ "28 feb 2026"
      refute row =~ "2026-03-01"
      assert row =~ "31 dic #{expires_year - 1}"
      refute row =~ "UTC"
    end

    test "a token never used shows the localised never label", ctx do
      token = create_token(ctx)

      view = settings_view(ctx, "tokens", %{"locale" => "de"})

      assert has_element?(view, "#workspace-token-#{token.id}", "nie")
    end
  end

  describe "invitations" do
    test "the expiry date shifts to the viewer's local day", ctx do
      {:ok, invitation} =
        Invitations.invite_to_workspace(
          ctx.org_admin,
          ctx.workspace,
          %{
            "email" => "guest-#{System.unique_integer([:positive])}@example.test",
            "role" => "guest"
          },
          &"https://example.test/invitations/#{&1}"
        )

      expires_year = DateTime.utc_now().year + 1
      expires_at = new_year_utc(expires_year)

      {1, _} =
        from(i in Invitation, where: i.id == ^invitation.id)
        |> Repo.update_all(set: [expires_at: expires_at])

      view =
        settings_view(ctx, "invitations", %{"timezone" => "America/Toronto", "locale" => "en"})

      assert has_element?(
               view,
               "#invitation-expiry-#{invitation.id}",
               "Expires Dec 31, #{expires_year - 1}"
             )
    end
  end

  describe "export" do
    test "requested and expiry times render local and without UTC", ctx do
      view = settings_view(ctx, "export", %{})
      render_click(view, "request_export", %{})
      export = Repo.one!(WorkspaceExport)

      {1, _} =
        from(e in WorkspaceExport, where: e.id == ^export.id)
        |> Repo.update_all(set: [inserted_at: ~U[2026-10-01 09:00:00Z]])

      view = settings_view(ctx, "export", %{"timezone" => "America/Toronto"})
      row = view |> element("#workspace-export-#{export.id}") |> render()

      assert row =~ "October 1, 2026 at 5:00 AM"
      refute row =~ "UTC"
    end
  end
end
