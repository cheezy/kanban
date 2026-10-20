defmodule KanbanWeb.IdParams do
  @moduledoc """
  Parses record ids that arrive in LiveView event params.

  Event params are whatever the client sends, so a crafted event can carry
  `"abc"`, `"1.5"`, a negative number or a 20-digit id where the page expects
  a row id. `String.to_integer/1` raises on the first three and the last one
  raises when it reaches Postgres, past the `bigint` range, so either crashes
  the sender's LiveView. `parse/1` and `parse_list/1` answer `:error` for all
  of them, and the handler treats that like a missing row.
  """

  # The Postgres bigint ceiling.
  @max_bigint 9_223_372_036_854_775_807

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
