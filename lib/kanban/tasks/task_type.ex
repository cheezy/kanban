defmodule Kanban.Tasks.TaskType do
  @moduledoc """
  Resolves the `type` a caller supplies when creating a task (D352).

  `Kanban.Tasks.Task`'s `Ecto.Enum` on `:type` is the single source of truth for
  the accepted values; nothing here keeps a second list. Client input is never
  converted to an atom: a binary is compared with the enum's string forms, so an
  unrecognised value can neither raise nor grow the atom table.

  Used by `Kanban.Tasks.Creation` to decide whether a new task is subject to a
  column's WIP limit, and to make sure a blank type reaches the changeset as
  `nil` (rejected as "can't be blank") rather than being cast to the `:work`
  default by Ecto's empty-value handling.
  """

  alias Kanban.Tasks.Task

  @doc """
  Returns the task type an attrs map asks for, as `from_value/1` resolves it.

  An attrs map with no `:type` or `"type"` key asks for the schema default,
  `:work`. A present key is resolved even when its value is `nil`.

      iex> Kanban.Tasks.TaskType.from_attrs(%{"type" => "defect"})
      :defect

      iex> Kanban.Tasks.TaskType.from_attrs(%{"title" => "no type"})
      :work
  """
  def from_attrs(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :type) -> from_value(attrs[:type])
      Map.has_key?(attrs, "type") -> from_value(attrs["type"])
      true -> :work
    end
  end

  @doc """
  Resolves one supplied type value to its `Ecto.Enum` atom, or `:unknown`.

  Matches are exact: an enum atom or its string form. Anything else — another
  string (including case or whitespace variants), `nil`, a number, a list, a
  map or an unknown atom — is `:unknown`, which gets no WIP-limit decision and
  is left for the changeset to reject.

      iex> Kanban.Tasks.TaskType.from_value("goal")
      :goal

      iex> Kanban.Tasks.TaskType.from_value("Work")
      :unknown
  """
  def from_value(value) do
    Task
    |> Ecto.Enum.mappings(:type)
    |> Enum.find_value(:unknown, fn {atom, string} ->
      if value === atom or value === string, do: atom
    end)
  end

  @doc """
  Replaces an empty or whitespace-only string `type` (atom or string key) with
  `nil`, leaving every other value untouched.

  Ecto's cast treats such a string as an empty value and applies the field
  default, so without this a blank type would be stored as `:work`.

      iex> Kanban.Tasks.TaskType.blank_to_nil(%{"type" => "  "})
      %{"type" => nil}

      iex> Kanban.Tasks.TaskType.blank_to_nil(%{type: "work"})
      %{type: "work"}
  """
  def blank_to_nil(attrs) when is_map(attrs) do
    attrs |> nil_if_blank(:type) |> nil_if_blank("type")
  end

  defp nil_if_blank(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) -> put_nil_if_blank(attrs, key, String.trim(value))
      _ -> attrs
    end
  end

  defp put_nil_if_blank(attrs, key, ""), do: Map.put(attrs, key, nil)
  defp put_nil_if_blank(attrs, _key, _trimmed), do: attrs
end
