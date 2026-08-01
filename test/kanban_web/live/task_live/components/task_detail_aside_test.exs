defmodule KanbanWeb.TaskLive.Components.TaskDetailAsideTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias KanbanWeb.TaskLive.Components.TaskDetailAside

  # The aside is pure presentation over an already-loaded task, so an unsaved
  # struct is enough — it never touches the DB. It must be a real
  # `Kanban.Tasks.Task` rather than a plain map, because the edit link builds a
  # verified route from it and `~p` requires a struct implementing
  # `Phoenix.Param`. The associations are pinned to nil rather than left at
  # their not-loaded defaults, since `%Ecto.Association.NotLoaded{}` is truthy
  # and would send the `:if` branches down a path a real loaded task never
  # takes; `parent` keeps the not-loaded default on purpose, because that IS
  # what ViewComponent's own loader hands this component.
  defp task(overrides) do
    struct(
      Kanban.Tasks.Task,
      Map.merge(
        %{
          id: 1,
          identifier: "W1",
          status: :in_progress,
          type: :work,
          priority: nil,
          complexity: nil,
          column: nil,
          needs_review: false,
          required_capabilities: [],
          human_task: false,
          estimated_files: nil,
          inserted_at: nil,
          claimed_at: nil,
          completed_at: nil,
          assigned_to: nil,
          created_by: nil
        },
        overrides
      )
    )
  end

  defp render_aside(overrides \\ %{}, opts \\ []) do
    render_component(&TaskDetailAside.task_detail_aside/1,
      task: task(overrides),
      can_modify: Keyword.get(opts, :can_modify, false),
      board_id: Keyword.get(opts, :board_id, nil)
    )
  end

  describe "task_detail_aside/1 (W2006)" do
    test "always renders the aside shell and the status item" do
      html = render_aside()

      assert html =~ "data-task-detail-aside"
      assert html =~ "Status"
      assert html =~ "Type"
    end

    test "renders the parent goal only when the parent association is loaded" do
      refute render_aside() =~ "hero-flag"

      html = render_aside(%{parent: %{identifier: "G7", title: "Epic Goal"}})

      assert html =~ "hero-flag"
      assert html =~ "G7"
      assert html =~ "Epic Goal"
    end

    test "a nil parent is treated as absent, like a not-loaded one" do
      refute render_aside(%{parent: nil}) =~ "hero-flag"
    end

    test "renders the board name only when column.board is loaded" do
      refute render_aside() =~ "Board"

      html = render_aside(%{column: %{name: "Doing", board: %{name: "Render Branch Board"}}})

      assert html =~ "Render Branch Board"
      assert html =~ "Doing"
    end

    test "a column without a loaded board renders the column but not a board name" do
      html = render_aside(%{column: %{name: "Doing", board: nil}})

      assert html =~ "Doing"
      refute html =~ "Render Branch Board"
    end

    test "needs_review renders Required, and its absence renders Auto" do
      assert render_aside(%{needs_review: true}) =~ "Required"
      assert render_aside(%{needs_review: false}) =~ "Auto"
    end

    test "renders the human-task indicator only when human_task is set" do
      assert render_aside(%{human_task: true}) =~ "Human task"
      refute render_aside(%{human_task: false}) =~ "Human task"
    end

    test "renders each required capability" do
      html = render_aside(%{required_capabilities: ["code_generation", "testing"]})

      assert html =~ "Capabilities"
      assert html =~ "code_generation"
      assert html =~ "testing"
    end

    test "omits the capabilities item for an empty list" do
      refute render_aside(%{required_capabilities: []}) =~ "Capabilities"
    end

    test "renders priority and complexity words when set" do
      html = render_aside(%{priority: :high, complexity: :medium})

      assert html =~ "Priority"
      assert html =~ "High"
      assert html =~ "Complexity"
      assert html =~ "Medium"
    end

    test "omits the date items when the timestamps are nil" do
      html = render_aside()

      refute html =~ "Created"
      refute html =~ "Claimed"
      refute html =~ "Completed"
    end

    test "renders each timestamp that is present" do
      html =
        render_aside(%{
          inserted_at: ~U[2024-01-10 09:00:00Z],
          claimed_at: ~U[2024-01-11 10:30:00Z],
          completed_at: ~U[2024-01-15 15:00:00Z]
        })

      assert html =~ "Created"
      assert html =~ "Jan 10, 2024"
      assert html =~ "Claimed"
      assert html =~ "Jan 11, 2024 10:30"
      assert html =~ "Completed"
      assert html =~ "Jan 15, 2024"
    end

    test "renders the author from assigned_to, falling back to created_by" do
      assert render_aside(%{assigned_to: %{id: 1, name: "Ada Lovelace"}}) =~ "Ada Lovelace"
      assert render_aside(%{created_by: %{id: 2, name: "Grace Hopper"}}) =~ "Grace Hopper"
    end

    test "assigned_to wins over created_by when both are present" do
      html =
        render_aside(%{
          assigned_to: %{id: 1, name: "Ada Lovelace"},
          created_by: %{id: 2, name: "Grace Hopper"}
        })

      assert html =~ "Ada Lovelace"
      refute html =~ "Grace Hopper"
    end

    test "falls back to the email, then to a placeholder, for the author name" do
      assert render_aside(%{assigned_to: %{id: 1, email: "ada@example.com"}}) =~ "ada@example.com"
      assert render_aside(%{assigned_to: %{id: 1}}) =~ "?"
    end

    test "omits the author item when neither user is present" do
      refute render_aside() =~ "Author"
    end

    # The edit link needs BOTH can_modify and a board_id — it patches to a
    # board-scoped route, so a nil board_id would build a broken path.
    test "renders the edit link only when can_modify and board_id are both present" do
      assert render_aside(%{}, can_modify: true, board_id: 42) =~ "Edit task"
      refute render_aside(%{}, can_modify: false, board_id: 42) =~ "Edit task"
      refute render_aside(%{}, can_modify: true, board_id: nil) =~ "Edit task"
      refute render_aside(%{}, can_modify: false, board_id: nil) =~ "Edit task"
    end

    test "the edit link points at the board-scoped edit route" do
      html = render_aside(%{id: 7}, can_modify: true, board_id: 42)

      assert html =~ "/boards/42/tasks/7/edit"
      assert html =~ "hero-pencil"
    end
  end
end
