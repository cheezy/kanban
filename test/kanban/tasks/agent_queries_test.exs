defmodule Kanban.Tasks.AgentQueriesTest do
  use Kanban.DataCase, async: true

  import Ecto.Query
  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures

  alias Kanban.Accounts.Scope
  alias Kanban.Repo
  alias Kanban.Tasks
  alias Kanban.Tasks.AgentQueries
  alias Kanban.Tasks.Task

  describe "get_next_task/2 excludes human tasks" do
    setup do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))

      %{user: user, board: board, ready_column: ready_column}
    end

    test "does not return tasks with human_task=true", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, _human_task} =
        Tasks.create_task(column, %{
          "title" => "Human Only Task",
          "status" => "open",
          "human_task" => true,
          "created_by_id" => user.id
        })

      result = AgentQueries.get_next_task([], board.id)

      assert result == nil
    end

    test "returns tasks with human_task=false", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Agent Task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => user.id
        })

      result = AgentQueries.get_next_task([], board.id)

      assert result.id == task.id
    end

    test "skips human tasks and returns next eligible task", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, _human_task} =
        Tasks.create_task(column, %{
          "title" => "Human Only Task",
          "status" => "open",
          "human_task" => true,
          "priority" => "critical",
          "created_by_id" => user.id
        })

      {:ok, agent_task} =
        Tasks.create_task(column, %{
          "title" => "Agent Task",
          "status" => "open",
          "human_task" => false,
          "priority" => "low",
          "created_by_id" => user.id
        })

      result = AgentQueries.get_next_task([], board.id)

      assert result.id == agent_task.id
    end

    test "returns nil when all available tasks are human_task=true", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, _task1} =
        Tasks.create_task(column, %{
          "title" => "Human Task 1",
          "status" => "open",
          "human_task" => true,
          "created_by_id" => user.id
        })

      {:ok, _task2} =
        Tasks.create_task(column, %{
          "title" => "Human Task 2",
          "status" => "open",
          "human_task" => true,
          "created_by_id" => user.id
        })

      result = AgentQueries.get_next_task([], board.id)

      assert result == nil
    end
  end

  describe "get_specific_task_for_claim/3 excludes human tasks" do
    setup do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))

      %{user: user, board: board, ready_column: ready_column}
    end

    test "rejects tasks with human_task=true", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, human_task} =
        Tasks.create_task(column, %{
          "title" => "Human Only Task",
          "status" => "open",
          "human_task" => true,
          "created_by_id" => user.id
        })

      result =
        AgentQueries.get_specific_task_for_claim(human_task.identifier, [], board.id)

      assert result == nil
    end

    test "allows tasks with human_task=false", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, agent_task} =
        Tasks.create_task(column, %{
          "title" => "Agent Task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => user.id
        })

      result =
        AgentQueries.get_specific_task_for_claim(agent_task.identifier, [], board.id)

      assert result.id == agent_task.id
    end
  end

  describe "get_next_task/3 with assignment filter" do
    setup do
      alice = user_fixture()
      bob = user_fixture()
      board = ai_optimized_board_fixture(alice)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))

      %{alice: alice, bob: bob, board: board, ready_column: ready_column}
    end

    test "returns a task assigned to the requesting user", %{
      alice: alice,
      board: board,
      ready_column: column
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Alice's task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => alice.id,
          "assigned_to_id" => alice.id
        })

      result = AgentQueries.get_next_task([], board.id, alice.id)

      assert result.id == task.id
    end

    test "does not return a task assigned to a different user", %{
      alice: alice,
      bob: bob,
      board: board,
      ready_column: column
    } do
      {:ok, _task} =
        Tasks.create_task(column, %{
          "title" => "Alice's task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => alice.id,
          "assigned_to_id" => alice.id
        })

      result = AgentQueries.get_next_task([], board.id, bob.id)

      assert result == nil
    end

    test "returns unassigned tasks to any user", %{
      alice: alice,
      bob: bob,
      board: board,
      ready_column: column
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Open task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => alice.id
        })

      assert AgentQueries.get_next_task([], board.id, alice.id).id == task.id
      assert AgentQueries.get_next_task([], board.id, bob.id).id == task.id
    end

    test "user_id=nil disables the assignment filter (legacy behavior)", %{
      alice: alice,
      board: board,
      ready_column: column
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Alice's task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => alice.id,
          "assigned_to_id" => alice.id
        })

      assert AgentQueries.get_next_task([], board.id).id == task.id
    end
  end

  describe "get_specific_task_for_claim/4 with assignment filter" do
    setup do
      alice = user_fixture()
      bob = user_fixture()
      board = ai_optimized_board_fixture(alice)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))

      %{alice: alice, bob: bob, board: board, ready_column: ready_column}
    end

    test "returns the task when assigned to the requesting user", %{
      alice: alice,
      board: board,
      ready_column: column
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Alice's task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => alice.id,
          "assigned_to_id" => alice.id
        })

      result =
        AgentQueries.get_specific_task_for_claim(task.identifier, [], board.id, alice.id)

      assert result.id == task.id
    end

    test "returns nil when the task is assigned to a different user", %{
      alice: alice,
      bob: bob,
      board: board,
      ready_column: column
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Alice's task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => alice.id,
          "assigned_to_id" => alice.id
        })

      result =
        AgentQueries.get_specific_task_for_claim(task.identifier, [], board.id, bob.id)

      assert result == nil
    end

    test "returns unassigned tasks regardless of requesting user", %{
      alice: alice,
      bob: bob,
      board: board,
      ready_column: column
    } do
      {:ok, task} =
        Tasks.create_task(column, %{
          "title" => "Open task",
          "status" => "open",
          "human_task" => false,
          "created_by_id" => alice.id
        })

      assert AgentQueries.get_specific_task_for_claim(task.identifier, [], board.id, alice.id).id ==
               task.id

      assert AgentQueries.get_specific_task_for_claim(task.identifier, [], board.id, bob.id).id ==
               task.id
    end
  end

  describe "archived tasks are not claimable" do
    setup do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready_column = Enum.find(columns, &(&1.name == "Ready"))
      %{user: user, board: board, ready_column: ready_column}
    end

    test "get_next_task does not return an archived task sitting in Ready", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, archived} =
        Tasks.create_task(column, %{
          "title" => "Archived",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, _} = Tasks.archive_task(archived)

      assert AgentQueries.get_next_task([], board.id) == nil
    end

    test "get_next_task returns the live task when an archived one is also present", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, archived} =
        Tasks.create_task(column, %{
          "title" => "Archived",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, _} = Tasks.archive_task(archived)

      {:ok, live} =
        Tasks.create_task(column, %{
          "title" => "Live",
          "status" => "open",
          "created_by_id" => user.id
        })

      assert AgentQueries.get_next_task([], board.id).id == live.id
    end

    test "get_specific_task_for_claim does not return an archived task by identifier", %{
      ready_column: column,
      board: board,
      user: user
    } do
      {:ok, archived} =
        Tasks.create_task(column, %{
          "title" => "Archived",
          "status" => "open",
          "created_by_id" => user.id
        })

      {:ok, _} = Tasks.archive_task(archived)

      assert AgentQueries.get_specific_task_for_claim(archived.identifier, [], board.id) == nil
    end

    test "get_next_task ignores key-file conflicts from archived in_progress tasks", %{
      ready_column: ready,
      board: board,
      user: user
    } do
      columns = Kanban.Columns.list_columns(board)
      doing = Enum.find(columns, &(&1.name == "Doing"))
      key_files = [%{"file_path" => "lib/kanban/shared.ex", "position" => 0}]

      # An ARCHIVED in_progress task in Doing touching the same file.
      {:ok, archived_doing} =
        Tasks.create_task(doing, %{
          "title" => "Old WIP",
          "status" => "in_progress",
          "key_files" => key_files,
          "created_by_id" => user.id
        })

      {:ok, _} = Tasks.archive_task(archived_doing)

      # A live Ready task touching the same file.
      {:ok, live} =
        Tasks.create_task(ready, %{
          "title" => "Live",
          "status" => "open",
          "key_files" => key_files,
          "created_by_id" => user.id
        })

      # The archived in-progress task must NOT register as a key-file conflict.
      assert AgentQueries.get_next_task([], board.id).id == live.id
    end
  end

  describe "get_next_task/2 priority ordering" do
    setup do
      user = user_fixture()
      board = ai_optimized_board_fixture(user)
      columns = Kanban.Columns.list_columns(board)
      ready = Enum.find(columns, &(&1.name == "Ready"))

      %{user: user, board: board, ready: ready, scope: Scope.for_user(user)}
    end

    test "returns the highest-priority eligible Ready task first, position breaking ties within a band",
         %{ready: ready, board: board, user: user} do
      # Insert in ascending-priority order so position order is the OPPOSITE of
      # priority order — proving priority dominates position.
      low = ready_task(ready, user, "low")
      medium = ready_task(ready, user, "medium")
      high = ready_task(ready, user, "high")
      critical = ready_task(ready, user, "critical")

      # Drain the queue by claiming each returned task; the sequence must be
      # strictly critical > high > medium > low.
      order =
        Enum.map(1..4, fn _ ->
          task = AgentQueries.get_next_task([], board.id)
          claim(task)
          task.id
        end)

      assert order == [critical.id, high.id, medium.id, low.id]
    end

    test "breaks ties within a priority band by ascending position", %{
      ready: ready,
      board: board,
      user: user
    } do
      first = ready_task(ready, user, "high")
      second = ready_task(ready, user, "high")

      # Same priority → the earlier-created (lower position) task claims first.
      assert AgentQueries.get_next_task([], board.id).id == first.id
      claim(first)
      assert AgentQueries.get_next_task([], board.id).id == second.id
    end

    test "reprioritizing a goal's child ahead of a peer changes the next claim", %{
      ready: ready,
      board: board,
      user: user,
      scope: scope
    } do
      {:ok, goal} =
        Tasks.create_task(ready, %{
          "title" => "Goal",
          "type" => "goal",
          "created_by_id" => user.id
        })

      child = ready_task(ready, user, "low", %{"parent_id" => goal.id})
      competitor = ready_task(ready, user, "high")

      # Baseline: the higher-priority competitor is claimed first.
      assert AgentQueries.get_next_task([], board.id).id == competitor.id

      # Raise the goal's not-started child to critical.
      assert {:ok, _} = Tasks.reprioritize_goal_unstarted(scope, goal, :critical)

      # The reprioritized child now outranks the competitor.
      assert AgentQueries.get_next_task([], board.id).id == child.id
    end
  end

  defp ready_task(column, user, priority, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          "title" => "Task #{System.unique_integer([:positive])}",
          "status" => "open",
          "priority" => priority,
          "created_by_id" => user.id
        },
        extra
      )

    {:ok, task} = Tasks.create_task(column, attrs)
    task
  end

  # Excludes a task from subsequent get_next_task results by giving it an
  # active (unexpired) claim, mimicking another agent picking it up.
  defp claim(%Task{id: id}) do
    future = DateTime.add(DateTime.utc_now(), 3600, :second)

    {1, _} =
      from(t in Task, where: t.id == ^id)
      |> Repo.update_all(set: [status: :in_progress, claim_expires_at: future])
  end
end
