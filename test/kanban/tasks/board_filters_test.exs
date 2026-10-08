defmodule Kanban.Tasks.BoardFiltersTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures
  import Kanban.LabelsFixtures
  import Kanban.TasksFixtures

  alias Kanban.Labels.TaskLabel
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.BoardFilters
  alias Kanban.Tasks.Task

  setup do
    owner = user_fixture()
    board = board_fixture(owner)
    column = column_fixture(board)
    %{owner: owner, board: board, column: column}
  end

  defp set(task, attrs), do: task |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp filtered_ids(columns, filters) do
    columns
    |> Tasks.list_tasks_by_columns(filters: filters)
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp ids(tasks), do: tasks |> Enum.map(& &1.id) |> Enum.sort()

  defp attach_label(task, label),
    do: Repo.insert!(%TaskLabel{task_id: task.id, label_id: label.id})

  describe "active?/1" do
    test "is false for nil and the default struct" do
      refute BoardFilters.active?(nil)
      refute BoardFilters.active?(%BoardFilters{})
    end

    test "is true when any dimension is set" do
      for filters <- [
            %BoardFilters{search: "x"},
            %BoardFilters{type: :defect},
            %BoardFilters{priority: :high},
            %BoardFilters{assignee: :unassigned},
            %BoardFilters{assignee: 7},
            %BoardFilters{label_id: 3}
          ] do
        assert BoardFilters.active?(filters)
      end
    end
  end

  describe "apply_filters/2 each dimension alone" do
    test "an inactive filter leaves the query unchanged" do
      assert BoardFilters.apply_filters(Task, nil) == Task
      assert BoardFilters.apply_filters(Task, %BoardFilters{}) == Task
    end

    test "search matches the title case-insensitively", %{column: column} do
      hit = task_fixture(column, %{title: "Fix Login Redirect"})
      _miss = task_fixture(column, %{title: "Unrelated chore"})

      assert filtered_ids([column], %BoardFilters{search: "login redirect"}) == [hit.id]
    end

    test "search matches the identifier case-insensitively", %{column: column} do
      hit = task_fixture(column, %{title: "Alpha"})
      _miss = task_fixture(column, %{title: "Beta"})

      assert filtered_ids([column], %BoardFilters{search: String.downcase(hit.identifier)}) ==
               [hit.id]
    end

    test "type", %{column: column} do
      defect = task_fixture(column, %{title: "Bug", type: :defect})
      _work = task_fixture(column, %{title: "Feature", type: :work})

      assert filtered_ids([column], %BoardFilters{type: :defect}) == [defect.id]
    end

    test "priority", %{column: column} do
      high = task_fixture(column, %{title: "Urgent", priority: :high})
      _low = task_fixture(column, %{title: "Later", priority: :low})

      assert filtered_ids([column], %BoardFilters{priority: :high}) == [high.id]
    end

    test "assignee by user id", %{column: column, owner: owner} do
      mine = column |> task_fixture(%{title: "Mine"}) |> set(assigned_to_id: owner.id)
      _other = task_fixture(column, %{title: "Nobody's"})

      assert filtered_ids([column], %BoardFilters{assignee: owner.id}) == [mine.id]
    end

    test "assignee :unassigned matches tasks with no assignee", %{column: column, owner: owner} do
      _mine = column |> task_fixture(%{title: "Mine"}) |> set(assigned_to_id: owner.id)
      unassigned = task_fixture(column, %{title: "Nobody's"})

      assert filtered_ids([column], %BoardFilters{assignee: :unassigned}) == [unassigned.id]
    end

    test "label", %{column: column, board: board} do
      label = label_fixture(board)
      labelled = task_fixture(column, %{title: "Labelled"})
      _plain = task_fixture(column, %{title: "Plain"})
      attach_label(labelled, label)

      assert filtered_ids([column], %BoardFilters{label_id: label.id}) == [labelled.id]
    end
  end

  describe "apply_filters/2 combined" do
    test "every set condition must hold", %{column: column, board: board} do
      label = label_fixture(board)
      both = task_fixture(column, %{title: "Crash on save", type: :defect, priority: :high})
      wrong_priority = task_fixture(column, %{title: "Crash on load", type: :defect})
      wrong_type = task_fixture(column, %{title: "Crash report", type: :work, priority: :high})
      Enum.each([both, wrong_priority, wrong_type], &attach_label(&1, label))

      filters = %BoardFilters{search: "crash", type: :defect, priority: :high, label_id: label.id}

      assert filtered_ids([column], filters) == [both.id]
    end
  end

  describe "search is parameterized" do
    test "percent is matched literally", %{column: column} do
      hit = task_fixture(column, %{title: "Reach 100% coverage"})
      _miss = task_fixture(column, %{title: "Reach 1000 users"})

      assert filtered_ids([column], %BoardFilters{search: "100%"}) == [hit.id]
    end

    test "underscore is matched literally", %{column: column} do
      hit = task_fixture(column, %{title: "rename a_b field"})
      _miss = task_fixture(column, %{title: "rename axb field"})

      assert filtered_ids([column], %BoardFilters{search: "a_b"}) == [hit.id]
    end

    test "backslash is matched literally", %{column: column} do
      hit = task_fixture(column, %{title: ~S"escape C:\temp path"})
      _miss = task_fixture(column, %{title: "escape C:temp path"})

      assert filtered_ids([column], %BoardFilters{search: ~S":\t"}) == [hit.id]
    end

    test "SQL metacharacters are data, not syntax", %{column: column} do
      _task = task_fixture(column, %{title: "Ordinary"})

      assert filtered_ids([column], %BoardFilters{search: "'; DROP TABLE tasks; --"}) == []
      assert Repo.aggregate(Task, :count) >= 1
    end

    test "a very long search string does not crash", %{column: column} do
      _task = task_fixture(column, %{title: "Ordinary"})

      assert filtered_ids([column], %BoardFilters{search: String.duplicate("a", 1_000)}) == []
    end
  end

  describe "board scoping" do
    test "a label from another board matches nothing", %{column: column} do
      other_owner = user_fixture()
      other_board = board_fixture(other_owner)
      foreign_label = label_fixture(other_board)
      task = task_fixture(column, %{title: "Here"})
      # A join row the Labels context would refuse to create.
      attach_label(task, foreign_label)

      assert filtered_ids([column], %BoardFilters{label_id: foreign_label.id}) == []
    end

    test "filters never widen beyond the requested columns", %{column: column} do
      other_board = board_fixture(user_fixture())
      other_column = column_fixture(other_board)
      here = task_fixture(column, %{title: "Shared word"})
      _there = task_fixture(other_column, %{title: "Shared word"})

      assert filtered_ids([column], %BoardFilters{search: "shared"}) == [here.id]
    end
  end

  describe "goal context" do
    setup %{column: column} do
      goal = task_fixture(column, %{title: "Quarterly goal", type: :goal})
      %{goal: goal}
    end

    test "a goal whose child matches is returned with the child", %{column: column, goal: goal} do
      child = column |> task_fixture(%{title: "Needle child"}) |> set(parent_id: goal.id)
      _sibling = column |> task_fixture(%{title: "Hay child"}) |> set(parent_id: goal.id)

      assert filtered_ids([column], %BoardFilters{search: "needle"}) == ids([goal, child])
    end

    test "a matching goal does not pull in non-matching children", %{column: column, goal: goal} do
      _child = column |> task_fixture(%{title: "Hay child"}) |> set(parent_id: goal.id)

      assert filtered_ids([column], %BoardFilters{search: "quarterly"}) == [goal.id]
    end

    test "an archived matching child does not pull in its goal", %{column: column, goal: goal} do
      _archived =
        column
        |> task_fixture(%{title: "Needle child"})
        |> set(parent_id: goal.id, archived_at: DateTime.utc_now(:second))

      assert filtered_ids([column], %BoardFilters{search: "needle"}) == []
    end
  end

  describe "Tasks.list_tasks_by_columns/2 with :filters" do
    test "groups by column and still excludes archived tasks", %{board: board, column: column} do
      second = column_fixture(board)
      a = task_fixture(column, %{title: "Match one"})
      b = task_fixture(second, %{title: "Match two"})

      _archived =
        column
        |> task_fixture(%{title: "Match old"})
        |> set(archived_at: DateTime.utc_now(:second))

      grouped =
        Tasks.list_tasks_by_columns([column, second], filters: %BoardFilters{search: "match"})

      assert ids(grouped[column.id]) == [a.id]
      assert ids(grouped[second.id]) == [b.id]
    end

    test "without :filters returns every task, as before", %{column: column} do
      a = task_fixture(column, %{title: "One"})
      b = task_fixture(column, %{title: "Two"})

      assert column |> List.wrap() |> Tasks.list_tasks_by_columns() |> Map.get(column.id) |> ids() ==
               ids([a, b])
    end
  end
end
