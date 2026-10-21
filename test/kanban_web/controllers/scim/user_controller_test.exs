defmodule KanbanWeb.SCIM.UserControllerTest do
  @moduledoc """
  The SCIM `/Users` endpoints (W2247), driven the way Okta and Microsoft
  Entra ID drive them.
  """
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.SCIMFixtures
  import Kanban.SSOFixtures

  alias Kanban.Accounts
  alias Kanban.ApiTokens
  alias Kanban.Repo

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @patch_schema "urn:ietf:params:scim:api:messages:2.0:PatchOp"
  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  setup %{conn: conn} do
    organization = organization_fixture()
    domain = verified_domain_fixture(organization).domain
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    {_token, plaintext} = scim_token_fixture(organization, %{created_by: org_admin})

    %{conn: authed(conn, plaintext), organization: organization, domain: domain}
  end

  defp authed(conn, plaintext) do
    conn
    |> put_req_header("authorization", "Bearer " <> plaintext)
    |> put_req_header("content-type", "application/scim+json")
  end

  defp email(domain), do: "person#{System.unique_integer([:positive])}@#{domain}"

  defp scim_json(conn, status) do
    assert conn.status == status
    assert ["application/scim+json" <> _] = get_resp_header(conn, "content-type")
    Jason.decode!(conn.resp_body)
  end

  defp deactivate_body(form) do
    op =
      case form do
        :okta -> %{"op" => "replace", "value" => %{"active" => false}}
        :entra -> %{"op" => "Replace", "path" => "active", "value" => "False"}
      end

    %{"schemas" => [@patch_schema], "Operations" => [op]}
  end

  test "the Okta lifecycle: look up, create, read, deactivate, delete", ctx do
    address = email(ctx.domain)
    filter = ~s(userName eq "#{address}")

    body = scim_json(get(ctx.conn, ~p"/scim/v2/Users?#{%{filter: filter}}"), 200)
    assert body["totalResults"] == 0
    assert body["Resources"] == []

    conn =
      post(ctx.conn, ~p"/scim/v2/Users", %{
        "schemas" => [@user_schema],
        "userName" => address,
        "name" => %{"givenName" => "Ada", "familyName" => "Lovelace"},
        "externalId" => "00u1",
        "active" => true
      })

    created = scim_json(conn, 201)
    id = created["id"]
    assert [location] = get_resp_header(conn, "location")
    assert location =~ "/scim/v2/Users/#{id}"
    assert created["userName"] == address
    assert created["active"] == true
    assert created["externalId"] == "00u1"

    shown = scim_json(get(ctx.conn, ~p"/scim/v2/Users/#{id}"), 200)
    assert shown["id"] == id

    user = id |> String.to_integer() |> Accounts.get_user!()
    session = Accounts.generate_user_session_token(user)
    topic = "users_sessions:" <> Base.url_encode64(session)
    KanbanWeb.Endpoint.subscribe(topic)

    patched = scim_json(patch(ctx.conn, ~p"/scim/v2/Users/#{id}", deactivate_body(:okta)), 200)
    assert patched["active"] == false
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
    assert Repo.reload(user).disabled_at

    assert scim_json(get(ctx.conn, ~p"/scim/v2/Users/#{id}"), 200)["active"] == false

    assert response(delete(ctx.conn, ~p"/scim/v2/Users/#{id}"), 204) == ""

    error = scim_json(get(ctx.conn, ~p"/scim/v2/Users/#{id}"), 404)
    assert error["schemas"] == [@error_schema]
    assert error["status"] == "404"
  end

  test "the Entra form of deactivation and re-activation, sent as application/json", ctx do
    conn = put_req_header(ctx.conn, "content-type", "application/json")
    created = scim_json(post(conn, ~p"/scim/v2/Users", %{"userName" => email(ctx.domain)}), 201)

    assert scim_json(
             patch(conn, ~p"/scim/v2/Users/#{created["id"]}", deactivate_body(:entra)),
             200
           )[
             "active"
           ] == false

    body = %{
      "schemas" => [@patch_schema],
      "Operations" => [%{"op" => "Replace", "path" => "active", "value" => "True"}]
    }

    assert scim_json(patch(conn, ~p"/scim/v2/Users/#{created["id"]}", body), 200)["active"] ==
             true
  end

  test "PUT replaces the attributes Stride keeps", ctx do
    created =
      scim_json(post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => email(ctx.domain)}), 201)

    replaced =
      ctx.conn
      |> put(~p"/scim/v2/Users/#{created["id"]}", %{
        "userName" => created["userName"],
        "displayName" => "Grace Hopper",
        "externalId" => "ext-9",
        "active" => true
      })
      |> scim_json(200)

    assert replaced["displayName"] == "Grace Hopper"
    assert replaced["externalId"] == "ext-9"
  end

  test "a deprovisioned user's board API token stops working", ctx do
    created =
      scim_json(post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => email(ctx.domain)}), 201)

    user = created["id"] |> String.to_integer() |> Accounts.get_user!()
    board = board_fixture(user)

    {:ok, {_token, api_plain}} =
      ApiTokens.create_api_token(user, board, %{
        name: "Agent",
        agent_model: "claude",
        agent_version: "v1",
        agent_purpose: "work"
      })

    api_conn = put_req_header(build_conn(), "authorization", "Bearer " <> api_plain)
    assert get(api_conn, ~p"/api/tasks").status == 200

    scim_json(patch(ctx.conn, ~p"/scim/v2/Users/#{created["id"]}", deactivate_body(:okta)), 200)

    assert get(api_conn, ~p"/api/tasks").status == 401
  end

  test "errors use the SCIM error schema with a scimType", ctx do
    error =
      scim_json(post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => "x@unverified.example"}), 400)

    assert error["scimType"] == "invalidValue"

    error =
      scim_json(
        post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => email(ctx.domain), "active" => "False"}),
        400
      )

    assert error["scimType"] == "invalidValue"
    assert error["detail"] =~ "active"

    error = scim_json(get(ctx.conn, ~p"/scim/v2/Users?#{%{filter: "userName sw \"a\""}}"), 400)
    assert error["scimType"] == "invalidFilter"

    address = email(ctx.domain)
    scim_json(post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => address}), 201)
    error = scim_json(post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => address}), 409)
    assert error["scimType"] == "uniqueness"

    elsewhere = user_fixture(%{email: email(ctx.domain)})
    organization_member_fixture(organization_fixture(), elsewhere)
    error = scim_json(post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => elsewhere.email}), 409)
    refute error["detail"] =~ "another"
  end

  test "a site admin is not provisioned, and the refusal does not say why", ctx do
    elsewhere = user_fixture(%{email: email(ctx.domain)})
    organization_member_fixture(organization_fixture(), elsewhere)

    conflict =
      scim_json(post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => elsewhere.email}), 409)

    admin = admin_fixture(%{email: email(ctx.domain)})
    error = scim_json(post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => admin.email}), 409)

    assert error["detail"] == conflict["detail"]
    refute Kanban.Organizations.member?(admin, ctx.organization.id)
  end

  test "a malformed JSON body gets a SCIM 400", ctx do
    {400, headers, body} =
      assert_error_sent 400, fn -> post(ctx.conn, "/scim/v2/Users", "{not json") end

    assert {"content-type", "application/scim+json" <> _} =
             List.keyfind(headers, "content-type", 0)

    assert Jason.decode!(body)["schemas"] == [@error_schema]
  end

  test "another Organization's token sees none of these users", ctx do
    created =
      scim_json(post(ctx.conn, ~p"/scim/v2/Users", %{"userName" => email(ctx.domain)}), 201)

    {_other, other_plain} = scim_token_fixture(organization_fixture())
    other = authed(build_conn(), other_plain)

    assert scim_json(get(other, ~p"/scim/v2/Users/#{created["id"]}"), 404)

    assert scim_json(
             patch(other, ~p"/scim/v2/Users/#{created["id"]}", deactivate_body(:okta)),
             404
           )

    assert scim_json(delete(other, ~p"/scim/v2/Users/#{created["id"]}"), 404)
    assert scim_json(get(other, ~p"/scim/v2/Users"), 200)["totalResults"] == 0
  end
end
