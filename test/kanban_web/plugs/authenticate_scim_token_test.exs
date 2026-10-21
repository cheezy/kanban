defmodule KanbanWeb.Plugs.AuthenticateScimTokenTest do
  @moduledoc """
  `KanbanWeb.Plugs.AuthenticateScimToken` (W2247): only an active SCIM token
  reaches `/scim/v2`, and a SCIM token reaches nothing else.
  """
  # async: false because one test enables the rate limiter globally.
  use KanbanWeb.ConnCase, async: false

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.SCIMFixtures

  alias Kanban.ApiTokens
  alias Kanban.AuditLog
  alias Kanban.SCIM

  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  defp with_bearer(conn, value), do: put_req_header(conn, "authorization", value)

  defp assert_unauthorized(conn) do
    assert conn.status == 401
    assert ["application/scim+json" <> _] = get_resp_header(conn, "content-type")
    assert [~s(Bearer realm="SCIM")] = get_resp_header(conn, "www-authenticate")
    body = Jason.decode!(conn.resp_body)
    assert body["schemas"] == [@error_schema]
    assert body["status"] == "401"
    body
  end

  test "an active token is accepted", %{conn: conn} do
    {_token, plaintext} = scim_token_fixture(organization_fixture())
    assert get(with_bearer(conn, "Bearer " <> plaintext), ~p"/scim/v2/Users").status == 200

    assert get(with_bearer(build_conn(), "bearer " <> plaintext), ~p"/scim/v2/Users").status ==
             200
  end

  test "missing, malformed, unknown and revoked tokens get the same 401", %{conn: conn} do
    organization = organization_fixture()
    org_admin = user_fixture()
    organization_member_fixture(organization, org_admin, :org_admin)
    {token, plaintext} = scim_token_fixture(organization)
    {:ok, _} = SCIM.revoke_token(org_admin, organization.id, token.id)

    bodies =
      for header <- [
            nil,
            "Basic abc",
            "Bearer ",
            "Bearer stride_scim_unknown",
            "Bearer " <> plaintext
          ] do
        conn = if header, do: with_bearer(build_conn(), header), else: conn
        conn |> get(~p"/scim/v2/Users") |> assert_unauthorized()
      end

    assert bodies |> Enum.uniq() |> length() == 1

    reasons = AuditLog.list_events(action: :scim_auth_failed) |> Enum.map(& &1.metadata["reason"])
    assert "missing_token" in reasons
    assert "revoked" in reasons
    assert "not_found" in reasons
    events = AuditLog.list_events(action: :scim_auth_failed)
    refute Enum.any?(events, &(inspect(&1) =~ plaintext))
  end

  test "a board API token is not a SCIM token, and a SCIM token is not an API token" do
    user = user_fixture()

    {:ok, {_token, api_plain}} =
      ApiTokens.create_api_token(user, board_fixture(user), %{
        name: "Agent",
        agent_model: "claude",
        agent_version: "v1",
        agent_purpose: "work"
      })

    assert_unauthorized(
      get(with_bearer(build_conn(), "Bearer " <> api_plain), ~p"/scim/v2/Users")
    )

    {_token, scim_plain} = scim_token_fixture(organization_fixture())
    assert get(with_bearer(build_conn(), "Bearer " <> scim_plain), ~p"/api/tasks").status == 401
  end

  describe "with the rate limiter enabled" do
    setup do
      original = Application.get_env(:kanban, Kanban.RateLimit)
      Application.put_env(:kanban, Kanban.RateLimit, enabled: true)
      on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)
      :ok
    end

    test "repeated failures with one token are refused with 429 and retry-after" do
      ip = {10, 77, :rand.uniform(255), :rand.uniform(255)}
      presented = "Bearer stride_scim_bad#{System.unique_integer([:positive])}"

      for _ <- 1..10 do
        conn =
          %{build_conn() | remote_ip: ip} |> with_bearer(presented) |> get(~p"/scim/v2/Users")

        assert conn.status == 401
      end

      conn = %{build_conn() | remote_ip: ip} |> with_bearer(presented) |> get(~p"/scim/v2/Users")
      assert conn.status == 429
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
      assert Jason.decode!(conn.resp_body)["status"] == "429"

      # A different, valid token from the same address still gets through.
      {_token, plaintext} = scim_token_fixture(organization_fixture())
      conn = %{build_conn() | remote_ip: ip} |> with_bearer("Bearer " <> plaintext)
      assert get(conn, ~p"/scim/v2/Users").status == 200
    end
  end
end
