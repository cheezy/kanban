defmodule KanbanWeb.TaskLive.Form.ParamNormalizer do
  @moduledoc """
  Pure parameter normalization for the task form. Filters out empty strings
  from array fields, converts Phoenix numeric-keyed maps (from `inputs_for`)
  back into lists for embed fields, and normalizes nested map fields like
  `testing_strategy` and `integration_points`.

  Called from `KanbanWeb.TaskLive.FormComponent` before changeset construction
  to avoid false validation errors on empty inputs.
  """

  @array_fields ~w[dependencies required_capabilities technology_requirements pitfalls out_of_scope security_considerations]

  @doc """
  Normalize array and map fields in the task params before changeset construction.
  """
  def normalize_array_params(params) do
    params
    |> normalize_array_fields(@array_fields)
    |> normalize_map_fields()
  end

  defp normalize_array_fields(params, fields) do
    Enum.reduce(fields, params, fn field, acc ->
      # Only normalize if the field is actually present in params
      # Don't add missing fields - that would incorrectly trigger change detection
      if Map.has_key?(acc, field) do
        Map.update(acc, field, [], &filter_empty_strings/1)
      else
        acc
      end
    end)
  end

  defp normalize_map_fields(params) do
    params
    |> normalize_testing_strategy()
    |> normalize_integration_points()
    |> normalize_embedded_fields()
  end

  defp normalize_embedded_fields(params) do
    params
    |> normalize_embedded_field("key_files")
    |> normalize_embedded_field("verification_steps")
  end

  defp normalize_embedded_field(params, field_name) do
    case Map.get(params, field_name) do
      # If it's already a list, leave it as is
      value when is_list(value) ->
        params

      # If it's a map with numeric string keys (from inputs_for), convert to list
      value when is_map(value) ->
        list =
          value
          |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
          |> Enum.map(fn {_k, v} -> Map.delete(v, "_persistent_id") end)

        Map.put(params, field_name, list)

      # If it's nil or missing, don't add it to params
      # Schema defaults will handle nil values appropriately
      # Adding empty arrays here would incorrectly trigger change detection
      _ ->
        params
    end
  end

  defp normalize_testing_strategy(params) do
    normalize_map_with_arrays(params, "testing_strategy", [
      "unit_tests",
      "integration_tests",
      "manual_tests"
    ])
  end

  defp normalize_integration_points(params) do
    normalize_map_with_arrays(params, "integration_points", [
      "telemetry_events",
      "pubsub_broadcasts",
      "phoenix_channels",
      "external_apis"
    ])
  end

  defp normalize_map_with_arrays(params, field_name, array_keys) do
    case Map.get(params, field_name) do
      # If field is present and is a map, normalize its array fields
      field_map when is_map(field_map) ->
        normalized_map = normalize_array_fields(field_map, array_keys)
        Map.put(params, field_name, normalized_map)

      # If it's nil or missing, don't add it to params
      # Schema defaults will handle nil values appropriately
      _ ->
        params
    end
  end

  defp filter_empty_strings(list) when is_list(list) do
    Enum.reject(list, &(&1 == "" || is_nil(&1)))
  end

  defp filter_empty_strings(value), do: value
end
