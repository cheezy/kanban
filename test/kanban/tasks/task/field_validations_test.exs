defmodule Kanban.Tasks.Task.FieldValidationsTest do
  @moduledoc """
  Unit tests for `Kanban.Tasks.Task.FieldValidations.validate_id_ranges/1`. The
  create and update paths that run it are covered in tasks_test.exs.
  """
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [cast: 3]

  alias Kanban.Tasks.Task
  alias Kanban.Tasks.Task.FieldValidations

  @max_bigint 9_223_372_036_854_775_807
  @id_fields [
    :column_id,
    :assigned_to_id,
    :parent_id,
    :target_id,
    :created_by_id,
    :completed_by_id,
    :reviewed_by_id,
    :archived_by_id,
    :duplicate_of_id
  ]

  defp validate(attrs) do
    %Task{}
    |> cast(attrs, @id_fields)
    |> FieldValidations.validate_id_ranges()
  end

  describe "validate_id_ranges/1" do
    test "an id beyond the Postgres bigint range is an error on its own field" do
      for field <- @id_fields do
        changeset = validate(%{field => "99999999999999999999"})

        assert {"is not a valid id", _} = changeset.errors[field]
        assert Keyword.keys(changeset.errors) == [field]
      end
    end

    test "zero and negative ids are errors" do
      for value <- [0, -1] do
        refute validate(%{parent_id: value}).valid?
      end
    end

    test "the largest bigint, an ordinary id and nil are valid" do
      for value <- [@max_bigint, 1, 42, nil] do
        assert validate(%{parent_id: value, column_id: value}).valid?
      end
    end

    test "a field that is not being changed is not checked" do
      assert %Task{parent_id: @max_bigint + 1}
             |> cast(%{title: "x"}, [:title])
             |> FieldValidations.validate_id_ranges()
             |> Map.fetch!(:valid?)
    end
  end
end
