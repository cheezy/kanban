defmodule Kanban.Tasks.Task.MapFieldValidationsTest do
  @moduledoc """
  Unit tests for the extracted structured-map field validators (W1445). The
  full changeset pipelines are covered end-to-end by ai_context_fields_test.exs;
  these lock one rule per function directly, including verbatim error strings.
  """
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.Task.MapFieldValidations

  describe "validate_string_list_field/2" do
    test "flags a list containing a non-string element" do
      result =
        %Task{security_considerations: ["ok", 123]}
        |> Changeset.change()
        |> MapFieldValidations.validate_string_list_field(:security_considerations)

      assert {"must be a list of strings", _} = result.errors[:security_considerations]
    end

    test "passes nil and a list of strings" do
      assert %Task{}
             |> Changeset.change()
             |> MapFieldValidations.validate_string_list_field(:security_considerations)
             |> Map.fetch!(:errors) == []

      assert %Task{security_considerations: ["a", "b"]}
             |> Changeset.change()
             |> MapFieldValidations.validate_string_list_field(:security_considerations)
             |> Map.fetch!(:errors) == []
    end
  end

  describe "validate_testing_strategy/1" do
    test "flags invalid values and names the offending keys" do
      result =
        %Task{testing_strategy: %{"unit_tests" => 5}}
        |> Changeset.change()
        |> MapFieldValidations.validate_testing_strategy()

      assert {"all values must be strings or arrays of strings. Invalid keys: unit_tests", _} =
               result.errors[:testing_strategy]
    end
  end

  describe "validate_technical_details/1" do
    test "accepts any map (free-form) but rejects a non-map" do
      ok =
        %Task{technical_details: %{"arbitrary" => 1}}
        |> Changeset.change()
        |> MapFieldValidations.validate_technical_details()

      assert ok.errors == []

      bad =
        %Task{technical_details: "not a map"}
        |> Changeset.change()
        |> MapFieldValidations.validate_technical_details()

      assert {"must be a JSON object", _} = bad.errors[:technical_details]
    end
  end

  describe "empty-collection short circuits" do
    test "an empty string list is accepted" do
      result =
        %Task{security_considerations: []}
        |> Changeset.change()
        |> MapFieldValidations.validate_string_list_field(:security_considerations)

      assert result.errors == []
    end

    test "an empty testing_strategy / integration_points map is accepted" do
      assert %Task{testing_strategy: %{}}
             |> Changeset.change()
             |> MapFieldValidations.validate_testing_strategy()
             |> Map.fetch!(:errors) == []

      assert %Task{integration_points: %{}}
             |> Changeset.change()
             |> MapFieldValidations.validate_integration_points()
             |> Map.fetch!(:errors) == []
    end

    test "a nil map field is accepted (each validator's nil branch)" do
      cs =
        Changeset.change(%Task{
          testing_strategy: nil,
          integration_points: nil,
          technical_details: nil
        })

      assert MapFieldValidations.validate_testing_strategy(cs).errors == []
      assert MapFieldValidations.validate_integration_points(cs).errors == []
      assert MapFieldValidations.validate_technical_details(cs).errors == []
    end
  end
end
