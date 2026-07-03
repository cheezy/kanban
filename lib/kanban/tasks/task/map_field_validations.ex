defmodule Kanban.Tasks.Task.MapFieldValidations do
  @moduledoc """
  Validations for the structured map / string-list AI-context fields on
  `Kanban.Tasks.Task` — `security_considerations`, `testing_strategy`,
  `integration_points`, and `technical_details` — extracted from the schema
  module (W1445).

  Each `validate_*/1` is a changeset-in / changeset-out pipeline stage. The
  error strings (including the JSON-object examples) are asserted verbatim by
  the AI-context-fields tests and shown to API clients, so they must not drift.

  `validate_string_list_field/2` is public because `Kanban.Tasks.Task` still
  calls it directly for the `technology_requirements` field.
  """

  import Ecto.Changeset

  @doc "Validates `security_considerations` is nil, empty, or a list of strings."
  def validate_security_considerations(changeset) do
    validate_string_list_field(changeset, :security_considerations)
  end

  @doc """
  Validates `field` is nil, empty, or a list of strings; otherwise adds the
  \"must be a list of strings\" / \"must be a list\" error.
  """
  def validate_string_list_field(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      [] ->
        changeset

      items when is_list(items) ->
        if Enum.all?(items, &is_binary/1) do
          changeset
        else
          add_error(changeset, field, "must be a list of strings")
        end

      _ ->
        add_error(changeset, field, "must be a list")
    end
  end

  @doc "Validates `testing_strategy` is a JSON object with string/array values."
  def validate_testing_strategy(changeset) do
    case get_field(changeset, :testing_strategy) do
      nil ->
        changeset

      %{} = strategy when map_size(strategy) == 0 ->
        changeset

      %{} = strategy ->
        # Validate that all values are strings or arrays of strings
        validate_testing_strategy_values(changeset, strategy)

      _ ->
        add_error(
          changeset,
          :testing_strategy,
          "must be a JSON object with string or array values describing testing approach (e.g., {\"unit_tests\": \"Test each function\", \"edge_cases\": [\"Empty input\", \"Invalid data\"]})"
        )
    end
  end

  defp validate_testing_strategy_values(changeset, strategy) do
    validate_string_or_string_list_map(changeset, :testing_strategy, strategy)
  end

  @doc "Validates `integration_points` is a JSON object with string/array values."
  def validate_integration_points(changeset) do
    case get_field(changeset, :integration_points) do
      nil ->
        changeset

      %{} = points when map_size(points) == 0 ->
        changeset

      %{} = points ->
        # Validate that all values are strings or arrays of strings
        validate_integration_points_values(changeset, points)

      _ ->
        add_error(
          changeset,
          :integration_points,
          "must be a JSON object with string or array values describing integration points (e.g., {\"external_api\": \"Stripe API\", \"pubsub\": [\"TaskUpdated\", \"BoardUpdated\"]})"
        )
    end
  end

  defp validate_integration_points_values(changeset, points) do
    validate_string_or_string_list_map(changeset, :integration_points, points)
  end

  # Free-form: any map (including empty) is valid; only a non-map value is an
  # error. Deliberately does NOT validate inner keys/values (contrast with
  # validate_testing_strategy/validate_integration_points which constrain values).
  @doc "Validates `technical_details` is a JSON object (free-form values)."
  def validate_technical_details(changeset) do
    case get_field(changeset, :technical_details) do
      nil ->
        changeset

      %{} ->
        changeset

      _ ->
        add_error(changeset, :technical_details, "must be a JSON object")
    end
  end

  defp validate_string_or_string_list_map(changeset, field, map) do
    invalid_values =
      Enum.reject(map, fn {_key, value} ->
        is_binary(value) or (is_list(value) and Enum.all?(value, &is_binary/1))
      end)

    if Enum.empty?(invalid_values) do
      changeset
    else
      invalid_keys = Enum.map_join(invalid_values, ", ", fn {key, _value} -> key end)

      add_error(
        changeset,
        field,
        "all values must be strings or arrays of strings. Invalid keys: #{invalid_keys}"
      )
    end
  end
end
