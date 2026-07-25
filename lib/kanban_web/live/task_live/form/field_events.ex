defmodule KanbanWeb.TaskLive.Form.FieldEvents do
  @moduledoc """
  Add/remove handling for the task form's repeating scalar fields, extracted
  from `KanbanWeb.TaskLive.FormComponent` (which was well over the module-size
  guidance in `AGENTS.md`).

  Two shapes are covered:

    * **array fields** — a `{:array, :string}` column such as `pitfalls`, where
      a row is one string in the list.
    * **map-array fields** — a JSONB map column such as `testing_strategy`,
      where a row is one string inside a named list within the map.

  `events/0` exposes the event-name table so the component can guard on it and
  keep its own `handle_event/3` clauses explicit; unknown events still fall
  through to a `FunctionClauseError` rather than being silently swallowed.

  The embed repeaters (`key_files`, `verification_steps`,
  `behaviour_test_matrix`) are deliberately NOT here — they use `put_embed`
  with typed structs and stay in the component alongside their schemas.
  """

  import Phoenix.Component, only: [assign: 3, to_form: 1]

  alias Kanban.Tasks

  # event name => array column
  @array_events %{
    "add-technology" => :technology_requirements,
    "remove-technology" => :technology_requirements,
    "add-pitfall" => :pitfalls,
    "remove-pitfall" => :pitfalls,
    "add-out-of-scope" => :out_of_scope,
    "remove-out-of-scope" => :out_of_scope,
    "add-dependency" => :dependencies,
    "remove-dependency" => :dependencies,
    "add-capability" => :required_capabilities,
    "remove-capability" => :required_capabilities,
    "add-security-consideration" => :security_considerations,
    "remove-security-consideration" => :security_considerations
  }

  # event name => {map column, key within that map}
  @map_array_events %{
    "add-unit-test" => {:testing_strategy, "unit_tests"},
    "remove-unit-test" => {:testing_strategy, "unit_tests"},
    "add-integration-test" => {:testing_strategy, "integration_tests"},
    "remove-integration-test" => {:testing_strategy, "integration_tests"},
    "add-manual-test" => {:testing_strategy, "manual_tests"},
    "remove-manual-test" => {:testing_strategy, "manual_tests"},
    "add-telemetry-event" => {:integration_points, "telemetry_events"},
    "remove-telemetry-event" => {:integration_points, "telemetry_events"},
    "add-pubsub-broadcast" => {:integration_points, "pubsub_broadcasts"},
    "remove-pubsub-broadcast" => {:integration_points, "pubsub_broadcasts"},
    "add-phoenix-channel" => {:integration_points, "phoenix_channels"},
    "remove-phoenix-channel" => {:integration_points, "phoenix_channels"},
    "add-external-api" => {:integration_points, "external_apis"},
    "remove-external-api" => {:integration_points, "external_apis"}
  }

  @events Map.merge(@array_events, @map_array_events)

  @doc """
  The event-name table, `event => field` or `event => {field, key}`. Bound as a
  module attribute by the component so it can be used in a guard.
  """
  def events, do: @events

  @doc """
  Applies a mapped add/remove event, returning the usual `{:noreply, socket}`.

  Raises `KeyError` for an unmapped event — callers guard on `events/0` first.
  """
  def handle("add-" <> _ = event, _params, socket) do
    add_row(socket, Map.fetch!(@events, event))
  end

  def handle("remove-" <> _ = event, params, socket) do
    remove_row(socket, Map.fetch!(@events, event), params["index"])
  end

  defp add_row(socket, field) when is_atom(field), do: add_to_array(socket, field)
  defp add_row(socket, {field, key}), do: add_to_map_array(socket, field, key)

  defp remove_row(socket, field, index) when is_atom(field),
    do: remove_from_array(socket, field, index)

  defp remove_row(socket, {field, key}, index),
    do: remove_from_map_array(socket, field, key, index)

  defp add_to_array(socket, field) do
    existing = current_value(socket, field) || []

    put_change(socket, field, existing ++ [""])
  end

  defp remove_from_array(socket, field, index) do
    list = current_value(socket, field) || []

    put_change(socket, field, List.delete_at(list, parse_index(index)))
  end

  defp add_to_map_array(socket, field, key) do
    existing_map = current_value(socket, field) || %{}
    existing_list = Map.get(existing_map, key, [])

    put_change(socket, field, Map.put(existing_map, key, existing_list ++ [""]))
  end

  defp remove_from_map_array(socket, field, key, index) do
    existing_map = current_value(socket, field) || %{}
    existing_list = Map.get(existing_map, key, [])
    new_list = List.delete_at(existing_list, parse_index(index))

    put_change(socket, field, Map.put(existing_map, key, new_list))
  end

  defp current_value(socket, field) do
    Ecto.Changeset.get_field(socket.assigns.form.source, field)
  end

  # Rebuilt from the task rather than the in-flight changeset, matching the
  # embed repeaters in the component: the row being added or removed is the
  # only change the form needs to reflect.
  defp put_change(socket, field, value) do
    changeset =
      socket.assigns.task
      |> Tasks.Task.changeset(%{})
      |> Ecto.Changeset.put_change(field, value)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  defp parse_index(index) when is_binary(index) do
    {parsed, _rest} = Integer.parse(index)
    parsed
  end

  defp parse_index(index) when is_integer(index), do: index
end
