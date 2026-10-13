defmodule Kanban.Tasks.InterventionTransactionsTest do
  use Kanban.DataCase, async: true

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.TasksFixtures
  import Kanban.TelemetryHelpers

  alias Kanban.Boards
  alias Kanban.Columns
  alias Kanban.Tasks
  alias Kanban.Tasks.InterventionTransactions
  alias Kanban.Tasks.Task

  setup do
    owner = user_fixture()
    member = user_fixture()
    board = ai_optimized_board_fixture(owner)
    {:ok, _} = Boards.add_user_to_board(board, member, :modify, owner)
    cols = board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
    goal = task_fixture(cols["Ready"], %{type: :goal})

    %{owner: owner, member: member, board: board, cols: cols, goal: goal}
  end

  describe "preview_children/1" do
    test "returns only open children in not-started columns", %{cols: cols, goal: goal} do
      backlog = task_fixture(cols["Backlog"], %{parent_id: goal.id})
      ready = task_fixture(cols["Ready"], %{parent_id: goal.id})
      claimed = task_fixture(cols["Backlog"], %{parent_id: goal.id})
      claim!(claimed)
      cols["Backlog"] |> task_fixture(%{parent_id: goal.id}) |> archive!()
      task_fixture(cols["Doing"], %{parent_id: goal.id, status: :in_progress})
      task_fixture(cols["Review"], %{parent_id: goal.id, status: :in_progress})

      task_fixture(cols["Done"], %{
        parent_id: goal.id,
        status: :completed,
        completed_at: DateTime.utc_now()
      })

      other_goal = task_fixture(cols["Ready"], %{type: :goal})
      task_fixture(cols["Backlog"], %{parent_id: other_goal.id})

      ids = goal |> InterventionTransactions.preview_children() |> Enum.map(& &1.id)

      assert Enum.sort(ids) == Enum.sort([backlog.id, ready.id])
    end

    test "preview_children returns an empty list when the goal has no not-started children",
         %{cols: cols, goal: goal} do
      assert InterventionTransactions.preview_children(goal) == []

      task_fixture(cols["Doing"], %{parent_id: goal.id, status: :in_progress})
      cols["Backlog"] |> task_fixture(%{parent_id: goal.id}) |> claim!()

      assert InterventionTransactions.preview_children(goal) == []
    end

    test "takes no FOR UPDATE row lock", %{cols: cols, goal: goal} do
      task_fixture(cols["Backlog"], %{parent_id: goal.id})
      attach_telemetry([:kanban, :repo, :query])

      assert [_child] = InterventionTransactions.preview_children(goal)

      sqls = repo_sql()
      assert sqls != []
      refute Enum.any?(sqls, &(&1 =~ "FOR UPDATE"))
    end

    test "the write path, by contrast, re-reads candidates under FOR UPDATE", %{
      cols: cols,
      goal: goal
    } do
      task_fixture(cols["Backlog"], %{parent_id: goal.id})
      attach_telemetry([:kanban, :repo, :query])

      assert {:ok, _} = InterventionTransactions.reprioritize(goal, :high)

      assert Enum.any?(repo_sql(), &(&1 =~ "FOR UPDATE"))
    end
  end

  describe "undo/4" do
    test "undo touches only the given child ids and restores each to its own prior value",
         %{cols: cols, goal: goal, owner: owner, member: member} do
      goal = assign!(goal, member)
      a = cols["Backlog"] |> task_fixture(%{parent_id: goal.id}) |> assign!(member)
      b = cols["Ready"] |> task_fixture(%{parent_id: goal.id}) |> assign!(member)
      bystander = cols["Ready"] |> task_fixture(%{parent_id: goal.id}) |> assign!(member)

      priors = %{goal.id => nil, a.id => owner.id, b.id => nil}
      goal_id = goal.id

      assert {:ok, %{moved: [%Task{id: ^goal_id} | _] = moved, skipped: []}} =
               InterventionTransactions.undo(goal, [a.id, b.id], :assigned_to_id, priors)

      assert moved |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([goal.id, a.id, b.id])
      assert reload(goal).assigned_to_id == nil
      assert reload(a).assigned_to_id == owner.id
      assert reload(b).assigned_to_id == nil
      assert reload(bystander).assigned_to_id == member.id
      assert assignment_to(a.id) == [owner.id]
      assert assignment_to(bystander.id) == []
    end

    test "restores each task's own prior priority", %{cols: cols, goal: goal} do
      goal = set_priority!(goal, :critical)
      child = cols["Backlog"] |> task_fixture(%{parent_id: goal.id}) |> set_priority!(:critical)

      priors = %{goal.id => :medium, child.id => :low}

      assert {:ok, %{moved: [_, _], skipped: []}} =
               InterventionTransactions.undo(goal, [child.id], :priority, priors)

      assert reload(goal).priority == :medium
      assert reload(child).priority == :low
      assert priority_changes_to(goal.id) == ["medium"]
      assert priority_changes_to(child.id) == ["low"]
    end

    test "a listed child claimed since lands in :skipped and keeps its value", %{
      cols: cols,
      goal: goal,
      owner: owner,
      member: member
    } do
      child = cols["Backlog"] |> task_fixture(%{parent_id: goal.id}) |> assign!(member)
      claim!(child)
      child_id = child.id

      assert {:ok, %{moved: [_goal], skipped: [%Task{id: ^child_id}]}} =
               InterventionTransactions.undo(
                 goal,
                 [child.id],
                 :assigned_to_id,
                 %{goal.id => owner.id, child.id => nil}
               )

      assert reload(child).assigned_to_id == member.id
      assert reload(goal).assigned_to_id == owner.id
    end

    test "with no child ids restores only the goal", %{goal: goal, member: member} do
      goal = assign!(goal, member)
      goal_id = goal.id

      assert {:ok, %{moved: [%Task{id: ^goal_id, assigned_to_id: nil}], skipped: []}} =
               InterventionTransactions.undo(goal, [], :assigned_to_id, %{goal.id => nil})
    end

    test "restores a prior assignee who is no longer on the board, with no membership check",
         %{cols: cols, goal: goal, member: member} do
      off_board = user_fixture()
      child = cols["Backlog"] |> task_fixture(%{parent_id: goal.id}) |> assign!(member)
      priors = %{goal.id => off_board.id, child.id => off_board.id}

      assert {:ok, %{moved: [_, _], skipped: []}} =
               InterventionTransactions.undo(goal, [child.id], :assigned_to_id, priors)

      assert reload(goal).assigned_to_id == off_board.id
      assert reload(child).assigned_to_id == off_board.id
    end

    test "passes a failed write's changeset through and rolls back", %{cols: cols, goal: goal} do
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :low})
      priors = %{goal.id => :high, child.id => :urgent}

      assert {:error, %Ecto.Changeset{}} =
               InterventionTransactions.undo(goal, [child.id], :priority, priors)

      assert reload(goal).priority == goal.priority
      assert reload(child).priority == :low
      assert priority_changes_to(goal.id) == []
      assert priority_changes_to(child.id) == []
    end
  end

  describe "reassign/2" do
    test "returns {:error, :assignee_not_on_board} for an off-board user and rolls back", %{
      cols: cols,
      goal: goal
    } do
      outsider = user_fixture()
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id})

      assert {:error, :assignee_not_on_board} =
               InterventionTransactions.reassign(goal, outsider.id)

      assert reload(goal).assigned_to_id == nil
      assert reload(child).assigned_to_id == nil
      assert assignment_to(goal.id) == []
      assert assignment_to(child.id) == []
    end

    test "nil unassigns the goal and its children without a membership check", %{
      cols: cols,
      goal: goal,
      member: member
    } do
      goal = assign!(goal, member)
      child = cols["Backlog"] |> task_fixture(%{parent_id: goal.id}) |> assign!(member)

      assert {:ok, %{moved: [_, _], skipped: []}} = InterventionTransactions.reassign(goal, nil)

      assert reload(goal).assigned_to_id == nil
      assert reload(child).assigned_to_id == nil
    end

    test "a goal with no children returns only the goal in moved and broadcasts it", %{
      board: board,
      goal: goal,
      member: member
    } do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{board.id}")
      goal_id = goal.id
      member_id = member.id

      assert {:ok, %{moved: [%Task{id: ^goal_id, assigned_to_id: ^member_id}], skipped: []}} =
               InterventionTransactions.reassign(goal, member.id)

      assert_receive {Kanban.Tasks, :task_updated, %Task{id: ^goal_id}}
      assert assignment_to(goal.id) == [member.id]
    end
  end

  describe "reprioritize/2" do
    test "moves the goal and open children and writes priority_change history for each", %{
      cols: cols,
      goal: goal
    } do
      backlog = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :low})
      ready = task_fixture(cols["Ready"], %{parent_id: goal.id, priority: :low})
      claimed = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :low})
      claim!(claimed)

      doing =
        task_fixture(cols["Doing"], %{parent_id: goal.id, status: :in_progress, priority: :low})

      claimed_id = claimed.id

      assert {:ok, %{moved: [moved_goal | moved_children], skipped: [%Task{id: ^claimed_id}]}} =
               InterventionTransactions.reprioritize(goal, :critical)

      assert moved_goal.id == goal.id

      assert moved_children |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([backlog.id, ready.id])

      for task <- [goal, backlog, ready] do
        assert reload(task).priority == :critical
        assert priority_changes_to(task.id) == ["critical"]
      end

      assert reload(claimed).priority == :low
      assert reload(doing).priority == :low
    end

    test "passes a failed write's changeset through and rolls back", %{cols: cols, goal: goal} do
      child = task_fixture(cols["Backlog"], %{parent_id: goal.id, priority: :low})

      assert {:error, %Ecto.Changeset{}} = InterventionTransactions.reprioritize(goal, :urgent)

      assert reload(child).priority == :low
      assert priority_changes_to(goal.id) == []
    end
  end

  defp reload(%Task{id: id}), do: Repo.get!(Task, id)

  defp claim!(%Task{id: id} = task) do
    {1, _} = from(t in Task, where: t.id == ^id) |> Repo.update_all(set: [status: :in_progress])
    task
  end

  defp archive!(%Task{id: id} = task) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    {1, _} = from(t in Task, where: t.id == ^id) |> Repo.update_all(set: [archived_at: now])
    task
  end

  defp assign!(%Task{} = task, user) do
    task |> Ecto.Changeset.change(assigned_to_id: user.id) |> Repo.update!()
  end

  defp set_priority!(%Task{} = task, priority) do
    task |> Ecto.Changeset.change(priority: priority) |> Repo.update!()
  end

  defp assignment_to(task_id) do
    task_id
    |> Tasks.get_task_with_history!()
    |> Map.fetch!(:task_histories)
    |> Enum.filter(&(&1.type == :assignment))
    |> Enum.map(& &1.to_user_id)
  end

  defp priority_changes_to(task_id) do
    task_id
    |> Tasks.get_task_with_history!()
    |> Map.fetch!(:task_histories)
    |> Enum.filter(&(&1.type == :priority_change))
    |> Enum.map(& &1.to_priority)
  end

  # Drains the repo query events this test process received since
  # attach_telemetry/1, returning their SQL.
  defp repo_sql do
    receive do
      {:telemetry_event, [:kanban, :repo, :query], _measurements, %{query: sql}} ->
        [sql | repo_sql()]
    after
      0 -> []
    end
  end
end
