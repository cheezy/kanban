defmodule Kanban.ApiTokens.DeniedAuditTest do
  @moduledoc """
  The refused-gate audit rows carry the token's Organization and are throttled
  per token and gate (G442 exploratory finding 6). The throttle is
  `Kanban.RateLimit`, which the test environment turns off, so these tests turn
  it on and are not async.
  """
  use Kanban.DataCase, async: false

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures

  alias Kanban.ApiTokens
  alias Kanban.ApiTokens.ApiToken
  alias Kanban.ApiTokens.DeniedAudit
  alias Kanban.AuditLog.AuditEvent
  alias Kanban.Boards.Board

  setup do
    original = Application.get_env(:kanban, Kanban.RateLimit)
    Application.put_env(:kanban, Kanban.RateLimit, enabled: true)
    on_exit(fn -> Application.put_env(:kanban, Kanban.RateLimit, original) end)

    organization = organization_fixture()
    admin = user_fixture()
    organization_member_fixture(organization, admin, :org_admin)
    workspace = org_workspace_fixture(organization)

    {:ok, {workspace_token, _}} =
      ApiTokens.create_workspace_api_token(admin, workspace, %{name: "Fleet"})

    board = ai_optimized_board_fixture(admin)
    move_board(board, workspace)
    {:ok, {board_token, _}} = ApiTokens.create_api_token(admin, Repo.reload!(board), %{name: "B"})

    %{
      organization: organization,
      admin: admin,
      workspace: workspace,
      workspace_token: preload(workspace_token),
      board_token: preload(board_token)
    }
  end

  describe "organization_id/1" do
    test "is the workspace's Organization for a workspace token", ctx do
      assert DeniedAudit.organization_id(ctx.workspace_token) == ctx.organization.id

      unloaded = %ApiToken{workspace_id: ctx.workspace.id}
      assert DeniedAudit.organization_id(unloaded) == ctx.organization.id
    end

    test "is the board's workspace's Organization for a board token", ctx do
      assert DeniedAudit.organization_id(ctx.board_token) == ctx.organization.id
    end

    test "is nil for a board outside any Organization, and without a token" do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      {:ok, {token, _}} = ApiTokens.create_api_token(user, board, %{name: "Personal"})

      assert token |> preload() |> DeniedAudit.organization_id() == nil
      assert DeniedAudit.organization_id(%ApiToken{board: nil, workspace_id: nil}) == nil
      assert DeniedAudit.organization_id(nil) == nil
    end
  end

  describe "record/3" do
    test "writes a row linked to the token's Organization", ctx do
      assert DeniedAudit.record(ctx.workspace_token, ctx.admin.id, :api_board_selector) == :ok

      assert [event] = rows(ctx.admin)
      assert event.organization_id == ctx.organization.id
      assert event.metadata["gate"] == "api_board_selector"

      assert [%{id: id}] =
               Kanban.AuditLog.list_events(
                 organization_id: ctx.organization.id,
                 action: :permission_denied
               )

      assert id == event.id
    end

    test "writes one row per token and gate in a window", ctx do
      attach_telemetry([:kanban, :rate_limit, :denied])

      for _ <- 1..5 do
        DeniedAudit.record(ctx.workspace_token, ctx.admin.id, :api_board_selector)
      end

      assert length(rows(ctx.admin)) == 1
      assert_receive {:telemetry_event, _, _, %{surface: :api_denied_audit}}

      # Another gate and another token each get their own row.
      DeniedAudit.record(ctx.workspace_token, ctx.admin.id, :api_board_read)
      DeniedAudit.record(ctx.board_token, ctx.admin.id, :api_board_read)
      DeniedAudit.record(ctx.board_token, ctx.admin.id, :api_board_read)

      assert rows(ctx.admin) |> Enum.map(& &1.metadata["gate"]) |> Enum.frequencies() == %{
               "api_board_selector" => 1,
               "api_board_read" => 2
             }
    end

    test "writes every row when the throttle is off", ctx do
      Application.put_env(:kanban, Kanban.RateLimit, enabled: false)

      for _ <- 1..3, do: DeniedAudit.record(ctx.board_token, ctx.admin.id, :api_board_read)

      assert length(rows(ctx.admin)) == 3
    end

    test "writes a row without a token, unthrottled and without an Organization", ctx do
      for _ <- 1..2, do: DeniedAudit.record(nil, ctx.admin.id, :api_board_read)

      assert [%{organization_id: nil}, %{organization_id: nil}] = rows(ctx.admin)
    end
  end

  defp rows(user) do
    from(e in AuditEvent,
      where: e.action == "permission_denied" and e.actor_user_id == ^user.id,
      order_by: e.id
    )
    |> Repo.all()
  end

  defp preload(token), do: Repo.preload(token, [:board, :workspace])

  defp move_board(board, workspace) do
    {1, _} =
      from(b in Board, where: b.id == ^board.id)
      |> Repo.update_all(set: [workspace_id: workspace.id])
  end
end
