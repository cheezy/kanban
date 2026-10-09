defmodule KanbanWeb.BoardLive.LabelsManagerComponentTest do
  use KanbanWeb.ConnCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.TasksFixtures
  import Phoenix.LiveViewTest

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Labels
  alias Kanban.Labels.Label
  alias Kanban.Labels.TaskLabel
  alias Kanban.Repo
  alias KanbanWeb.BoardLive.LabelsManagerComponent

  @denied "You do not have permission to manage labels on this board"

  defp manager(board), do: "#board-labels-#{board.id}"

  defp open_settings(conn, user, board) do
    {:ok, view, _html} = live(log_in_user(conn, user), ~p"/boards/#{board}/settings")
    view
  end

  defp new_form(view), do: element(view, "[data-labels-manager] form[id^=label-new-form]")

  defp create(view, name, color) do
    view |> new_form() |> render_submit(%{"label" => %{"name" => name, "color" => color}})
  end

  defp label_names(board) do
    Label |> Repo.all() |> Enum.filter(&(&1.board_id == board.id)) |> Enum.map(& &1.name)
  end

  describe "as the board owner" do
    setup %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      %{conn: conn, owner: owner, board: board}
    end

    test "shows an empty state when the board has no labels", %{conn: c, owner: o, board: b} do
      view = open_settings(c, o, b)

      assert has_element?(view, "[data-labels-empty]", "No labels yet")
      assert has_element?(view, "form[id^=label-new-form]")
    end

    test "creates a label and renders it as a chip", %{conn: c, owner: o, board: b} do
      view = open_settings(c, o, b)

      html = create(view, "Bug", "red")

      assert html =~ "Bug"
      assert has_element?(view, "[data-label-chip=red]", "Bug")
      refute has_element?(view, "[data-labels-empty]")
      assert label_names(b) == ["Bug"]
    end

    test "shows inline errors for a blank, too long or duplicate name", %{
      conn: c,
      owner: o,
      board: b
    } do
      label_fixture(b, %{name: "Bug"})
      view = open_settings(c, o, b)

      assert create(view, "  ", "red") =~ "can&#39;t be blank"
      assert create(view, String.duplicate("a", 41), "red") =~ "should be at most 40 character(s)"
      assert create(view, "BUG", "red") =~ "has already been taken"
      assert label_names(b) == ["Bug"]
    end

    test "validate previews the chip for a typed name", %{conn: c, owner: o, board: b} do
      view = open_settings(c, o, b)

      view
      |> new_form()
      |> render_change(%{"label" => %{"name" => "Preview", "color" => "teal"}})

      assert has_element?(view, "[data-label-chip=teal]", "Preview")
    end

    test "renames and recolors a label", %{conn: c, owner: o, board: b} do
      label = label_fixture(b, %{name: "Bug", color: :red})
      view = open_settings(c, o, b)

      view |> element("#label-edit-#{label.id}") |> render_click()
      assert has_element?(view, "#label-edit-form-#{label.id}")

      view
      |> element("#label-edit-form-#{label.id}")
      |> render_change(%{"label_id" => label.id, "label" => %{"name" => "", "color" => "red"}})

      assert render(view) =~ "can&#39;t be blank"

      view
      |> element("#label-edit-form-#{label.id}")
      |> render_submit(%{
        "label_id" => label.id,
        "label" => %{"name" => "Defect", "color" => "green"}
      })

      refute has_element?(view, "#label-edit-form-#{label.id}")
      assert has_element?(view, "[data-label-chip=green]", "Defect")
      assert %Label{name: "Defect", color: :green} = Repo.get!(Label, label.id)
    end

    test "an invalid update keeps the row in edit mode with the error", %{
      conn: c,
      owner: o,
      board: b
    } do
      label = label_fixture(b, %{name: "Bug"})
      label_fixture(b, %{name: "Feature"})
      view = open_settings(c, o, b)

      view |> element("#label-edit-#{label.id}") |> render_click()

      html =
        view
        |> element("#label-edit-form-#{label.id}")
        |> render_submit(%{"label_id" => label.id, "label" => %{"name" => "feature"}})

      assert html =~ "has already been taken"
      assert has_element?(view, "#label-edit-form-#{label.id}")
      assert Repo.get!(Label, label.id).name == "Bug"
    end

    test "cancel leaves edit mode without saving", %{conn: c, owner: o, board: b} do
      label = label_fixture(b, %{name: "Bug"})
      view = open_settings(c, o, b)

      view |> element("#label-edit-#{label.id}") |> render_click()
      view |> element("#label-row-#{label.id} button", "Cancel") |> render_click()

      refute has_element?(view, "#label-edit-form-#{label.id}")
      assert has_element?(view, "#label-edit-#{label.id}")
    end

    test "deletes a label used on many tasks without touching the tasks", %{
      conn: c,
      owner: o,
      board: b
    } do
      label = label_fixture(b, %{name: "Bug"})
      column = column_fixture(b)
      scope = Scope.for_user(o)

      tasks =
        for _ <- 1..3 do
          task = task_fixture(column)
          {:ok, _} = Labels.set_task_labels(scope, task, [label.id])
          task
        end

      view = open_settings(c, o, b)
      view |> element("#label-delete-#{label.id}") |> render_click()

      refute has_element?(view, "#label-row-#{label.id}")
      assert has_element?(view, "[data-labels-empty]")
      assert Repo.all(TaskLabel) |> Enum.filter(&(&1.label_id == label.id)) == []
      for task <- tasks, do: assert(Repo.get(Kanban.Tasks.Task, task.id))
    end

    test "a long name is truncated in its chip with the full name as a title", %{
      conn: c,
      owner: o,
      board: b
    } do
      name = String.duplicate("x", 40)
      label_fixture(b, %{name: name})
      view = open_settings(c, o, b)

      assert has_element?(view, ~s([data-label-chip][title="#{name}"]))
      assert render(view) =~ "text-overflow: ellipsis"
    end

    test "a new label reaches the board filter bar without a reload", %{
      conn: c,
      owner: o,
      board: b
    } do
      # The filter bar only renders on a board with columns. Opening the board
      # first caches its filter options, so only the label-change reload can
      # put the new label into them.
      column_fixture(b)
      label_fixture(b, %{name: "Existing"})
      {:ok, view, _html} = live(log_in_user(c, o), ~p"/boards/#{b}")
      assert has_element?(view, "#board-filter-label option", "Existing")
      render_patch(view, ~p"/boards/#{b}/settings")

      create(view, "Fresh", "blue")
      render_patch(view, ~p"/boards/#{b}")

      assert has_element?(view, "#board-filter-label option", "Fresh")
    end

    test "renaming, recolouring and deleting a label update the open board's cards", %{
      conn: c,
      owner: o,
      board: b
    } do
      label = label_fixture(b, %{name: "Bug", color: :red})
      task = b |> column_fixture() |> task_fixture()
      {:ok, _} = o |> Scope.for_user() |> Labels.set_task_labels(task, [label.id])
      card_chip = "#task-#{task.id} [data-label-chip]"

      {:ok, view, _html} = live(log_in_user(c, o), ~p"/boards/#{b}")
      assert has_element?(view, "#task-#{task.id} [data-label-chip=red]", "Bug")
      render_patch(view, ~p"/boards/#{b}/settings")

      view |> element("#label-edit-#{label.id}") |> render_click()

      view
      |> element("#label-edit-form-#{label.id}")
      |> render_submit(%{
        "label_id" => label.id,
        "label" => %{"name" => "Defect", "color" => "purple"}
      })

      render_patch(view, ~p"/boards/#{b}")
      assert has_element?(view, "#task-#{task.id} [data-label-chip=purple]", "Defect")
      refute has_element?(view, card_chip, "Bug")

      render_patch(view, ~p"/boards/#{b}/settings")
      view |> element("#label-delete-#{label.id}") |> render_click()
      render_patch(view, ~p"/boards/#{b}")

      refute has_element?(view, card_chip)
      refute has_element?(view, "#board-filter-label")
    end

    test "an id from another board or a stale id is refused", %{conn: c, owner: o, board: b} do
      other_board = board_fixture(o)
      foreign = label_fixture(other_board, %{name: "Foreign"})
      view = open_settings(c, o, b)

      view |> with_target(manager(b)) |> render_click("delete", %{"id" => "#{foreign.id}"})
      assert render(view) =~ "That label no longer exists"
      assert Repo.get(Label, foreign.id)

      view |> with_target(manager(b)) |> render_click("delete", %{"id" => "not-an-id"})
      assert Repo.get(Label, foreign.id)
    end

    test "a label deleted in another session gets a flash, not a crash", %{
      conn: c,
      owner: o,
      board: b
    } do
      gone = label_fixture(b, %{name: "Gone"})
      edited = label_fixture(b, %{name: "Edited"})
      view = open_settings(c, o, b)
      view |> element("#label-edit-#{edited.id}") |> render_click()

      Repo.delete!(edited)

      view
      |> element("#label-edit-form-#{edited.id}")
      |> render_submit(%{"label_id" => edited.id, "label" => %{"name" => "Renamed"}})

      assert render(view) =~ "That label no longer exists"
      refute has_element?(view, "#label-edit-form-#{edited.id}")

      Repo.delete!(gone)
      view |> element("#label-delete-#{gone.id}") |> render_click()

      refute has_element?(view, "#label-row-#{gone.id}")
      refute has_element?(view, "#label-row-#{edited.id}")
      assert has_element?(view, "[data-labels-empty]")
    end

    test "opening a label for edit also drops labels deleted elsewhere", %{
      conn: c,
      owner: o,
      board: b
    } do
      kept = label_fixture(b, %{name: "Kept"})
      gone = label_fixture(b, %{name: "Gone"})
      view = open_settings(c, o, b)

      Repo.delete!(gone)
      view |> element("#label-edit-#{kept.id}") |> render_click()

      assert has_element?(view, "#label-edit-form-#{kept.id}")
      refute has_element?(view, "#label-row-#{gone.id}")
    end

    test "sees the board details form", %{conn: c, owner: o, board: b} do
      view = open_settings(c, o, b)

      assert has_element?(view, "#board-settings-form-#{b.id}")
      refute has_element?(view, "[data-settings-owner-only]")
    end
  end

  describe "as a modify member" do
    setup %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
      %{conn: conn, member: member, board: board}
    end

    test "can manage labels but not the owner-only board details", %{
      conn: c,
      member: m,
      board: b
    } do
      view = open_settings(c, m, b)

      create(view, "Docs", "purple")

      assert has_element?(view, "[data-label-chip=purple]", "Docs")
      assert label_names(b) == ["Docs"]
      refute has_element?(view, "#board-settings-form-#{b.id}")
      assert has_element?(view, "[data-settings-owner-only]")
    end
  end

  describe "as a read-only member" do
    setup %{conn: conn} do
      owner = user_fixture()
      board = board_fixture(owner)
      member = user_fixture()
      {:ok, _} = Boards.add_user_to_board(board, member, :read_only, owner)
      label = label_fixture(board, %{name: "Bug", color: :red})
      %{conn: conn, member: member, board: board, label: label}
    end

    test "reaches board settings from the board's Settings tab", %{conn: c, member: m, board: b} do
      {:ok, view, _html} = live(log_in_user(c, m), ~p"/boards/#{b}")

      assert has_element?(view, ~s(a[href="/boards/#{b.id}/settings"]))
    end

    test "sees the chips with no edit controls", %{conn: c, member: m, board: b, label: l} do
      view = open_settings(c, m, b)

      assert has_element?(view, "[data-label-chip=red]", "Bug")
      refute has_element?(view, "form[id^=label-new-form]")
      refute has_element?(view, "#label-edit-#{l.id}")
      refute has_element?(view, "#label-delete-#{l.id}")
    end

    test "sees the read-only empty state on a board without labels", %{
      conn: c,
      member: m,
      board: b,
      label: l
    } do
      Repo.delete!(l)
      view = open_settings(c, m, b)

      assert has_element?(view, "[data-labels-empty]", "This board has no labels yet.")
    end

    test "forged events are refused with a flash", %{conn: c, member: m, board: b, label: l} do
      view = open_settings(c, m, b)
      target = with_target(view, manager(b))

      render_click(target, "delete", %{"id" => "#{l.id}"})
      assert render(view) =~ @denied

      render_submit(target, "create", %{"label" => %{"name" => "Forged", "color" => "red"}})

      render_submit(target, "update", %{
        "label_id" => "#{l.id}",
        "label" => %{"name" => "Hacked", "color" => "green"}
      })

      render_click(target, "edit", %{"id" => "#{l.id}"})
      render_change(target, "validate", %{"label" => %{"name" => "x"}})

      refute has_element?(view, "#label-edit-form-#{l.id}")
      assert render(view) =~ @denied
      assert label_names(b) == ["Bug"]
      assert %Label{name: "Bug", color: :red} = Repo.get!(Label, l.id)
    end
  end

  describe "apply_parent_message/2" do
    test "puts a flash for a flash message" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

      socket = LabelsManagerComponent.apply_parent_message(socket, {:flash, :error, "Nope"})

      assert socket.assigns.flash == %{"error" => "Nope"}
    end
  end
end
