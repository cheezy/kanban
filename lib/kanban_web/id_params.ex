defmodule KanbanWeb.IdParams do
  @moduledoc """
  Parses record ids that arrive in LiveView event params.

  Event params are whatever the client sends, so a crafted event can carry
  `"abc"`, `"1.5"`, a negative number or a 20-digit id where the page expects
  a row id. `String.to_integer/1` raises on the first three and the last one
  raises when it reaches Postgres, past the `bigint` range, so either crashes
  the sender's LiveView. `parse/1` and `parse_list/1` answer `:error` for all
  of them, and the handler treats that like a missing row.

  `parse_index/1` does the same for row positions in a list, such as the
  `index` a form's remove-row button sends, where `0` is the first row.
  """

  # The Postgres bigint ceiling.
  @max_bigint 9_223_372_036_854_775_807

  # Far past any list a form edits; a larger index cannot name a row.
  @max_index 10_000

  @doc """
  Returns `{:ok, id}` for a positive integer within the `bigint` range, or a
  string holding exactly one, and `:error` for anything else.

  ## Examples

      iex> KanbanWeb.IdParams.parse("42")
      {:ok, 42}

      iex> KanbanWeb.IdParams.parse("abc")
      :error

  """
  @spec parse(term()) :: {:ok, pos_integer()} | :error
  def parse(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: {:ok, id}

  def parse(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parse(parsed)
      _other -> :error
    end
  end

  def parse(_id), do: :error

  @doc """
  Returns `{:ok, index}` for a list position from `0` to #{@max_index}, or a
  string holding exactly one, and `:error` for anything else.

  Unlike `parse/1` it accepts `0`. A negative index is refused because
  `List.delete_at/2` counts it from the end and would remove a different row.

  ## Examples

      iex> KanbanWeb.IdParams.parse_index("0")
      {:ok, 0}

      iex> KanbanWeb.IdParams.parse_index("-1")
      :error

  """
  @spec parse_index(term()) :: {:ok, non_neg_integer()} | :error
  def parse_index(index) when is_integer(index) and index >= 0 and index <= @max_index,
    do: {:ok, index}

  def parse_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {parsed, ""} -> parse_index(parsed)
      _other -> :error
    end
  end

  def parse_index(_index), do: :error

  @doc """
  Parses every element of `ids` with `parse/1`, returning `{:ok, ids}` in the
  same order, or `:error` when `ids` is not a list or any element fails.

  ## Examples

      iex> KanbanWeb.IdParams.parse_list(["3", 1])
      {:ok, [3, 1]}

      iex> KanbanWeb.IdParams.parse_list(["3", "x"])
      :error

  """
  @spec parse_list(term()) :: {:ok, [pos_integer()]} | :error
  def parse_list(ids) when is_list(ids) do
    ids
    |> Enum.reduce_while([], fn id, acc ->
      case parse(id) do
        {:ok, parsed} -> {:cont, [parsed | acc]}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :error -> :error
      parsed -> {:ok, Enum.reverse(parsed)}
    end
  end

  def parse_list(_ids), do: :error
end
