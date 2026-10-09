defmodule Kanban.Tasks.CreationTest do
  @moduledoc """
  Regression tests for the task-creation paths (D81): an oversized varchar(255)
  field must surface as a changeset error and roll back the transaction, never
  raise a Postgres 22001 (string_data_right_truncation) and crash the request.
  """
  use Kanban.DataCase

  import Kanban.AccountsFixtures
  import Kanban.BoardsFixtures
  import Kanban.ColumnsFixtures

  alias Kanban.Tasks
  alias Kanban.Tasks.Task

  @over String.duplicate("a", 256)

  setup do
    user = user_fixture()
    board = board_fixture(user)
    column = column_fixture(board)
    %{user: user, column: column}
  end

  describe "create_task/2 length validation (D81)" do
    test "returns {:error, changeset} for an over-long title instead of raising",
         %{column: column} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Tasks.create_task(column, %{"title" => @over})

      assert %{title: ["should be at most 255 character(s)"]} = errors_on(changeset)

      over_query = from(t in Task, where: t.title == ^@over)
      refute Repo.exists?(over_query)
    end

    test "accepts a title of exactly 255 characters", %{column: column} do
      title = String.duplicate("a", 255)
      assert {:ok, %Task{}} = Tasks.create_task(column, %{"title" => title})
    end
  end

  describe "create_goal_with_tasks/3 rollback (D81)" do
    test "an over-long child title errors and rolls back every sibling, without raising",
         %{column: column} do
      goal_attrs = %{"title" => "Goal D81", "type" => "goal", "priority" => "medium"}

      children = [
        %{"title" => "Valid child D81", "type" => "work"},
        %{"title" => @over, "type" => "work"}
      ]

      result = Tasks.create_goal_with_tasks(column, goal_attrs, children)

      # An error tuple (not a raised 22001) — reaching this line proves no raise.
      assert elem(result, 0) == :error

      # The transaction rolled back: neither the goal nor the valid sibling persisted.
      goal_query = from(t in Task, where: t.title == "Goal D81")
      sibling_query = from(t in Task, where: t.title == "Valid child D81")
      refute Repo.exists?(goal_query)
      refute Repo.exists?(sibling_query)
    end
  end

  # D352: an unrecognised task type used to reach String.to_existing_atom/1 in
  # Creation.normalize_type/1, which raised ArgumentError (a 500 at the API) for a
  # string with no existing atom, and handed an existing-atom string like "task"
  # to the WIP-limit decision. Every unrecognised type must now return a type
  # changeset error and persist nothing.
  describe "unrecognised task type (D352)" do
    defp unique_type, do: "no_such_type_d352_#{System.unique_integer([:positive])}"

    defp persisted?(title), do: from(t in Task, where: t.title == ^title) |> Repo.exists?()

    test "api_create_task/2 with a type string that has no atom returns a type error, never raises",
         %{column: column} do
      type = unique_type()

      # Guarantees the regression input: the old String.to_existing_atom/1 call
      # raises on exactly this value.
      assert_raise ArgumentError, fn -> String.to_existing_atom(type) end

      assert {:error, %Ecto.Changeset{} = changeset} =
               Tasks.api_create_task(column, %{"title" => "D352 no atom", "type" => type})

      assert %{type: ["is invalid"]} = errors_on(changeset)
      refute persisted?("D352 no atom")
    end

    test "api_create_task/2 with existing-atom invalid strings returns a type error",
         %{column: column} do
      for type <- ["task", "bug", "epic"] do
        title = "D352 #{type}"

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Tasks.api_create_task(column, %{"title" => title, "type" => type})

        assert %{type: ["is invalid"]} = errors_on(changeset)
        refute persisted?(title)
      end
    end

    test "create_task/2 with an invalid string type returns a type error instead of raising",
         %{column: column} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Tasks.create_task(column, %{"title" => "D352 create", "type" => unique_type()})

      assert %{type: ["is invalid"]} = errors_on(changeset)
      refute persisted?("D352 create")
    end

    test "api_create_task/2 rejects case and whitespace variants of a valid type",
         %{column: column} do
      for type <- ["Work", "WORK", " work", "work ", "Defect", "GOAL"] do
        title = "D352 variant #{inspect(type)}"

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Tasks.api_create_task(column, %{"title" => title, "type" => type})

        assert %{type: [_]} = errors_on(changeset)
        refute persisted?(title)
      end

      assert {:ok, %Task{type: :work}} =
               Tasks.api_create_task(column, %{"title" => "D352 exact", "type" => "work"})
    end

    test "api_create_task/2 handles empty, nil and non-string type without raising",
         %{column: column} do
      for type <- [nil, 42, ["work"], %{"value" => "work"}] do
        title = "D352 odd #{inspect(type)}"

        assert {:error, %Ecto.Changeset{} = changeset} =
                 Tasks.api_create_task(column, %{"title" => title, "type" => type})

        assert %{type: [_]} = errors_on(changeset)
        refute persisted?(title)
      end

      # An empty or whitespace-only string is rejected as blank rather than
      # being cast to the :work default by Ecto's empty-value handling.
      for {type, title} <- [{"", "D352 empty"}, {"   ", "D352 blank"}] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Tasks.api_create_task(column, %{"title" => title, "type" => type})

        assert %{type: ["can't be blank"]} = errors_on(changeset)
        refute persisted?(title)
      end

      # An omitted type key still defaults to work.
      assert {:ok, %Task{type: :work}} =
               Tasks.api_create_task(column, %{"title" => "D352 omitted"})
    end

    test "valid strings and atoms still create every type", %{column: column} do
      for type <- ["work", "defect", "goal", :work, :defect, :goal] do
        title = "D352 valid #{inspect(type)}"

        assert {:ok, %Task{} = task} =
                 Tasks.api_create_task(column, %{"title" => title, "type" => type})

        assert Atom.to_string(task.type) == to_string(type)
      end
    end

    test "WIP limits still apply to work and defect, and goals still skip them",
         %{user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 1})

      assert {:ok, _} = Tasks.api_create_task(column, %{"title" => "D352 fill", "type" => "work"})

      assert {:error, :wip_limit_reached} =
               Tasks.api_create_task(column, %{"title" => "D352 over w", "type" => "work"})

      assert {:error, :wip_limit_reached} =
               Tasks.api_create_task(column, %{"title" => "D352 over d", "type" => :defect})

      assert {:ok, %Task{type: :goal}} =
               Tasks.api_create_task(column, %{"title" => "D352 goal", "type" => "goal"})
    end

    test "an invalid type in a full WIP column returns the type error, not :wip_limit_reached",
         %{user: user} do
      board = board_fixture(user)
      column = column_fixture(board, %{wip_limit: 1})

      assert {:ok, _} = Tasks.api_create_task(column, %{"title" => "D352 fill", "type" => "work"})

      for type <- ["task", unique_type(), "", "   ", nil] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Tasks.api_create_task(column, %{"title" => "D352 wip invalid", "type" => type})

        assert %{type: [_]} = errors_on(changeset)
      end

      refute persisted?("D352 wip invalid")
    end

    test "api_create_goal_with_tasks/3 with an invalid child type persists no goal or child",
         %{column: column} do
      goal_attrs = %{"title" => "Goal D352", "type" => "goal"}

      # The bad child at the first, middle and last of three positions, for each
      # kind of invalid value; every combination rolls the whole goal back.
      for bad_type <- ["bug", unique_type(), nil, ""], position <- 0..2 do
        valid = [
          %{"title" => "Valid child D352 a", "type" => "work"},
          %{"title" => "Valid child D352 b", "type" => "defect"}
        ]

        children =
          List.insert_at(valid, position, %{"title" => "Bad child D352", "type" => bad_type})

        assert {:error, _operation, %Ecto.Changeset{} = changeset} =
                 Tasks.api_create_goal_with_tasks(column, goal_attrs, children)

        assert %{type: [_]} = errors_on(changeset)

        for title <- ["Goal D352", "Valid child D352 a", "Valid child D352 b", "Bad child D352"] do
          refute persisted?(title),
                 "#{title} persisted (type #{inspect(bad_type)}, position #{position})"
        end
      end
    end
  end

  describe "a goal cannot contain a goal (D354)" do
    # A child of type goal used to be inserted with its parent's own G
    # identifier: the child identifiers were pre-generated from the database
    # before the parent row existed. Stride is two-level, so the child is now
    # refused before any identifier is generated or any row is written.
    alias Kanban.Tasks.Task.HierarchyValidations

    defp nested_goal_message, do: HierarchyValidations.nested_goal_message()

    defp column_task_count(column),
      do: from(t in Task, where: t.column_id == ^column.id) |> Repo.aggregate(:count)

    defp duplicate_identifiers(column) do
      from(t in Task,
        where: t.column_id == ^column.id,
        group_by: t.identifier,
        having: count(t.id) > 1,
        select: t.identifier
      )
      |> Repo.all()
    end

    for create_fun <- [:create_goal_with_tasks, :api_create_goal_with_tasks] do
      test "#{create_fun}/3: nested goal rejected at any position, writing nothing",
           %{column: column} do
        goal_attrs = %{"title" => "D354 parent", "type" => "goal"}

        for goal_type <- ["goal", :goal], position <- 0..2 do
          siblings = [
            %{"title" => "D354 work child", "type" => "work"},
            %{"title" => "D354 defect child", "type" => "defect"}
          ]

          children =
            List.insert_at(siblings, position, %{"title" => "D354 child", "type" => goal_type})

          assert {:error, {:child_task, ^position}, %Ecto.Changeset{} = changeset} =
                   apply(Tasks, unquote(create_fun), [column, goal_attrs, children])

          assert errors_on(changeset) == %{type: [nested_goal_message()]}
        end

        assert column_task_count(column) == 0
      end
    end

    test "the child-goal check is the transaction's first step, ahead of every other validation",
         %{column: column} do
      # A child insert would also report the over-long title; the hierarchy
      # step fails first, before any child changeset or identifier exists.
      assert {:error, {:child_task, 0}, changeset} =
               Tasks.api_create_goal_with_tasks(column, %{"title" => "D354 early"}, [
                 %{"title" => @over, "type" => "goal"}
               ])

      assert errors_on(changeset) == %{type: [nested_goal_message()]}
    end

    test "several child goals are rejected at the first one", %{column: column} do
      children = [
        %{"title" => "D354 w", "type" => "work"},
        %{"title" => "D354 g1", "type" => "goal"},
        %{"title" => "D354 g2", "type" => "goal"}
      ]

      assert {:error, {:child_task, 1}, %Ecto.Changeset{}} =
               Tasks.api_create_goal_with_tasks(column, %{"title" => "D354 p"}, children)

      assert column_task_count(column) == 0
    end

    test "a rejected request consumes no identifier, so the next goal on an empty board is G1",
         %{column: column} do
      assert {:error, _, _} =
               Tasks.api_create_goal_with_tasks(column, %{"title" => "D354 rejected"}, [
                 %{"title" => "D354 nested", "type" => "goal"}
               ])

      assert {:ok, %{goal: %Task{identifier: "G1"}, child_tasks: []}} =
               Tasks.api_create_goal_with_tasks(column, %{"title" => "D354 first goal"}, [])
    end

    test "goal with work and defect children is still created, with sequential identifiers and index dependencies",
         %{column: column} do
      children = [
        %{"title" => "D354 a", "type" => "work"},
        %{"title" => "D354 b", "type" => "defect", "dependencies" => [0]},
        %{"title" => "D354 c", "type" => "work", "dependencies" => [0, 1]}
      ]

      assert {:ok, %{goal: goal, child_tasks: [a, b, c]}} =
               Tasks.create_goal_with_tasks(column, %{"title" => "D354 ok"}, children)

      assert goal.identifier == "G1"
      assert {a.identifier, b.identifier, c.identifier} == {"W1", "D1", "W2"}
      assert b.dependencies == [a.identifier]
      assert c.dependencies == [a.identifier, b.identifier]
      assert Enum.all?([a, b, c], &(&1.parent_id == goal.id))
      assert duplicate_identifiers(column) == []
    end

    for create_fun <- [:create_goal_with_tasks, :api_create_goal_with_tasks] do
      test "#{create_fun}/3: goal with no children is still created", %{column: column} do
        assert {:ok,
                %{goal: %Task{type: :goal, identifier: "G1", parent_id: nil}, child_tasks: []}} =
                 apply(Tasks, unquote(create_fun), [column, %{"title" => "D354 lone goal"}, []])

        assert {:ok, %{goal: %Task{identifier: "G2"}, child_tasks: []}} =
                 apply(Tasks, unquote(create_fun), [column, %{"title" => "D354 lone goal 2"}])

        assert column_task_count(column) == 2
        assert duplicate_identifiers(column) == []
      end
    end

    test "create_task/2 refuses a goal with a parent", %{column: column} do
      {:ok, parent} = Tasks.create_task(column, %{"title" => "D354 top", "type" => "goal"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Tasks.create_task(column, %{
                 "title" => "D354 nested single",
                 "type" => "goal",
                 "parent_id" => parent.id
               })

      assert errors_on(changeset) == %{type: [nested_goal_message()]}
      refute persisted?("D354 nested single")

      assert {:ok, %Task{type: :work}} =
               Tasks.create_task(column, %{"title" => "D354 child ok", "parent_id" => parent.id})
    end

    test "update_task/2 refuses to give a goal a parent or turn a child into a goal",
         %{column: column} do
      {:ok, goal_a} = Tasks.create_task(column, %{"title" => "D354 goal a", "type" => "goal"})
      {:ok, goal_b} = Tasks.create_task(column, %{"title" => "D354 goal b", "type" => "goal"})

      {:ok, child} =
        Tasks.create_task(column, %{"title" => "D354 child", "parent_id" => goal_a.id})

      assert {:error, changeset} = Tasks.update_task(goal_b, %{parent_id: goal_a.id})
      assert errors_on(changeset) == %{type: [nested_goal_message()]}

      assert {:error, changeset} = Tasks.update_task(child, %{type: :goal})
      assert errors_on(changeset) == %{type: [nested_goal_message()]}

      assert {:error, changeset} = Tasks.api_update_task(child, %{"type" => "goal"})
      assert errors_on(changeset) == %{type: [nested_goal_message()]}

      assert {:ok, %Task{type: :defect}} = Tasks.api_update_task(child, %{"type" => "defect"})
      assert {:ok, %Task{type: :goal, parent_id: nil}} = Tasks.update_task(goal_b, %{title: "x"})
    end

    test "a nested goal written before D354, sharing its parent's identifier, stays editable",
         %{column: column} do
      {:ok, parent} =
        Tasks.create_task(column, %{"title" => "D354 legacy parent", "type" => "goal"})

      # The real shape of the pre-D354 rows: the child goal holds its parent's G.
      legacy =
        Repo.insert!(%Task{
          title: "D354 legacy nested",
          type: :goal,
          parent_id: parent.id,
          column_id: column.id,
          position: 99,
          identifier: parent.identifier
        })

      assert duplicate_identifiers(column) == [parent.identifier]

      assert {:ok, %Task{title: "D354 legacy renamed"}} =
               Tasks.update_task(legacy, %{title: "D354 legacy renamed"})

      # The next generated goal is still the next free number, not a third copy.
      assert {:ok, %{goal: %Task{identifier: "G2"}}} =
               Tasks.api_create_goal_with_tasks(column, %{"title" => "D354 after legacy"}, [])

      assert duplicate_identifiers(column) == [parent.identifier]
    end

    test "a rejected request on a board with goals leaves the next G number unchanged",
         %{column: column} do
      for i <- 1..2 do
        assert {:ok, _} =
                 Tasks.api_create_goal_with_tasks(column, %{"title" => "D354 existing #{i}"}, [])
      end

      assert {:error, {:child_task, 0}, _} =
               Tasks.api_create_goal_with_tasks(column, %{"title" => "D354 refused"}, [
                 %{"title" => "D354 refused child", "type" => "goal"}
               ])

      assert {:ok, %{goal: %Task{identifier: "G3"}}} =
               Tasks.api_create_goal_with_tasks(column, %{"title" => "D354 next"}, [])
    end

    test "a child goal ahead of a dependent work child is rejected at its own index",
         %{column: column} do
      children = [
        %{"title" => "D354 dep work", "type" => "work"},
        %{"title" => "D354 dep goal", "type" => "goal"},
        %{"title" => "D354 dep on 0", "type" => "work", "dependencies" => [0]}
      ]

      assert {:error, {:child_task, 1}, changeset} =
               Tasks.api_create_goal_with_tasks(column, %{"title" => "D354 dep parent"}, children)

      assert errors_on(changeset) == %{type: [nested_goal_message()]}
      assert column_task_count(column) == 0
    end

    for create_fun <- [:create_goal_with_tasks, :api_create_goal_with_tasks] do
      test "#{create_fun}/3 rejects a child that carries tasks of its own", %{column: column} do
        message = HierarchyValidations.nested_tasks_message()

        for grandchild_type <- ["work", "goal"] do
          children = [
            %{"title" => "D354 plain child", "type" => "work"},
            %{
              "title" => "D354 child with tasks",
              "type" => "defect",
              "tasks" => [%{"title" => "D354 grandchild", "type" => grandchild_type}]
            }
          ]

          assert {:error, {:child_task, 1}, changeset} =
                   apply(Tasks, unquote(create_fun), [column, %{"title" => "D354 g"}, children])

          assert errors_on(changeset) == %{tasks: [message]}
        end

        assert column_task_count(column) == 0

        # An empty tasks list on a child is not nesting and is still accepted.
        assert {:ok, %{child_tasks: [%Task{type: :work}]}} =
                 apply(Tasks, unquote(create_fun), [
                   column,
                   %{"title" => "D354 empty nested"},
                   [%{"title" => "D354 empty child", "type" => "work", "tasks" => []}]
                 ])
      end
    end
  end

  describe ":before_broadcast" do
    setup %{column: column} do
      Phoenix.PubSub.subscribe(Kanban.PubSub, "board:#{column.board_id}")
      :ok
    end

    test "api_create_task/3 runs it with the saved task before :task_created",
         %{column: column} do
      test_pid = self()
      callback = fn task -> send(test_pid, {:before_broadcast, task.id}) end

      {:ok, task} =
        Tasks.api_create_task(column, %{"title" => "Hooked", "type" => "work"},
          before_broadcast: callback
        )

      assert next_message() == {:before_broadcast, task.id}
      assert {Kanban.Tasks, :task_created, %Task{id: id}} = next_message()
      assert id == task.id
    end

    test "api_create_goal_with_tasks/4 runs it with the goal and children before any broadcast",
         %{column: column} do
      test_pid = self()

      callback = fn goal, children ->
        send(test_pid, {:before_broadcast, goal.id, Enum.map(children, & &1.title)})
      end

      {:ok, %{goal: goal}} =
        Tasks.api_create_goal_with_tasks(
          column,
          %{"title" => "Hooked goal"},
          [%{"title" => "Hooked child", "type" => "work"}],
          before_broadcast: callback
        )

      assert next_message() == {:before_broadcast, goal.id, ["Hooked child"]}
      assert {Kanban.Tasks, :task_created, %Task{id: id}} = next_message()
      assert id == goal.id
    end

    test "without it the task is created and broadcast as before", %{column: column} do
      {:ok, task} = Tasks.api_create_task(column, %{"title" => "Plain", "type" => "work"})
      assert {Kanban.Tasks, :task_created, %Task{id: id}} = next_message()
      assert id == task.id
    end

    test "a failed create never runs it", %{column: column} do
      test_pid = self()

      assert {:error, %Ecto.Changeset{}} =
               Tasks.api_create_task(column, %{"title" => @over},
                 before_broadcast: fn _ -> send(test_pid, :ran) end
               )

      refute_received :ran
    end
  end

  # Only the hook's message and board broadcasts; fixtures also mail the test.
  defp next_message do
    receive do
      {:before_broadcast, _, _} = message -> message
      {:before_broadcast, _} = message -> message
      {Kanban.Tasks, _event, _task} = message -> message
    after
      500 -> :no_message
    end
  end
end
