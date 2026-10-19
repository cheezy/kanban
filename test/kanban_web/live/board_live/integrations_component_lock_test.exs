defmodule KanbanWeb.BoardLive.IntegrationsComponentLockTest do
  @moduledoc """
  The Integrations panel while paid plans are enforced: a free board shows
  the locked Integrations prompt and its endpoints as paused, read-only rows
  the owner can still inspect and delete, and refuses crafted write events.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use KanbanWeb.ConnCase, async: false
  use Oban.Testing, repo: Kanban.Repo

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TelemetryHelpers
  import Kanban.WebhooksFixtures
  import Kanban.WorkspacesFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Webhooks.DeliveryWorker
  alias Kanban.Webhooks.Endpoint

  @refused [:kanban, :plan, :feature_refused]
  @locked_flash "Integrations are available to organizations. Nothing was changed."
  @params %{
    "kind" => "generic",
    "url" => "https://hooks.example.com/stride/new",
    "event_types" => ["task.created"]
  }

  setup do
    Repo.delete_all(Oban.Job)
    owner = user_fixture()
    board = board_fixture(owner)
    %{owner: owner, board: board, endpoint: webhook_endpoint_fixture(board)}
  end

  defp open(conn, user, board) do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/boards/#{board}/integrations")
    view
  end

  defp target(board), do: "#board-integrations-#{board.id}"

  defp make_paid(%Board{id: id}) do
    workspace = org_workspace_fixture(organization_fixture())

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    :ok
  end

  defp endpoint_count(board), do: Endpoint |> where(board_id: ^board.id) |> Repo.aggregate(:count)

  describe "a free board under enforcement" do
    setup :enforce_plans

    test "shows the locked Integrations prompt instead of the add form", %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)

      assert has_element?(view, ~s(#integrations-locked[data-locked-feature="integrations"]))
      assert has_element?(view, ~s(#integrations-locked a[href="/locked/integrations"]))
      assert render(view) =~ "Available to organizations"
      refute has_element?(view, "form[id^=webhook-endpoint-form]")
    end

    test "shows existing endpoints as paused, read-only rows", %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)
      id = ctx.endpoint.id

      assert has_element?(view, "#webhook-endpoint-#{id} [data-endpoint-paused]", "Paused")
      assert has_element?(view, "#webhook-delete-#{id}")
      assert has_element?(view, "#webhook-log-toggle-#{id}")

      for control <- ~w(edit toggle test rotate) do
        refute has_element?(view, "#webhook-#{control}-#{id}"), "#{control} is still offered"
      end
    end

    test "hides the empty-state text when the board has no endpoints", %{conn: conn} = ctx do
      Repo.delete!(ctx.endpoint)
      view = open(conn, ctx.owner, ctx.board)

      assert has_element?(view, "#integrations-locked")
      refute has_element?(view, "[data-webhooks-empty]")
    end

    test "still lets the owner open the deliveries and delete an endpoint",
         %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)
      id = ctx.endpoint.id

      view |> element("#webhook-log-toggle-#{id}") |> render_click()
      assert has_element?(view, "#webhook-log-#{id}")

      view |> element("#webhook-delete-#{id}") |> render_click()
      assert render(view) =~ "Endpoint deleted"
      assert Repo.get(Endpoint, id) == nil
    end

    test "refuses crafted toggle, rotate and send_test events with a flash",
         %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)
      attach_telemetry(@refused)

      for event <- ~w(toggle rotate send_test) do
        view
        |> with_target(target(ctx.board))
        |> render_click(event, %{"id" => "#{ctx.endpoint.id}"})

        assert render(view) =~ @locked_flash, "#{event} was not refused"

        assert_received {:telemetry_event, @refused, %{count: 1},
                         %{feature: :integrations, surface: :live_view}}
      end

      unchanged = Repo.get!(Endpoint, ctx.endpoint.id)
      assert unchanged.enabled
      assert unchanged.encrypted_secret == ctx.endpoint.encrypted_secret
      refute has_element?(view, "#webhook-secret")
      refute_enqueued(worker: DeliveryWorker)
    end

    test "refuses crafted create and save_edit submits with a flash", %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)
      attach_telemetry(@refused)

      view |> with_target(target(ctx.board)) |> render_submit("create", %{"endpoint" => @params})
      assert render(view) =~ @locked_flash

      view
      |> with_target(target(ctx.board))
      |> render_submit("save_edit", %{
        "id" => "#{ctx.endpoint.id}",
        "endpoint_edit" => %{"event_types" => ["task.moved"]}
      })

      assert render(view) =~ @locked_flash
      assert_received {:telemetry_event, @refused, _, %{surface: :live_view}}
      assert_received {:telemetry_event, @refused, _, %{surface: :live_view}}
      assert endpoint_count(ctx.board) == 1
      assert Repo.get!(Endpoint, ctx.endpoint.id).event_types == ctx.endpoint.event_types
    end

    test "a crafted edit opens no edit form", %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)

      view
      |> with_target(target(ctx.board))
      |> render_click("edit", %{"id" => "#{ctx.endpoint.id}"})

      refute has_element?(view, "#webhook-edit-form-#{ctx.endpoint.id}")
    end

    test "translates the Paused badge", %{conn: conn} = ctx do
      conn = conn |> log_in_user(ctx.owner) |> Plug.Test.init_test_session(%{"locale" => "fr"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{ctx.board}/integrations")

      assert has_element?(view, "[data-endpoint-paused]", "En pause")
    end
  end

  describe "the lock flips while the panel is open" do
    test "a write after the board loses paid access is refused and locks the panel",
         %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)
      assert has_element?(view, "#webhook-toggle-#{ctx.endpoint.id}")

      enforce_plans()
      view |> element("#webhook-toggle-#{ctx.endpoint.id}") |> render_click()

      assert render(view) =~ @locked_flash
      assert has_element?(view, "#integrations-locked")
      assert has_element?(view, "[data-endpoint-paused]")
      assert Repo.get!(Endpoint, ctx.endpoint.id).enabled
    end
  end

  describe "a paid board or no enforcement" do
    test "a paid board under enforcement shows the normal panel", %{conn: conn} = ctx do
      enforce_plans()
      :ok = make_paid(ctx.board)
      view = open(conn, ctx.owner, ctx.board)

      refute has_element?(view, "#integrations-locked")
      refute has_element?(view, "[data-endpoint-paused]")
      assert has_element?(view, "#webhook-toggle-#{ctx.endpoint.id}")
      assert has_element?(view, "form[id^=webhook-endpoint-form]")
    end

    test "a free board while enforcement is off shows the normal panel", %{conn: conn} = ctx do
      view = open(conn, ctx.owner, ctx.board)

      refute has_element?(view, "#integrations-locked")
      refute has_element?(view, "[data-endpoint-paused]")
      assert has_element?(view, "#webhook-rotate-#{ctx.endpoint.id}")
    end
  end
end
