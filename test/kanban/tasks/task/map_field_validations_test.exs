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

  describe "validate_security_considerations/1 — credential-shaped entries (W2382)" do
    # Fake values only. `@token` is long enough to clear the Stride pattern's
    # length floor; `@other_token` is a second, different shape.
    @token "stride_dev_" <> "AbCdEfGhIjKlMnOpQrSt0123"
    @other_token "ghp_abcdefghij0123456789"

    defp cast_considerations(task, entries) do
      task
      |> Changeset.cast(%{security_considerations: entries}, [:security_considerations])
      |> MapFieldValidations.validate_security_considerations()
    end

    defp credential_errors(changeset) do
      for {:security_considerations, {msg, opts}} <- changeset.errors,
          msg == MapFieldValidations.credential_entry_message(),
          do: opts
    end

    test "rejects a security_considerations entry carrying a Stride token, naming its position but not its value" do
      changeset = cast_considerations(%Task{}, ["Keep queries scoped to the board", @token])

      refute changeset.valid?
      assert credential_errors(changeset) == [[position: 2]]
      refute inspect(changeset.errors) =~ @token
    end

    test "adds one error per offending entry, each naming its own position" do
      changeset = cast_considerations(%Task{}, [@token, "Prose about scoping", @other_token])

      assert changeset |> credential_errors() |> Enum.sort() == [[position: 1], [position: 3]]
      refute inspect(changeset.errors) =~ @token
      refute inspect(changeset.errors) =~ @other_token
    end

    test "accepts considerations that only describe credentials in prose" do
      changeset =
        cast_considerations(%Task{}, [
          "API tokens are never logged",
          "Never log sensitive data (passwords, tokens, credit cards)",
          "api_key: [REDACTED — row text embedded a credential]",
          "Examples use a short placeholder such as stride_dev_abc123"
        ])

      assert changeset.errors == []
    end

    test "accepts nil and an empty security_considerations list" do
      assert cast_considerations(%Task{}, []).errors == []
      assert cast_considerations(%Task{}, nil).errors == []

      assert %Task{security_considerations: nil}
             |> Changeset.change()
             |> MapFieldValidations.validate_security_considerations()
             |> Map.fetch!(:errors) == []
    end

    test "still checks a new list when the stored value is nil" do
      changeset = cast_considerations(%Task{security_considerations: nil}, [@token])

      assert credential_errors(changeset) == [[position: 1]]
    end

    test "does not re-validate persisted considerations a change did not touch" do
      legacy = %Task{security_considerations: [@token]}

      # No change to the field at all.
      assert legacy
             |> Changeset.change(title: "Renamed")
             |> MapFieldValidations.validate_security_considerations()
             |> Map.fetch!(:errors) == []

      # Appending prose keeps the stored entry; only new entries are checked.
      assert cast_considerations(legacy, [@token, "Prose about scoping"]).errors == []

      # A newly introduced credential is still refused, at its own position.
      assert legacy |> cast_considerations([@token, @other_token]) |> credential_errors() ==
               [[position: 2]]
    end

    test "reports only the list-shape error when the list is malformed" do
      changeset =
        %Task{}
        |> Changeset.change(security_considerations: [@token, 123])
        |> MapFieldValidations.validate_security_considerations()

      assert [{"must be a list of strings", _}] =
               Keyword.get_values(changeset.errors, :security_considerations)
    end

    test "a different error already on the field does not hide a credential" do
      changeset =
        %Task{}
        |> Changeset.cast(%{security_considerations: [@token]}, [:security_considerations])
        |> Changeset.add_error(:security_considerations, "an earlier error")
        |> MapFieldValidations.validate_security_considerations()

      assert credential_errors(changeset) == [[position: 1]]
    end

    test "the message is translated in every locale the task form renders it in" do
      message = MapFieldValidations.credential_entry_message()

      for locale <- ~w(de es fr ja pt zh) do
        translated =
          Gettext.with_locale(KanbanWeb.Gettext, locale, fn ->
            KanbanWeb.CoreComponents.translate_error({message, [position: 2]})
          end)

        refute translated =~ "looks like it contains", "no #{locale} translation"
        assert translated =~ "2", "#{locale} translation dropped the position"
        refute translated =~ "%{position}"
      end
    end
  end
end
