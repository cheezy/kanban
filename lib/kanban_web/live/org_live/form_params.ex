defmodule KanbanWeb.OrgLive.FormParams do
  @moduledoc """
  Scalar-only form params for the Organization console's forms (D441).

  A form field whose value is not a string (a map, a list, an integer) fails
  the Ecto cast but stays in the changeset params, where the re-rendered
  `<.input>` reads it and raises, crashing the LiveView. The crash report
  prints the event payload at every log level, and `:filter_parameters` does
  not reach it. So every value is kept only when it is a string and otherwise
  becomes blank, which the changeset then treats exactly as an empty input.

  Sanitizing goes by value type, never by a list of field names, so a field
  added later is covered. The one named rule is for checkboxes, whose value is
  kept only as the `"true"` or `"false"` the core checkbox sends; anything else
  is dropped, because a blank one would cast to `nil` for a boolean column.
  """

  @doc """
  Returns `params` with every non-string value blank and every value of a
  `checkboxes` field that is not `"true"` or `"false"` dropped.
  """
  @spec scalar(map(), [String.t()]) :: map()
  def scalar(params, checkboxes \\ []) when is_map(params) do
    Enum.reduce(params, %{}, fn {key, value}, acc ->
      put_scalar(acc, key, value, key in checkboxes)
    end)
  end

  defp put_scalar(acc, key, value, true) when value in ["true", "false"],
    do: Map.put(acc, key, value)

  defp put_scalar(acc, _key, _value, true), do: acc
  defp put_scalar(acc, key, value, false) when is_binary(value), do: Map.put(acc, key, value)
  defp put_scalar(acc, key, _value, false), do: Map.put(acc, key, "")
end
