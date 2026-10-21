defmodule Kanban.SSO.OIDCDeadlineTest do
  # async: false: the test shortens the global Kanban.SSO.OIDC deadline.
  use Kanban.DataCase, async: false

  import Kanban.OrganizationsFixtures
  import Kanban.SSOFixtures

  alias Kanban.OIDCTestHelpers
  alias Kanban.SSO.OIDC

  setup do
    settings = Application.get_env(:kanban, OIDC, [])
    Application.put_env(:kanban, OIDC, Keyword.put(settings, :deadline_ms, 200))
    on_exit(fn -> Application.put_env(:kanban, OIDC, settings) end)
    %{connection: oidc_connection_fixture(organization_fixture())}
  end

  test "a provider slower than the deadline is reported unreachable", %{connection: connection} do
    Req.Test.stub(OIDC, fn conn ->
      Process.sleep(2_000)
      Req.Test.json(conn, OIDCTestHelpers.discovery())
    end)

    {micros, result} = :timer.tc(fn -> OIDC.fetch_provider(connection) end)

    assert result == {:error, :provider_unreachable}
    assert micros < 1_500_000
  end

  test "a provider inside the deadline still answers", %{connection: connection} do
    OIDCTestHelpers.stub_idp(OIDCTestHelpers.signing_key(), fn _form -> %{} end)
    assert {:ok, _provider} = OIDC.fetch_provider(connection)
  end
end
