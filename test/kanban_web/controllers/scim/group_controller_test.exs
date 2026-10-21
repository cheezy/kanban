defmodule KanbanWeb.SCIM.GroupControllerTest do
  @moduledoc "The SCIM `/Groups` endpoints (W2247): the Organization's workspaces."
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.SCIMFixtures
  import Kanban.WorkspacesFixtures

  alias Kanban.Repo
  alias Kanban.Workspaces.WorkspaceMember

  @patch_schema "urn:ietf:params:scim:api:messages:2.0:PatchOp"

  setup %{conn: conn} do
    organization = organization_fixture()
    {_token, plaintext} = scim_token_fixture(organization)
    workspace = org_workspace_fixture(organization)
    member = user_fixture()
    organization_member_fixture(organization, member)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> plaintext)
      |> put_req_header("content-type", "application/scim+json")

    %{conn: conn, organization: organization, workspace: workspace, member: member}
  end

  defp scim_json(conn, status) do
    assert conn.status == status
    assert ["application/scim+json" <> _] = get_resp_header(conn, "content-type")
    Jason.decode!(conn.resp_body)
  end

  defp members_op(op, ids) do
    %{
      "schemas" => [@patch_schema],
      "Operations" => [
        %{"op" => op, "path" => "members", "value" => Enum.map(ids, &%{"value" => "#{&1}"})}
      ]
    }
  end

  test "lists and reads the Organization's workspaces as Groups", ctx do
    list = scim_json(get(ctx.conn, ~p"/scim/v2/Groups"), 200)
    assert list["totalResults"] == 1
    assert [%{"id" => id, "displayName" => name, "members" => []}] = list["Resources"]
    assert id == "#{ctx.workspace.id}"
    assert name == ctx.workspace.name

    lean = scim_json(get(ctx.conn, ~p"/scim/v2/Groups?#{%{excludedAttributes: "members"}}"), 200)
    refute lean["Resources"] |> hd() |> Map.has_key?("members")

    shown = scim_json(get(ctx.conn, ~p"/scim/v2/Groups/#{ctx.workspace.id}"), 200)
    assert shown["meta"]["resourceType"] == "Group"
  end

  test "PATCH adds and removes members", ctx do
    conn =
      patch(ctx.conn, ~p"/scim/v2/Groups/#{ctx.workspace.id}", members_op("add", [ctx.member.id]))

    assert response(conn, 204) == ""
    assert Repo.get_by(WorkspaceMember, workspace_id: ctx.workspace.id, user_id: ctx.member.id)

    shown = scim_json(get(ctx.conn, ~p"/scim/v2/Groups/#{ctx.workspace.id}"), 200)
    assert [%{"value" => value, "display" => display}] = shown["members"]
    assert value == "#{ctx.member.id}"
    assert display == ctx.member.email

    remove = %{
      "schemas" => [@patch_schema],
      "Operations" => [%{"op" => "Remove", "path" => ~s(members[value eq "#{ctx.member.id}"])}]
    }

    assert response(patch(ctx.conn, ~p"/scim/v2/Groups/#{ctx.workspace.id}", remove), 204)
    refute Repo.get_by(WorkspaceMember, workspace_id: ctx.workspace.id, user_id: ctx.member.id)
  end

  test "PATCH refuses an outsider with invalidValue", ctx do
    outsider = user_fixture()

    conn =
      patch(ctx.conn, ~p"/scim/v2/Groups/#{ctx.workspace.id}", members_op("add", [outsider.id]))

    assert scim_json(conn, 400)["scimType"] == "invalidValue"
  end

  test "creating, replacing and deleting Groups is refused", ctx do
    assert scim_json(post(ctx.conn, ~p"/scim/v2/Groups", %{"displayName" => "x"}), 403)
    assert scim_json(put(ctx.conn, ~p"/scim/v2/Groups/#{ctx.workspace.id}", %{}), 403)
    assert scim_json(delete(ctx.conn, ~p"/scim/v2/Groups/#{ctx.workspace.id}"), 403)
  end

  test "another Organization's workspace is not found", ctx do
    other = org_workspace_fixture(organization_fixture())
    assert scim_json(get(ctx.conn, ~p"/scim/v2/Groups/#{other.id}"), 404)
    assert scim_json(patch(ctx.conn, ~p"/scim/v2/Groups/#{other.id}", members_op("add", [])), 404)
  end
end
