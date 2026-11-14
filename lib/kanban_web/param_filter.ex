defmodule KanbanWeb.ParamFilter do
  @moduledoc """
  Filters params through `config :phoenix, :filter_parameters`, as Phoenix's
  own request and LiveView event logs do, for places those logs do not cover
  (`KanbanWeb.ErrorTrackerFilter`).

  Phoenix's function for this, `Phoenix.Logger.filter_values/2`, is not part
  of its public API, so a Phoenix upgrade could change or remove it without
  notice. This module gives the same results for the filter shapes Phoenix
  accepts:

    * a list of words, a single word or `{:discard, words}` - a map entry
      whose key contains one of the words, or whose string value contains
      `word=`, becomes `"[FILTERED]"`; structs are left as they are
    * `{:keep, keys}` - only the values of the listed keys are kept, and
      every other leaf, a struct included, becomes `"[FILTERED]"`

  Phoenix compiles a discard filter when it starts and stores it back in
  `:filter_parameters` as `{:compiled, key_pattern, value_pattern}`, so that
  shape is read too: its two patterns are what `String.contains?/2` takes.
  """

  @filtered "[FILTERED]"

  @doc """
  Filters `values` (a map, a list or a leaf) with `filter`, by default the
  configured `:filter_parameters`.
  """
  def filter(values, filter \\ Application.get_env(:phoenix, :filter_parameters, []))

  def filter(values, {:keep, keys}), do: keep(values, keys)
  def filter(values, {:discard, words}), do: filter(values, words)
  def filter(values, {:compiled, words, pairs}), do: discard(values, words, pairs)

  def filter(values, words) when is_list(words) or is_binary(words) do
    words = List.wrap(words)
    discard(values, words, Enum.map(words, &(&1 <> "=")))
  end

  defp discard(%{__struct__: module} = struct, _words, _pairs) when is_atom(module), do: struct

  defp discard(%{} = map, words, pairs),
    do: Map.new(map, fn {key, value} -> {key, discard_entry(key, value, words, pairs)} end)

  defp discard([_ | _] = list, words, pairs), do: Enum.map(list, &discard(&1, words, pairs))
  defp discard(other, _words, _pairs), do: other

  defp discard_entry(key, value, words, pairs) do
    cond do
      is_binary(key) and String.contains?(key, words) -> @filtered
      is_binary(value) and String.contains?(value, pairs) -> @filtered
      true -> discard(value, words, pairs)
    end
  end

  defp keep(%{__struct__: module}, _keys) when is_atom(module), do: @filtered

  defp keep(%{} = map, keys),
    do: Map.new(map, fn {key, value} -> {key, keep_entry(key, value, keys)} end)

  defp keep([_ | _] = list, keys), do: Enum.map(list, &keep(&1, keys))
  defp keep(_leaf, _keys), do: @filtered

  defp keep_entry(key, value, keys) do
    if is_binary(key) and key in keys, do: value, else: keep(value, keys)
  end
end
