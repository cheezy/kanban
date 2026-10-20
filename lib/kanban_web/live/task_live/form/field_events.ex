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

  alias KanbanWeb.IdParams

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
  A remove event whose `index` is not a valid list position (non-numeric,
  negative or oversized — the client sends it) changes nothing (D384), as does
  one past the end of the list. Rows are read through `rows/1` (a bare string
  is one row, any other non-list value none) and a map-array column value that
  is not a map is read as `%{}`, so a crafted `validate` event cannot crash the
  form through it.
  """
  def handle("add-" <> _ = event, _params, socket) do
    add_row(socket, Map.fetch!(@events, event))
  end

  def handle("remove-" <> _ = event, params, socket) do
    field = Map.fetch!(@events, event)

    case IdParams.parse_index(params["index"]) do
      {:ok, index} -> remove_row(socket, field, index)
      :error -> {:noreply, socket}
    end
  end

  defp add_row(socket, field) when is_atom(field), do: add_to_array(socket, field)
  defp add_row(socket, {field, key}), do: add_to_map_array(socket, field, key)

  defp remove_row(socket, field, index) when is_atom(field),
    do: remove_from_array(socket, field, index)

  defp remove_row(socket, {field, key}, index),
    do: remove_from_map_array(socket, field, key, index)

  defp add_to_array(socket, field) do
    existing = socket |> current_value(field) |> rows()

    put_change(socket, field, existing ++ [""])
  end

  defp remove_from_array(socket, field, index) do
    list = socket |> current_value(field) |> rows()

    remove_at(socket, list, index, &put_change(socket, field, &1))
  end

  defp add_to_map_array(socket, field, key) do
    existing_map = socket |> current_value(field) |> map_or_empty()
    existing_list = existing_map |> Map.get(key) |> rows()

    put_change(socket, field, Map.put(existing_map, key, existing_list ++ [""]))
  end

  defp remove_from_map_array(socket, field, key, index) do
    existing_map = socket |> current_value(field) |> map_or_empty()
    existing_list = existing_map |> Map.get(key) |> rows()

    remove_at(
      socket,
      existing_list,
      index,
      &put_change(socket, field, Map.put(existing_map, key, &1))
    )
  end

  # An index past the end names no row, so nothing changes. That includes a
  # value that is neither a list nor a string (read as `[]` by `rows/1`).
  defp remove_at(socket, list, index, _put) when index >= length(list), do: {:noreply, socket}
  defp remove_at(_socket, list, index, put), do: list |> List.delete_at(index) |> put.()

  @doc """
  The rows a stored repeating-field value holds: a list as given, a bare
  string as a single row, and anything else (`nil`, a map, a number, a
  boolean) as no rows.

  The values of `testing_strategy` and `integration_points` may be a string or
  a list of strings (`Kanban.Tasks.Task.MapFieldValidations` accepts both, e.g.
  `%{"unit_tests" => "Test each function"}`), and a crafted `validate` event can
  put any JSON value there. Both the add/remove events here and
  `KanbanWeb.TaskLive.Form.PlanningSections` read rows through this one
  function, so every rendered row has a working Remove button, a stored string
  is kept (never silently dropped) when a row is added, and no value can crash
  the form on `++` or `List.delete_at/2` (D384).
  """
  @spec rows(term()) :: list()
  def rows(value) when is_list(value), do: value
  def rows(value) when is_binary(value), do: [value]
  def rows(_value), do: []

  @doc """
  Returns `value` when it is a map (and not a struct), else `%{}` — the map
  counterpart of `rows/1` for the `testing_strategy` and
  `integration_points` columns themselves.
  """
  @spec map_or_empty(term()) :: map()
  def map_or_empty(value) when is_map(value) and not is_struct(value), do: value
  def map_or_empty(_value), do: %{}

  defp current_value(socket, field) do
    Ecto.Changeset.get_field(socket.assigns.form.source, field)
  end

  # Builds on the in-flight form (kept current by phx-change="validate"),
  # like the embed repeaters in the component, so adding or removing a row
  # keeps the user's other unsaved edits.
  defp put_change(socket, field, value) do
    changeset = Ecto.Changeset.put_change(socket.assigns.form.source, field, value)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end
end
