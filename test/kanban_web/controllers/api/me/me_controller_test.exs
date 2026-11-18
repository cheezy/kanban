defmodule KanbanWeb.API.Me.MeControllerTest do
  # async: false - some tests switch the global :plans_enforced application env
  # on, and the parallel-request test needs the shared sandbox.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.DevicesFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.Accounts
  alias Kanban.ApiTokens
  alias Kanban.Devices.Device
  alias Kanban.Organizations.OrganizationMember
  alias Kanban.Repo

  setup do
    user = user_fixture()
    {:ok, user} = Accounts.update_user_name(user, %{name: "Ada Lovelace"})
    scope = user_scope_fixture(user)
    {device, issued} = device_with_tokens_fixture(scope, %{name: "Ada's iPhone"})

    %{user: user, scope: scope, device: device, access_token: issued.access_token}
  end

  defp get_me(token, headers \\ []) do
    headers
    |> Enum.reduce(build_conn(), fn {name, value}, conn -> put_req_header(conn, name, value) end)
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(~p"/api/me")
  end

  defp member_of_org(user, role \\ :member) do
    organization = organization_fixture(%{name: "Analytical Engines"})
    organization_member_fixture(organization, user, role)
    workspace = org_workspace_fixture(organization, %{name: "Research"})
    workspace_member_fixture(workspace, user)
    %{organization: organization, workspace: workspace}
  end

  describe "GET /api/me" do
    test "returns the person, workspaces, limits and device", ctx do
      %{organization: organization, workspace: workspace} = member_of_org(ctx.user)

      data = ctx.access_token |> get_me() |> json_response(200) |> Map.fetch!("data")

      assert Map.keys(data) |> Enum.sort() ==
               ~w(app_unlocked device limits min_app_versions organization user workspaces)

      assert data["user"] == %{
               "id" => ctx.user.id,
               "display_name" => "Ada Lovelace",
               "initials" => "AL"
             }

      assert data["organization"] == %{
               "id" => organization.id,
               "name" => "Analytical Engines",
               "role" => "member"
             }

      assert data["workspaces"] == [
               %{"id" => workspace.id, "name" => "Research", "slug" => workspace.slug}
             ]

      assert data["app_unlocked"] == true
      assert data["limits"] == %{"phone_max_files" => 10, "phone_max_lines" => 500}

      assert %{"ios" => %{"min_version" => _, "store_url" => _}, "android" => %{}} =
               data["min_app_versions"]

      device = data["device"]

      assert Map.keys(device) |> Enum.sort() ==
               ~w(app_version device_class id last_seen_at model name os_version platform signed_in_at)

      assert device["id"] == ctx.device.id
      assert device["name"] == "Ada's iPhone"
      assert device["platform"] == "ios"
      assert device["device_class"] == "phone"
      assert is_binary(device["last_seen_at"])

      # Secrets and contact data never leave the server.
      body = Jason.encode!(data)
      refute body =~ "approval_public_key"
      refute body =~ "push_token"
      refute body =~ "token_hash"
      refute body =~ "contact_"
      refute body =~ ctx.access_token
    end

    test "uses the email as the display name when the person has no name", ctx do
      user = user_fixture()
      {_device, issued} = device_with_tokens_fixture(user_scope_fixture(user))

      user_json =
        issued.access_token |> get_me() |> json_response(200) |> get_in(["data", "user"])

      assert user_json["display_name"] == user.email
      assert user_json["initials"] =~ ~r/\A[A-Z0-9]{1,2}\z/
      assert ctx.user.id != user.id
    end

    test "app_unlocked is false for a free user when plans are enforced", ctx do
      enforce_plans()

      data = ctx.access_token |> get_me() |> json_response(200) |> Map.fetch!("data")

      assert data["app_unlocked"] == false
      assert data["organization"] == nil
      assert data["workspaces"] == []
    end

    test "app_unlocked is true for an Organization member when plans are enforced", ctx do
      enforce_plans()
      member_of_org(ctx.user, :org_admin)

      data = ctx.access_token |> get_me() |> json_response(200) |> Map.fetch!("data")

      assert data["app_unlocked"] == true
      assert data["organization"]["role"] == "org_admin"
    end

    test "a user removed from the Organization after sign-in loses it on the next request",
         ctx do
      %{organization: organization} = member_of_org(ctx.user)
      assert get_me(ctx.access_token) |> json_response(200) |> get_in(["data", "organization"])

      membership =
        from m in OrganizationMember,
          where: m.user_id == ^ctx.user.id and m.organization_id == ^organization.id

      Repo.delete_all(membership)

      enforce_plans()
      data = ctx.access_token |> get_me() |> json_response(200) |> Map.fetch!("data")

      assert data["organization"] == nil
      assert data["workspaces"] == []
      assert data["app_unlocked"] == false
    end

    test "two parallel requests both update last_seen_at without error", ctx do
      results =
        [ctx.access_token, ctx.access_token]
        |> Enum.map(fn token -> Task.async(fn -> get_me(token) end) end)
        |> Task.await_many(10_000)

      for conn <- results do
        assert conn.status == 200
        assert is_binary(json_response(conn, 200)["data"]["device"]["last_seen_at"])
      end

      assert %DateTime{} = Repo.get!(Device, ctx.device.id).last_seen_at
    end

    test "answers 426 for an outdated app, before checking the token", ctx do
      conn = get_me("sdat_expired-or-unknown", [{"x-stride-app", "ios/0.0.1 (1)"}])

      assert %{"error" => "app_update_required", "store_url" => "https://" <> _} =
               json_response(conn, 426)

      current = get_me(ctx.access_token, [{"x-stride-app", "ios/1.0.0 (42)"}])
      assert json_response(current, 200)["data"]["user"]["id"] == ctx.user.id
    end

    test "refuses an agent API token with 401", ctx do
      {:ok, {_api_token, agent_token}} =
        ApiTokens.create_api_token(ctx.user, ai_optimized_board_fixture(ctx.user), %{
          name: "Agent"
        })

      assert json_response(get_me(agent_token), 401) == %{"error" => "Invalid access token"}
    end

    test "answers 401 without a token" do
      conn = get(build_conn(), ~p"/api/me")

      assert json_response(conn, 401) == %{"error" => "Missing or invalid Authorization header"}
    end
  end
end
