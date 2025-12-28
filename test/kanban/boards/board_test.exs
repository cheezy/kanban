defmodule Kanban.Boards.BoardTest do
  use Kanban.DataCase

  alias Kanban.Boards.Board

  describe "changeset/2" do
    test "validates required name field" do
      changeset = Board.changeset(%Board{}, %{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates name length minimum" do
      changeset = Board.changeset(%Board{}, %{name: "abc"})
      assert %{name: ["should be at least 5 character(s)"]} = errors_on(changeset)
    end

    test "validates name length maximum" do
      long_name = String.duplicate("a", 51)
      changeset = Board.changeset(%Board{}, %{name: long_name})
      assert %{name: ["should be at most 50 character(s)"]} = errors_on(changeset)
    end

    test "validates description length maximum" do
      long_description = String.duplicate("a", 256)
      changeset = Board.changeset(%Board{}, %{name: "Valid Name", description: long_description})
      assert %{description: ["should be at most 255 character(s)"]} = errors_on(changeset)
    end

    test "accepts valid board attributes" do
      attrs = %{
        name: "Test Board",
        description: "A test board description"
      }

      changeset = Board.changeset(%Board{}, attrs)
      assert changeset.valid?
    end

    test "sets default field_visibility on new board" do
      board = %Board{}

      assert board.field_visibility == %{
               "acceptance_criteria" => true,
               "complexity" => false,
               "context" => false,
               "key_files" => false,
               "verification_steps" => false,
               "technical_notes" => false,
               "observability" => false,
               "error_handling" => false,
               "technology_requirements" => false,
               "pitfalls" => false,
               "out_of_scope" => false,
               "required_capabilities" => false
             }
    end

    test "validates field_visibility is a map" do
      changeset = Board.changeset(%Board{}, %{name: "Test Board", field_visibility: "not a map"})
      assert %{field_visibility: ["is invalid"]} = errors_on(changeset)
    end

    test "validates field_visibility has all required keys" do
      incomplete_visibility = %{
        "acceptance_criteria" => true,
        "complexity" => false
      }

      changeset =
        Board.changeset(%Board{}, %{name: "Test", field_visibility: incomplete_visibility})

      assert %{field_visibility: ["missing required field visibility keys"]} =
               errors_on(changeset)
    end

    test "accepts complete field_visibility map" do
      complete_visibility = %{
        "acceptance_criteria" => true,
        "complexity" => true,
        "context" => true,
        "key_files" => true,
        "verification_steps" => true,
        "technical_notes" => true,
        "observability" => true,
        "error_handling" => true,
        "technology_requirements" => true,
        "pitfalls" => true,
        "out_of_scope" => true,
        "required_capabilities" => true
      }

      changeset =
        Board.changeset(%Board{}, %{name: "Test Board", field_visibility: complete_visibility})

      assert changeset.valid?
    end

    test "allows updating field_visibility" do
      updated_visibility = %{
        "acceptance_criteria" => false,
        "complexity" => true,
        "context" => false,
        "key_files" => true,
        "verification_steps" => false,
        "technical_notes" => false,
        "observability" => false,
        "error_handling" => false,
        "technology_requirements" => false,
        "pitfalls" => false,
        "out_of_scope" => false,
        "required_capabilities" => false
      }

      changeset =
        Board.changeset(%Board{}, %{name: "Test Board", field_visibility: updated_visibility})

      assert changeset.valid?
      assert get_change(changeset, :field_visibility) == updated_visibility
    end
  end
end
