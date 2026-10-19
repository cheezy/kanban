defmodule KanbanWeb.TaskLive.TelemetryFieldsLockTest do
  @moduledoc """
  The paid task fields (`telemetry_event` and `metrics_to_track`) in the task
  form and task view while paid plans are enforced: a free board shows the
  locked prompt instead of the inputs, never stores the fields from a save,
  keeps values stored before the lock, and hides them in the view.
  """
  # async: false - these tests switch the global :plans_enforced application
  # env on through Kanban.PlansHelpers.
  use KanbanWeb.ConnCase, async: false

  import Ecto.Query
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.OrganizationsFixtures
  import Kanban.PlansHelpers
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers
  import Kanban.WorkspacesFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias KanbanWeb.TaskLive.ViewComponent

  @stored %{
    telemetry_event: "[:kanban, :task, :done]",
    metrics_to_track: "Done count",
    logging_requirements: "Log every completion"
  }

  setup :register_and_log_in_user

  setup %{user: user} do
    board =
      user
      |> board_fixture()
      |> Ecto.Changeset.change(field_visibility: %{"observability" => true})
      |> Repo.update!()

    column = column_fixture(board)
    %{board: board, column: column, task: task_fixture(column, @stored)}
  end

  defp make_paid(%Board{id: id}) do
    workspace = org_workspace_fixture(organization_fixture())

    {1, _} =
      Board |> where([b], b.id == ^id) |> Repo.update_all(set: [workspace_id: workspace.id])

    :ok
  end

  defp edit(conn, board, task) do
    {:ok, view, _html} = live(conn, ~p"/boards/#{board}/tasks/#{task}/edit")
    view
  end

  defp stored(task) do
    Task
    |> Repo.get!(task.id)
    |> Map.take([:telemetry_event, :metrics_to_track, :logging_requirements])
  end

  defp render_view(task) do
    render_component(ViewComponent,
      id: "view-#{task.id}",
      task_id: task.id,
      field_visibility: %{"observability" => true}
    )
  end

  describe "the task form on a free board under enforcement" do
    setup :enforce_plans

    test "shows the locked Telemetry prompt instead of the two inputs", %{conn: conn} = ctx do
      view = edit(conn, ctx.board, ctx.task)

      assert has_element?(view, ~s(#task-telemetry-locked [data-locked-feature="telemetry"]))
      assert has_element?(view, ~s(#task-telemetry-locked a[href="/locked/telemetry"]))
      refute has_element?(view, ~s(#task-form [name="task[telemetry_event]"]))
      refute has_element?(view, ~s(#task-form [name="task[metrics_to_track]"]))
      assert has_element?(view, ~s(#task-form [name="task[logging_requirements]"]))
    end

    test "saving keeps the values stored before the lock", %{conn: conn} = ctx do
      view = edit(conn, ctx.board, ctx.task)

      view |> form("#task-form", task: %{title: "Renamed"}) |> render_submit()

      assert Repo.get!(Task, ctx.task.id).title == "Renamed"
      assert stored(ctx.task) == @stored
    end

    test "a crafted save with the paid fields does not store them", %{conn: conn} = ctx do
      view = edit(conn, ctx.board, ctx.task)

      view
      |> element("#task-form")
      |> render_submit(%{
        "task" => %{
          "title" => "Crafted",
          "telemetry_event" => "[:forged]",
          "metrics_to_track" => "",
          "logging_requirements" => "New logging"
        }
      })

      assert Repo.get!(Task, ctx.task.id).title == "Crafted"
      assert stored(ctx.task) == %{@stored | logging_requirements: "New logging"}
    end

    test "a crafted validate with the paid fields still renders no inputs", %{conn: conn} = ctx do
      view = edit(conn, ctx.board, ctx.task)

      view
      |> element("#task-form")
      |> render_change(%{"task" => %{"telemetry_event" => "[:forged]"}})

      refute has_element?(view, ~s(#task-form [name="task[telemetry_event]"]))
      refute render(view) =~ "[:forged]"
    end

    test "a new task created from the form stores neither field", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/boards/#{ctx.board}/columns/#{ctx.column}/tasks/new")

      view
      |> element("#task-form")
      |> render_submit(%{
        "task" => %{"title" => "Fresh task", "type" => "work", "telemetry_event" => "[:new]"}
      })

      assert %Task{telemetry_event: nil} = Repo.get_by!(Task, title: "Fresh task")
    end
  end

  describe "a task form opened before enforcement was switched on" do
    setup ctx do
      view = edit(ctx.conn, ctx.board, ctx.task)
      assert has_element?(view, ~s(#task-form [name="task[telemetry_event]"]))
      enforce_plans()
      %{view: view}
    end

    test "a save that changes the paid fields stores neither and says so", ctx do
      attach_telemetry([:kanban, :plan, :feature_refused])

      ctx.view
      |> form("#task-form",
        task: %{title: "Stale", telemetry_event: "[:changed]", metrics_to_track: "Changed"}
      )
      |> render_submit()

      assert Repo.get!(Task, ctx.task.id).title == "Stale"
      assert stored(ctx.task) == @stored

      assert render(ctx.view) =~
               "Telemetry Event and Metrics to Track need a board in an Organization"

      assert_received {:telemetry_event, [:kanban, :plan, :feature_refused], %{count: 1},
                       %{feature: :telemetry, surface: :live_view}}
    end

    test "a save that leaves the stored values as they were gives no warning", ctx do
      attach_telemetry([:kanban, :plan, :feature_refused])

      ctx.view |> form("#task-form", task: %{title: "Unchanged"}) |> render_submit()

      assert Repo.get!(Task, ctx.task.id).title == "Unchanged"
      assert stored(ctx.task) == @stored
      refute render(ctx.view) =~ "need a board in an Organization"
      refute_received {:telemetry_event, [:kanban, :plan, :feature_refused], _, _}
    end
  end

  describe "the task form on a paid board or without enforcement" do
    test "a paid board under enforcement shows and saves the inputs", %{conn: conn} = ctx do
      enforce_plans()
      :ok = make_paid(ctx.board)
      view = edit(conn, ctx.board, ctx.task)

      refute has_element?(view, "#task-telemetry-locked")

      view
      |> form("#task-form", task: %{telemetry_event: "[:paid]"})
      |> render_submit()

      assert stored(ctx.task).telemetry_event == "[:paid]"
    end

    test "a free board without enforcement shows the inputs", %{conn: conn} = ctx do
      view = edit(conn, ctx.board, ctx.task)

      refute has_element?(view, "#task-telemetry-locked")
      assert has_element?(view, ~s(#task-form [name="task[telemetry_event]"]))
      assert has_element?(view, ~s(#task-form [name="task[metrics_to_track]"]))
    end
  end

  describe "the task view" do
    test "hides the stored paid fields on a free board under enforcement", ctx do
      enforce_plans()
      html = render_view(ctx.task)

      refute html =~ "[:kanban, :task, :done]"
      refute html =~ "Done count"
      assert html =~ "Observability"
      assert html =~ "Log every completion"
    end

    test "hides the whole section when only paid fields are stored", ctx do
      enforce_plans()
      task = task_fixture(ctx.column, %{telemetry_event: "[:only]"})

      refute render_view(task) =~ "Observability"
    end

    test "shows the stored fields on a paid board under enforcement", ctx do
      enforce_plans()
      :ok = make_paid(ctx.board)
      html = render_view(ctx.task)

      assert html =~ "[:kanban, :task, :done]"
      assert html =~ "Done count"
    end

    test "shows the stored fields on a free board without enforcement", ctx do
      html = render_view(ctx.task)

      assert html =~ "[:kanban, :task, :done]"
      assert html =~ "Done count"
    end
  end
end
