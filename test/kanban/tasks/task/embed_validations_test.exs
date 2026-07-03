defmodule Kanban.Tasks.Task.EmbedValidationsTest do
  @moduledoc """
  Unit tests for the extracted embed validators (W1445). The full changeset
  pipelines are covered end-to-end by tasks_test.exs; these lock one rule per
  function directly, including the enhanced error strings.
  """
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Kanban.Schemas.Task.KeyFile
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.Task.EmbedValidations

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
