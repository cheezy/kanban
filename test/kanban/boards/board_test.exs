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

    test "name with exactly 5 characters is valid (min boundary)" do
      changeset = Board.changeset(%Board{}, %{name: "abcde"})
      assert changeset.valid?
    end

    test "name with exactly 4 characters is invalid (just below min)" do
      changeset = Board.changeset(%Board{}, %{name: "abcd"})
      assert %{name: ["should be at least 5 character(s)"]} = errors_on(changeset)
    end

    test "name with exactly 50 characters is valid (max boundary)" do
      name = String.duplicate("a", 50)
      changeset = Board.changeset(%Board{}, %{name: name})
      assert changeset.valid?
    end

    test "description with exactly 255 characters is valid (max boundary)" do
      description = String.duplicate("a", 255)
      changeset = Board.changeset(%Board{}, %{name: "Test Board", description: description})
      assert changeset.valid?
    end

    test "description is optional" do
      changeset = Board.changeset(%Board{}, %{name: "Test Board"})
      assert changeset.valid?
    end

    test "casts read_only when set to true" do
      changeset = Board.changeset(%Board{}, %{name: "Test Board", read_only: true})
      assert changeset.valid?
      assert get_change(changeset, :read_only) == true
    end

    test "casts read_only when set to false on a board where it was true" do
      changeset =
        Board.changeset(%Board{read_only: true}, %{name: "Test Board", read_only: false})

      assert changeset.valid?
      assert get_change(changeset, :read_only) == false
    end

    test "read_only defaults to false on a new struct" do
      assert %Board{}.read_only == false
    end

    test "ai_optimized_board defaults to false on a new struct" do
      assert %Board{}.ai_optimized_board == false
    end

    test "does not cast ai_optimized_board (cannot be set via changeset)" do
      changeset =
        Board.changeset(%Board{ai_optimized_board: false}, %{
          name: "Test Board",
          ai_optimized_board: true
        })

      assert changeset.valid?
      assert get_change(changeset, :ai_optimized_board) == nil
    end

    test "field_visibility as a list is rejected" do
      changeset =
        Board.changeset(%Board{}, %{name: "Test Board", field_visibility: ["not", "a", "map"]})

      assert %{field_visibility: ["is invalid"]} = errors_on(changeset)
    end

    test "empty field_visibility map is rejected (no required keys present)" do
      changeset = Board.changeset(%Board{}, %{name: "Test Board", field_visibility: %{}})

      assert %{field_visibility: ["missing required field visibility keys"]} =
               errors_on(changeset)
    end

    test "field_visibility with all required keys plus extra keys is valid" do
      visibility = %{
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
        "required_capabilities" => false,
        "future_field" => true,
        "another_extra" => false
      }

      changeset = Board.changeset(%Board{}, %{name: "Test Board", field_visibility: visibility})
      assert changeset.valid?
    end

    test "field_visibility is unchanged when not in attrs" do
      changeset = Board.changeset(%Board{}, %{name: "Test Board"})
      assert changeset.valid?
      assert get_change(changeset, :field_visibility) == nil
    end

    test "rejects unknown attribute keys silently (not cast)" do
      changeset = Board.changeset(%Board{}, %{name: "Test Board", not_a_field: "value"})
      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :not_a_field)
    end

    test "accumulates multiple validation errors in a single changeset" do
      long_name = String.duplicate("a", 51)
      long_description = String.duplicate("a", 256)

      changeset =
        Board.changeset(%Board{}, %{name: long_name, description: long_description})

      errors = errors_on(changeset)
      assert errors[:name] == ["should be at most 50 character(s)"]
      assert errors[:description] == ["should be at most 255 character(s)"]
    end

    test "empty string name fails validate_required" do
      changeset = Board.changeset(%Board{}, %{name: ""})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "explicit nil name fails validate_required" do
      changeset = Board.changeset(%Board{}, %{name: nil})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "whitespace-only name fails validate_required (Ecto trims)" do
      changeset = Board.changeset(%Board{}, %{name: "        "})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts string-keyed params" do
      changeset =
        Board.changeset(%Board{}, %{
          "name" => "String Keys",
          "description" => "Works the same way"
        })

      assert changeset.valid?
      assert get_change(changeset, :name) == "String Keys"
      assert get_change(changeset, :description) == "Works the same way"
    end

    test "updates an existing board while preserving its id" do
      existing = %Board{id: 42, name: "Original", description: "Old"}
      changeset = Board.changeset(existing, %{name: "Renamed Board"})

      assert changeset.valid?
      assert changeset.data.id == 42
      assert get_change(changeset, :name) == "Renamed Board"
      refute Map.has_key?(changeset.changes, :description)
    end

    test "casting only :name in attrs leaves description untouched on existing board" do
      existing = %Board{name: "Original", description: "Keep me"}
      changeset = Board.changeset(existing, %{name: "Renamed Board"})

      applied = Ecto.Changeset.apply_changes(changeset)
      assert applied.name == "Renamed Board"
      assert applied.description == "Keep me"
    end

    test "rejects non-boolean read_only values" do
      changeset = Board.changeset(%Board{}, %{name: "Test Board", read_only: "yes"})
      assert %{read_only: ["is invalid"]} = errors_on(changeset)
    end

    test "field_visibility with atom keys is rejected (validation expects string keys)" do
      atom_keyed = %{
        acceptance_criteria: true,
        complexity: false,
        context: false,
        key_files: false,
        verification_steps: false,
        technical_notes: false,
        observability: false,
        error_handling: false,
        technology_requirements: false,
        pitfalls: false,
        out_of_scope: false,
        required_capabilities: false
      }

      changeset = Board.changeset(%Board{}, %{name: "Test Board", field_visibility: atom_keyed})

      assert %{field_visibility: ["missing required field visibility keys"]} =
               errors_on(changeset)
    end

    test "field_visibility validation only checks key presence, not value types" do
      visibility = %{
        "acceptance_criteria" => "yes",
        "complexity" => 1,
        "context" => nil,
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

      changeset = Board.changeset(%Board{}, %{name: "Test Board", field_visibility: visibility})
      assert changeset.valid?
      assert get_change(changeset, :field_visibility) == visibility
    end

    test "validate_required is checked even when an unrelated field_visibility change is valid" do
      changeset =
        Board.changeset(%Board{}, %{
          name: "",
          field_visibility: %{
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
        })

      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "schema declares user_access as a virtual field" do
      assert :user_access in Board.__schema__(:virtual_fields)
    end

    test "user_access is not cast through the changeset" do
      changeset = Board.changeset(%Board{}, %{name: "Test Board", user_access: :owner})
      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :user_access)
    end

    test "schema lists the expected real fields" do
      fields = Board.__schema__(:fields)
      assert :name in fields
      assert :description in fields
      assert :ai_optimized_board in fields
      assert :read_only in fields
      assert :field_visibility in fields
      refute :user_access in fields
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
