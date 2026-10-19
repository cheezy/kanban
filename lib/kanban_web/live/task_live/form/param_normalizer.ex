defmodule KanbanWeb.TaskLive.Form.ParamNormalizer do
  @moduledoc """
  Pure parameter normalization for the task form. Filters out empty strings
  from array fields, converts Phoenix numeric-keyed maps (from `inputs_for`)
  back into lists for embed fields, and normalizes nested map fields like
  `testing_strategy` and `integration_points`.

  Called from `KanbanWeb.TaskLive.FormComponent` before changeset construction
  to avoid false validation errors on empty inputs. `normalize_params/3` also
  drops the paid task fields on a locked board (W2409), so a save on a free
  board cannot carry them, and reports which dropped values were changes.
  """

  alias Kanban.Plans

  @array_fields ~w[dependencies required_capabilities technology_requirements pitfalls out_of_scope security_considerations]

  @array_field_keys Enum.map(@array_fields, &{String.to_atom(&1), &1})

  # Map fields the form edits only partly: it has inputs for some keys (e.g.
  # testing_strategy's unit/integration/manual tests) but not others
  # (edge_cases, coverage_target), which tasks created through the API carry.
  @partly_edited_map_fields [
    testing_strategy: "testing_strategy",
    integration_points: "integration_points"
  ]

  @doc """
  Normalize array and map fields in the task params before changeset construction.
  """
  def normalize_array_params(params) do
    params
    |> normalize_array_fields(@array_fields)
    |> normalize_map_fields()
  end

  @doc """
  `normalize_array_params/1`, then drops the paid task fields
  (`Kanban.Plans.strip_locked_task_fields/3`) when `board` is locked. A
  dropped key is simply absent from the cast, so a value stored before the
  board was locked is kept.

  Returns `{params, lost}`, where `lost` names the dropped fields whose
  submitted value was a change: not blank, and not the value `task` already
  stores. Only a form rendered before the board was locked, or a crafted
  event, can submit one, and the caller tells the user it was not saved.
  """
  def normalize_params(params, board, task \\ %Kanban.Tasks.Task{}) do
    params = normalize_array_params(params)
    {stripped, dropped} = Plans.strip_locked_task_fields(params, board)

    {stripped, Enum.filter(dropped, &changed?(params, task, &1))}
  end

  defp changed?(params, task, field) do
    case Map.get(params, field) do
      value when is_binary(value) ->
        String.trim(value) != "" and value != Map.get(task, String.to_existing_atom(field))

      _ ->
        false
    end
  end

  @doc """
  Adjusts edit-form params so a save writes only what the user changed:

    * partly-edited map fields (`testing_strategy`, `integration_points`)
      merge the submitted keys over the stored map, so keys the form has no
      inputs for survive instead of the whole map being replaced;
    * the form posts every key and list it has inputs for, so an empty list
      the task never had (a missing map key, a nil map, or a nil list field
      like `pitfalls`) is dropped rather than written. Emptying a value that
      was stored still saves `[]`.

  Fields the form did not submit are left alone.
  """
  def preserve_stored_values(params, task) do
    params
    |> merge_map_fields(task)
    |> drop_unset_empty_lists(task)
  end

  defp merge_map_fields(params, task) do
    Enum.reduce(@partly_edited_map_fields, params, fn {key, field}, acc ->
      merge_stored(acc, field, Map.get(task, key))
    end)
  end

  defp merge_stored(params, field, %{} = stored) do
    case Map.get(params, field) do
      %{} = submitted ->
        Map.put(params, field, Map.merge(stored, new_or_filled(submitted, stored)))

      _ ->
        params
    end
  end

  # A nil map stays nil unless the form submitted a non-empty value for it.
  defp merge_stored(params, field, nil) do
    case Map.get(params, field) do
      %{} = submitted -> put_or_drop(params, field, new_or_filled(submitted, %{}))
      _ -> params
    end
  end

  defp merge_stored(params, _field, _stored), do: params

  defp put_or_drop(params, field, filled) when map_size(filled) == 0,
    do: Map.delete(params, field)

  defp put_or_drop(params, field, filled), do: Map.put(params, field, filled)

  defp drop_unset_empty_lists(params, task) do
    Enum.reduce(@array_field_keys, params, fn {key, field}, acc ->
      if Map.get(acc, field) == [] and is_nil(Map.get(task, key)),
        do: Map.delete(acc, field),
        else: acc
    end)
  end

  defp new_or_filled(submitted, stored) do
    Map.reject(submitted, fn {key, value} -> value == [] and not Map.has_key?(stored, key) end)
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
    |> normalize_embedded_field("behaviour_test_matrix")
  end

  defp normalize_embedded_field(params, field_name) do
    case Map.get(params, field_name) do
      # If it's already a list, leave it as is
      value when is_list(value) ->
        params

      # If it's a map with numeric string keys (from inputs_for), convert to list
      value when is_map(value) ->
        Map.put(params, field_name, indexed_map_to_list(value))

      # If it's nil or missing, don't add it to params
      # Schema defaults will handle nil values appropriately
      # Adding empty arrays here would incorrectly trigger change detection
      _ ->
        params
    end
  end

  defp indexed_map_to_list(value) do
    value
    |> Enum.sort_by(fn {k, _v} -> String.to_integer(k) end)
    |> Enum.map(fn {_k, v} -> Map.delete(v, "_persistent_id") end)
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
