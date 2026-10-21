defmodule KanbanWeb.SCIM.DiscoveryControllerTest do
  @moduledoc "The SCIM discovery endpoints (W2247)."
  use KanbanWeb.ConnCase, async: true

  import Kanban.OrganizationsFixtures
  import Kanban.SCIMFixtures

  setup %{conn: conn} do
    {_token, plaintext} = scim_token_fixture(organization_fixture())
    %{conn: put_req_header(conn, "authorization", "Bearer " <> plaintext)}
  end

  defp scim_json(conn, status) do
    assert conn.status == status
    assert ["application/scim+json" <> _] = get_resp_header(conn, "content-type")
    Jason.decode!(conn.resp_body)
  end

  test "ServiceProviderConfig states what is supported", %{conn: conn} do
    config = scim_json(get(conn, ~p"/scim/v2/ServiceProviderConfig"), 200)
    assert config["patch"]["supported"] == true
    assert config["filter"]["supported"] == true
    assert config["bulk"]["supported"] == false
    assert config["changePassword"]["supported"] == false
    assert [%{"type" => "oauthbearertoken"}] = config["authenticationSchemes"]
  end

  test "ResourceTypes and Schemas list Users and Groups", %{conn: conn} do
    types = scim_json(get(conn, ~p"/scim/v2/ResourceTypes"), 200)
    assert types["Resources"] |> Enum.map(& &1["id"]) |> Enum.sort() == ["Group", "User"]
    assert scim_json(get(conn, ~p"/scim/v2/ResourceTypes/User"), 200)["endpoint"] == "/Users"
    assert scim_json(get(conn, ~p"/scim/v2/ResourceTypes/Nope"), 404)

    schemas = scim_json(get(conn, ~p"/scim/v2/Schemas"), 200)
    assert schemas["totalResults"] == 2
    [schema | _] = schemas["Resources"]
    assert scim_json(get(conn, ~p"/scim/v2/Schemas/#{schema["id"]}"), 200)["id"] == schema["id"]
  end

  test "discovery needs a token too" do
    assert scim_json(get(build_conn(), ~p"/scim/v2/ServiceProviderConfig"), 401)
  end
end
