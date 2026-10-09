defmodule KanbanWeb.BoardLive.BulkSelectionTest do
  use KanbanWeb.ConnCase

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Boards
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.Task
  alias KanbanWeb.BoardLive.BulkSelection

  setup [:register_and_log_in_user]

  setup %{user: user} do
    board = board_fixture(user)
    todo = column_fixture(board, %{name: "Todo"})
    done = column_fixture(board, %{name: "Done"})
    %{board: board, todo: todo, done: done}
  end

  defp reload(task), do: Repo.get!(Task, task.id)

  defp enter_selection(view) do
    view |> element("#bulk-select-toggle") |> render_click()
  end

  defp select(view, task), do: view |> element("#bulk-select-#{task.id}") |> render_click()

  describe "owner and modify members" do
    test "select two cards and move them to Done", %{
      conn: conn,
      board: board,
      todo: todo,
      done: done
    } do
      t1 = task_fixture(todo, %{title: "Alpha"})
      t2 = task_fixture(todo, %{title: "Beta"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      assert has_element?(view, "#bulk-action-bar")
      select(view, t1)
      select(view, t2)
      assert view |> element("#bulk-selected-count") |> render() =~ "2 selected"
      assert has_element?(view, "#bulk-select-#{t1.id}[aria-checked=true]")

      html = view |> form("#bulk-move-form", %{column_id: done.id}) |> render_submit()

      assert html =~ "Moved 2 tasks to Done"
      assert has_element?(view, "#tasks-#{done.id} #task-#{t1.id}")
      assert has_element?(view, "#tasks-#{done.id} #task-#{t2.id}")
      assert reload(t1).column_id == done.id
      assert view |> element("#bulk-selected-count") |> render() =~ "0 selected"
    end

    test "clicking a card body toggles it in selection mode", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      task = task_fixture(todo)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)

      view
      |> element("#task-#{task.id} div.cursor-pointer[phx-click=bulk_toggle]")
      |> render_click()

      assert has_element?(view, "#bulk-select-#{task.id}[aria-checked=true]")

      view |> element("#bulk-clear") |> render_click()
      assert has_element?(view, "#bulk-select-#{task.id}[aria-checked=false]")
    end

    test "select all picks only the visible cards in a column and toggles back", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      shown = task_fixture(todo, %{title: "Alpha one"})
      hidden = task_fixture(todo, %{title: "Zulu"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}?q=Alpha")

      enter_selection(view)
      view |> element("#bulk-select-column-#{todo.id}") |> render_click()

      assert view |> element("#bulk-selected-count") |> render() =~ "1 selected"
      assert has_element?(view, "#bulk-select-#{shown.id}[aria-checked=true]")
      refute has_element?(view, "#bulk-select-#{hidden.id}")

      view |> element("#bulk-select-column-#{todo.id}") |> render_click()
      assert view |> element("#bulk-selected-count") |> render() =~ "0 selected"
    end

    test "a filter change prunes selected cards it hides", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      alpha = task_fixture(todo, %{title: "Alpha"})
      zulu = task_fixture(todo, %{title: "Zulu"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      select(view, alpha)
      select(view, zulu)
      render_patch(view, ~p"/boards/#{board}?q=Alpha")

      assert view |> element("#bulk-selected-count") |> render() =~ "1 selected"

      view |> element("#bulk-archive") |> render_click()
      assert reload(alpha).archived_at
      assert reload(zulu).archived_at == nil
    end

    test "a selected task moved by another session leaves the selection", %{
      conn: conn,
      board: board,
      todo: todo,
      done: done
    } do
      review = column_fixture(board, %{name: "Review"})
      kept = task_fixture(todo, %{title: "Kept"})
      moved = task_fixture(todo, %{title: "Moved away"})
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      view |> element("#bulk-select-column-#{todo.id}") |> render_click()
      assert view |> element("#bulk-selected-count") |> render() =~ "2 selected"

      {:ok, _} = moved |> reload() |> Tasks.move_task(done, 0)

      assert view |> element("#bulk-selected-count") |> render() =~ "1 selected"
      assert render(view) =~ "A selected task moved to another column"
      refute has_element?(view, "#bulk-select-#{moved.id}[aria-checked=true]")

      view |> form("#bulk-move-form", %{column_id: review.id}) |> render_submit()

      assert reload(kept).column_id == review.id
      assert reload(moved).column_id == done.id
    end

    test "a WIP breach changes nothing and says so", %{conn: conn, board: board, todo: todo} do
      limited = column_fixture(board, %{name: "Limited", wip_limit: 1})
      _occupant = task_fixture(limited)
      task = task_fixture(todo)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      select(view, task)
      html = view |> form("#bulk-move-form", %{column_id: limited.id}) |> render_submit()

      assert html =~ "exceed its WIP limit"
      assert reload(task).column_id == todo.id
    end

    test "goals are skipped by a move with a message", %{
      conn: conn,
      board: board,
      todo: todo,
      done: done
    } do
      goal = task_fixture(todo, %{type: :goal, title: "Goal"})
      task = task_fixture(todo)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      select(view, goal)
      select(view, task)
      html = view |> form("#bulk-move-form", %{column_id: done.id}) |> render_submit()

      assert html =~ "1 goal was skipped"
      assert reload(goal).column_id == todo.id
      assert reload(task).column_id == done.id
    end

    test "an empty selection is refused", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      assert render_hook(view, "bulk_archive", %{}) =~ "Select at least one task"
    end

    test "archive asks for confirmation and archives the selection", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      t1 = task_fixture(todo)
      t2 = task_fixture(todo)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      select(view, t1)
      select(view, t2)

      assert view |> element("#bulk-archive") |> render() =~ "data-confirm"
      html = view |> element("#bulk-archive") |> render_click()

      assert html =~ "Archived 2 tasks"
      refute has_element?(view, "#task-#{t1.id}")
      assert reload(t2).archived_at
    end

    test "assign and label forms apply to the selection", %{
      conn: conn,
      user: user,
      board: board,
      todo: todo
    } do
      label = label_fixture(board, %{name: "urgent"})
      task = task_fixture(todo)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      select(view, task)

      assert view |> form("#bulk-assign-form", %{assignee: user.id}) |> render_submit() =~
               "Assigned 1 task"

      assert reload(task).assigned_to_id == user.id

      select(view, task)

      assert view |> form("#bulk-add-label-form", %{label_id: label.id}) |> render_submit() =~
               "Added the label to 1 task"

      select(view, task)

      assert view |> form("#bulk-remove-label-form", %{label_id: label.id}) |> render_submit() =~
               "Removed the label from 1 task"

      select(view, task)

      assert view |> form("#bulk-assign-form", %{assignee: "unassigned"}) |> render_submit() =~
               "Assigned 1 task"

      assert reload(task).assigned_to_id == nil
    end

    test "invalid targets are reported", %{conn: conn, board: board, todo: todo} do
      task = task_fixture(todo)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      select(view, task)

      assert render_hook(view, "bulk_move", %{"column_id" => ""}) =~
               "Column not found on this board"

      assert render_hook(view, "bulk_assign", %{"assignee" => ""}) =~ "Choose a board member"
      assert render_hook(view, "bulk_add_label", %{"label_id" => "x"}) =~ "Label not found"
      assert render_hook(view, "bulk_toggle", %{"id" => "999999999"})
      assert view |> element("#bulk-selected-count") |> render() =~ "1 selected"
    end

    test "a card deleted by another user drops out of the selection", %{
      conn: conn,
      board: board,
      todo: todo
    } do
      kept = task_fixture(todo)
      gone = task_fixture(todo)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      select(view, kept)
      select(view, gone)
      {:ok, _} = Tasks.delete_task(gone)

      assert view |> element("#bulk-selected-count") |> render() =~ "1 selected"
      assert view |> element("#bulk-archive") |> render_click() =~ "Archived 1 task"
      assert reload(kept).archived_at
    end

    test "the server re-checks access even when the socket still allows it", %{
      conn: conn,
      user: user,
      board: board,
      todo: todo
    } do
      task = task_fixture(todo)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      select(view, task)

      from(bu in Kanban.Boards.BoardUser,
        where: bu.board_id == ^board.id and bu.user_id == ^user.id
      )
      |> Repo.update_all(set: [access: :read_only])

      assert view |> element("#bulk-archive") |> render_click() =~ "permission to modify"
      assert reload(task).archived_at == nil
    end

    test "a modify member can bulk move, and other viewers see the result", %{
      conn: conn,
      user: owner,
      board: board,
      todo: todo,
      done: done
    } do
      editor = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, editor, :modify, owner)
      task = task_fixture(todo)

      {:ok, owner_view, _html} = live(conn, ~p"/boards/#{board}")
      {:ok, editor_view, _html} = live(log_in_user(build_conn(), editor), ~p"/boards/#{board}")

      enter_selection(editor_view)
      select(editor_view, task)
      editor_view |> form("#bulk-move-form", %{column_id: done.id}) |> render_submit()

      assert has_element?(owner_view, "#tasks-#{done.id} #task-#{task.id}")
    end

    test "leaving selection mode hides the controls", %{conn: conn, board: board, todo: todo} do
      task = task_fixture(todo)
      {:ok, view, _html} = live(conn, ~p"/boards/#{board}")

      enter_selection(view)
      assert has_element?(view, "#tasks-#{todo.id}[data-sortable-disabled=true]")
      enter_selection(view)

      refute has_element?(view, "#bulk-action-bar")
      refute has_element?(view, "#bulk-select-#{task.id}")
    end
  end

  describe "read-only members" do
    setup %{board: board, user: owner} do
      reader = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, reader, :read_only, owner)
      %{reader: reader}
    end

    test "see no selection controls and their forged events are refused", %{
      board: board,
      todo: todo,
      reader: reader
    } do
      task = task_fixture(todo)
      {:ok, view, _html} = live(log_in_user(build_conn(), reader), ~p"/boards/#{board}")

      refute has_element?(view, "#bulk-select-toggle")
      refute has_element?(view, ".bulk-select")
      refute has_element?(view, "#bulk-action-bar")

      assert render_hook(view, "bulk_toggle_mode", %{}) =~ "permission to modify"
      assert render_hook(view, "bulk_toggle", %{"id" => task.id}) =~ "permission to modify"
      assert render_hook(view, "bulk_archive", %{}) =~ "permission to modify"
      refute has_element?(view, "#bulk-action-bar")
      assert reload(task).archived_at == nil
    end
  end

  describe "prune/1" do
    defp socket(assigns) do
      %{%Phoenix.LiveView.Socket{} | assigns: Map.merge(%{__changed__: %{}}, assigns)}
    end

    test "keeps only visible ids for a modifier" do
      pruned =
        socket(%{
          can_modify: true,
          selected_ids: MapSet.new([1, 2, 3]),
          visible_tasks_by_column: %{
            10 => [%{id: 1, column_id: 10}],
            11 => [%{id: 3, column_id: 11}]
          }
        })
        |> BulkSelection.prune()

      assert pruned.assigns.selected_ids == MapSet.new([1, 3])
    end

    test "drops a selected task whose column changed since the previous load, with a flash" do
      pruned =
        socket(%{
          can_modify: true,
          flash: %{},
          selected_ids: MapSet.new([1, 2, 3]),
          visible_tasks_by_column: %{
            10 => [%{id: 1, column_id: 10}],
            11 => [%{id: 2, column_id: 11}, %{id: 3, column_id: 11}]
          }
        })
        |> BulkSelection.prune(%{1 => 10, 2 => 10, 3 => 11})

      assert pruned.assigns.selected_ids == MapSet.new([1, 3])
      assert pruned.assigns.flash["info"] =~ "A selected task moved to another column"
    end

    test "counts several moved tasks in the flash and keeps one that only changed position" do
      pruned =
        socket(%{
          can_modify: true,
          flash: %{},
          selected_ids: MapSet.new([1, 2, 3]),
          visible_tasks_by_column: %{
            11 => [%{id: 1, column_id: 11}, %{id: 2, column_id: 11}, %{id: 3, column_id: 10}]
          }
        })
        |> BulkSelection.prune(%{1 => 10, 2 => 10, 3 => 10})

      assert pruned.assigns.selected_ids == MapSet.new([3])
      assert pruned.assigns.flash["info"] =~ "2 selected tasks moved to another column"
    end

    test "without a previous load nothing counts as moved" do
      pruned =
        socket(%{
          can_modify: true,
          flash: %{},
          selected_ids: MapSet.new([1]),
          visible_tasks_by_column: %{11 => [%{id: 1, column_id: 11}]}
        })
        |> BulkSelection.prune()

      assert pruned.assigns.selected_ids == MapSet.new([1])
      assert pruned.assigns.flash == %{}
    end
  end

  describe "task_columns/1" do
    test "maps each visible task to its column, and is empty before any load" do
      socket =
        socket(%{
          visible_tasks_by_column: %{
            10 => [%{id: 1, column_id: 10}],
            11 => [%{id: 2, column_id: 11}]
          }
        })

      assert BulkSelection.task_columns(socket) == %{1 => 10, 2 => 11}
      assert %{} |> socket() |> BulkSelection.task_columns() == %{}
    end

    test "clears the selection and mode for a viewer who cannot modify" do
      pruned =
        socket(%{can_modify: false, selection_mode: true, selected_ids: MapSet.new([1])})
        |> BulkSelection.prune()

      assert pruned.assigns.selected_ids == MapSet.new()
      refute pruned.assigns.selection_mode
    end

    test "tolerates a socket that has no selection yet" do
      pruned = socket(%{can_modify: true}) |> BulkSelection.prune()
      assert pruned.assigns.selected_ids == MapSet.new()
    end
  end
end
