defmodule KanbanWeb.BoardLive.FilterParams do
  @moduledoc """
  Pure translation between the board view's URL query params and a
  `%Kanban.Tasks.BoardFilters{}` (W2235).

  The params are untrusted — they come from a shared link or a form — so
  every value is matched against a whitelist: enum values by string
  comparison against the schema's own `Ecto.Enum` values (never
  `String.to_atom`), ids by exact `Integer.parse`, and search text trimmed
  and capped. Anything unknown or malformed is dropped silently, so a bad
  link renders the unfiltered board instead of crashing.

  | Param      | Accepted values                          |
  |------------|------------------------------------------|
  | `q`        | free text, trimmed, at most 100 graphemes |
  | `type`     | `work`, `defect`, `goal`                 |
  | `priority` | `low`, `medium`, `high`, `critical`      |
  | `assignee` | `unassigned` or a positive user id       |
  | `label`    | a positive label id                      |

  `parse/1` validates shape only. `restrict/3` then drops an assignee or a
  label that does not belong to the current board, and `encode/1` turns the
  struct back into query params for `push_patch`, so a parsed URL
  round-trips.
  """

  alias Kanban.Tasks.BoardFilters
  alias Kanban.Tasks.Task

  @max_search_length 100

  @types Task |> Ecto.Enum.values(:type) |> Map.new(&{Atom.to_string(&1), &1})
  @priorities Task |> Ecto.Enum.values(:priority) |> Map.new(&{Atom.to_string(&1), &1})

  @doc "The longest search text kept, in graphemes."
  def max_search_length, do: @max_search_length

  @doc """
  Builds a `%BoardFilters{}` from a params map, keeping only whitelisted
  values. Unknown keys and values are ignored.
  """
  @spec parse(map()) :: BoardFilters.t()
  def parse(params) when is_map(params) do
    %BoardFilters{
      search: parse_search(params["q"]),
      type: Map.get(@types, string_param(params["type"])),
      priority: Map.get(@priorities, string_param(params["priority"])),
      assignee: parse_assignee(params["assignee"]),
      label_id: parse_id(params["label"])
    }
  end

  def parse(_), do: %BoardFilters{}

  @doc """
  Drops an integer assignee that is not one of `member_ids` and a label that
  is not one of `label_ids`, so ids from another board never reach the
  query. `:unassigned` is always kept.
  """
  @spec restrict(BoardFilters.t(), [integer()], [integer()]) :: BoardFilters.t()
  def restrict(%BoardFilters{} = filters, member_ids, label_ids) do
    %{
      filters
      | assignee: keep_member(filters.assignee, member_ids),
        label_id: keep_if_member(filters.label_id, label_ids)
    }
  end

  @doc """
  Encodes the set dimensions as query params, in a stable order, omitting
  unset ones. `parse(Map.new(encode(f)))` returns `f` for any parsed `f`.
  """
  @spec encode(BoardFilters.t()) :: [{String.t(), String.t()}]
  def encode(%BoardFilters{} = filters) do
    [
      {"q", filters.search},
      {"type", atom_param(filters.type)},
      {"priority", atom_param(filters.priority)},
      {"assignee", assignee_param(filters.assignee)},
      {"label", id_param(filters.label_id)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  The filter bar's selected values, as strings keyed by input name (`""`
  for an unset dimension).
  """
  @spec form_values(BoardFilters.t()) :: %{String.t() => String.t()}
  def form_values(%BoardFilters{} = filters) do
    defaults = %{"q" => "", "type" => "", "priority" => "", "assignee" => "", "label" => ""}
    Map.merge(defaults, Map.new(encode(filters)))
  end

  defp parse_search(value) when is_binary(value) do
    case value |> String.trim() |> String.slice(0, @max_search_length) |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp parse_search(_), do: nil

  defp parse_assignee("unassigned"), do: :unassigned
  defp parse_assignee(value), do: parse_id(value)

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp string_param(value) when is_binary(value), do: value
  defp string_param(_), do: nil

  defp keep_member(id, member_ids) when is_integer(id), do: keep_if_member(id, member_ids)
  defp keep_member(other, _member_ids), do: other

  defp keep_if_member(nil, _ids), do: nil
  defp keep_if_member(id, ids), do: if(id in ids, do: id)

  defp atom_param(nil), do: nil
  defp atom_param(value), do: Atom.to_string(value)

  defp assignee_param(:unassigned), do: "unassigned"
  defp assignee_param(value), do: id_param(value)

  defp id_param(nil), do: nil
  defp id_param(id), do: Integer.to_string(id)
end
