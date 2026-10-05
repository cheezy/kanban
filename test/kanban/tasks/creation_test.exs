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
end
