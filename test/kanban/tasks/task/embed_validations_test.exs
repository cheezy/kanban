defmodule Kanban.Tasks.Task.EmbedValidationsTest do
  @moduledoc """
  Unit tests for the extracted embed validators (W1445). The full changeset
  pipelines are covered end-to-end by tasks_test.exs; these lock one rule per
  function directly, including the enhanced error strings.
  """
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Kanban.Schemas.Task.BehaviourTestRow
  alias Kanban.Schemas.Task.KeyFile
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.Task.EmbedValidations

  @matrix_shape_message "must be an array of objects with category, behaviour, test_name, type, status, and position fields"

  defp matrix_row(overrides \\ %{}) do
    Map.merge(
      %{
        "category" => "Happy path",
        "behaviour" => "claims an open task",
        "test_name" => "claims an open task",
        "type" => "unit",
        "status" => "planned",
        "position" => 0
      },
      overrides
    )
  end

  defp row_changeset(overrides \\ %{}) do
    EmbedValidations.validate_behaviour_test_row_embed(%BehaviourTestRow{}, matrix_row(overrides))
  end

  describe "validate_embed_type/3" do
    test "rejects a non-array key_files value with the field-specific message" do
      cs = Changeset.change(%Task{})

      result =
        EmbedValidations.validate_embed_type(cs, :key_files, %{"key_files" => "not a list"})

      assert {"must be an array of objects with file_path, note, and position fields", _} =
               result.errors[:key_files]
    end

    test "rejects an array with non-object verification_steps items" do
      cs = Changeset.change(%Task{})

      result =
        EmbedValidations.validate_embed_type(cs, :verification_steps, %{
          "verification_steps" => ["oops"]
        })

      assert {"must be an array of objects with step_type, step_text, expected_result, and position fields",
              _} = result.errors[:verification_steps]
    end

    test "passes when the field is absent or an empty list" do
      cs = Changeset.change(%Task{})
      assert EmbedValidations.validate_embed_type(cs, :key_files, %{}).errors == []

      assert EmbedValidations.validate_embed_type(cs, :key_files, %{"key_files" => []}).errors ==
               []
    end
  end

  describe "validate_key_file_embed/2" do
    test "enhances the blank file_path and position errors" do
      result = EmbedValidations.validate_key_file_embed(%KeyFile{}, %{})

      assert {"is required (relative path from project root)", _} = result.errors[:file_path]
      assert {"is required (integer starting from 0)", _} = result.errors[:position]
    end
  end

  describe "validate_behaviour_test_row_embed/2 — valid rows" do
    test "casts a fully populated row to a BehaviourTestRow struct" do
      changeset = row_changeset()

      assert changeset.valid?

      assert %BehaviourTestRow{
               category: "Happy path",
               behaviour: "claims an open task",
               test_name: "claims an open task",
               type: "unit",
               status: "planned",
               na_reason: nil,
               position: 0
             } = Changeset.apply_changes(changeset)
    end

    test "accepts every one of the seven fixed categories" do
      for category <- BehaviourTestRow.categories() do
        assert row_changeset(%{"category" => category}).valid?,
               "expected #{inspect(category)} to be a valid category"
      end
    end

    test "categories/0 returns the seven canonical categories in order" do
      assert BehaviourTestRow.categories() == [
               "Happy path",
               "Boundary",
               "Error / exception",
               "Null / empty",
               "Concurrency",
               "Lifecycle / wiring",
               "Contract / serialization"
             ]
    end

    test "accepts a single type token and a '/'-separated combination" do
      for type <- ["unit", "integration", "manual", "unit / manual", "unit/integration/manual"] do
        assert row_changeset(%{"type" => type}).valid?,
               "expected #{inspect(type)} to be a valid type"
      end
    end

    test "accepts every valid status" do
      for status <- BehaviourTestRow.statuses() do
        overrides = %{"status" => status, "na_reason" => "covered by a manual smoke test"}
        assert row_changeset(overrides).valid?, "expected #{inspect(status)} to be a valid status"
      end
    end

    test "accepts a not_applicable row that has an na_reason and no test_name" do
      changeset =
        row_changeset(%{
          "status" => "not_applicable",
          "test_name" => nil,
          "na_reason" => "no concurrent access path in this module"
        })

      assert changeset.valid?
    end

    test "defaults an omitted status to 'planned'" do
      changeset =
        EmbedValidations.validate_behaviour_test_row_embed(
          %BehaviourTestRow{},
          Map.delete(matrix_row(), "status")
        )

      assert changeset.valid?
      assert Changeset.apply_changes(changeset).status == "planned"
    end

    test "treats single words from the N/A phrases as real test names" do
      for test_name <- ["not", "applicable"] do
        assert row_changeset(%{"test_name" => test_name}).valid?,
               "expected #{inspect(test_name)} to be a real test name, not a waiver"
      end
    end

    test "accepts an omitted position" do
      changeset =
        EmbedValidations.validate_behaviour_test_row_embed(
          %BehaviourTestRow{},
          Map.delete(matrix_row(), "position")
        )

      assert changeset.valid?
    end
  end

  describe "validate_behaviour_test_row_embed/2 — invalid rows" do
    test "rejects a category outside the seven fixed values" do
      result = row_changeset(%{"category" => "Sad path"})

      refute result.valid?

      assert {"must be one of: Happy path, Boundary, Error / exception, Null / empty, Concurrency, Lifecycle / wiring, Contract / serialization",
              _} = result.errors[:category]
    end

    test "enhances the blank category error with the allowed values" do
      result = row_changeset(%{"category" => nil})

      assert {"is required (one of: Happy path, Boundary, Error / exception, Null / empty, Concurrency, Lifecycle / wiring, Contract / serialization)",
              _} = result.errors[:category]
    end

    test "rejects a status outside the enum" do
      result = row_changeset(%{"status" => "flaky"})

      refute result.valid?

      assert {"must be one of: planned, passing, failing, not_applicable", _} =
               result.errors[:status]
    end

    test "enhances the blank status error" do
      result = row_changeset(%{"status" => nil})

      assert {"is required (one of: planned, passing, failing, not_applicable)", _} =
               result.errors[:status]
    end

    test "enhances the blank behaviour error" do
      result = row_changeset(%{"behaviour" => nil})

      assert {"is required (what the code should do)", _} = result.errors[:behaviour]
    end

    test "rejects an unknown type token" do
      result = row_changeset(%{"type" => "flakey"})

      refute result.valid?

      assert {"must be 'unit', 'integration', or 'manual', or a '/'-separated combination (e.g. 'unit / manual')",
              _} = result.errors[:type]
    end

    test "rejects a combination containing an unknown token" do
      result = row_changeset(%{"type" => "unit / flakey"})

      refute result.valid?
      assert result.errors[:type]
    end

    test "rejects a combination with an empty token" do
      result = row_changeset(%{"type" => "unit //manual"})

      refute result.valid?
      assert result.errors[:type]
    end

    test "rejects a row with neither a test_name nor an na_reason" do
      result = row_changeset(%{"test_name" => nil})

      refute result.valid?
      assert {"is required unless the row is not applicable", _} = result.errors[:test_name]
    end

    test "rejects a not_applicable row with no na_reason" do
      result = row_changeset(%{"status" => "not_applicable", "test_name" => nil})

      refute result.valid?
      assert {"is required when the row is not applicable", _} = result.errors[:na_reason]
    end

    test "rejects every spelling of an N/A test_name when there is no na_reason" do
      for test_name <- ["N/A", "n/a", "na", "not applicable", "Not Applicable", "not  applicable"] do
        result = row_changeset(%{"test_name" => test_name})

        refute result.valid?, "expected #{inspect(test_name)} to require an na_reason"
        assert {"is required when the row is not applicable", _} = result.errors[:na_reason]
      end
    end

    test "rejects a negative position" do
      result = row_changeset(%{"position" => -1})

      refute result.valid?
      assert {"must be greater than or equal to %{number}", _} = result.errors[:position]
    end
  end

  describe "validate_embed_type/3 — behaviour_test_matrix" do
    test "rejects a non-array value with the field-specific message" do
      cs = Changeset.change(%Task{})

      result =
        EmbedValidations.validate_embed_type(cs, :behaviour_test_matrix, %{
          "behaviour_test_matrix" => "not a list"
        })

      assert {@matrix_shape_message, _} = result.errors[:behaviour_test_matrix]
    end

    test "rejects an array with non-object items" do
      cs = Changeset.change(%Task{})

      result =
        EmbedValidations.validate_embed_type(cs, :behaviour_test_matrix, %{
          "behaviour_test_matrix" => ["oops"]
        })

      assert {@matrix_shape_message, _} = result.errors[:behaviour_test_matrix]
    end

    test "passes when the field is absent or an empty list" do
      cs = Changeset.change(%Task{})
      assert EmbedValidations.validate_embed_type(cs, :behaviour_test_matrix, %{}).errors == []

      assert EmbedValidations.validate_embed_type(cs, :behaviour_test_matrix, %{
               "behaviour_test_matrix" => []
             }).errors == []
    end
  end

  describe "validate_embed_type/3 — generic (non key_files/verification_steps) field" do
    test "uses the generic 'array of objects' message for non-object items" do
      cs = Changeset.change(%Task{})
      result = EmbedValidations.validate_embed_type(cs, :other, %{"other" => ["not a map"]})

      assert {"must be an array of objects", _} = result.errors[:other]
    end

    test "uses the generic 'array' message for a non-array value" do
      cs = Changeset.change(%Task{})
      result = EmbedValidations.validate_embed_type(cs, :other, %{"other" => "not a list"})

      assert {"must be an array", _} = result.errors[:other]
    end
  end
end
