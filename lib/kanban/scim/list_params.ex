defmodule Kanban.SCIM.ListParams do
  @moduledoc """
  The pagination parameters of a SCIM list request (RFC 7644 §3.4.2.4):
  `startIndex` is 1-based and `count` is the page size. Values a client gets
  wrong are clamped rather than refused, as the RFC asks: a `startIndex`
  below 1 reads as 1, a negative `count` as 0, and a `count` above
  200 as 200. Anything that is not an integer falls back to the default.
  """

  @default_count 100
  @max_count 200

  @type t :: %{start_index: pos_integer(), count: non_neg_integer()}

  @doc """
  Reads `startIndex` and `count` from request params.

  ## Examples

      iex> Kanban.SCIM.ListParams.parse(%{"startIndex" => "3", "count" => "10"})
      %{start_index: 3, count: 10}

      iex> Kanban.SCIM.ListParams.parse(%{})
      %{start_index: 1, count: 100}

  """
  @spec parse(map()) :: t()
  def parse(params) when is_map(params) do
    %{
      start_index: params |> Map.get("startIndex") |> to_integer(1) |> max(1),
      count: params |> Map.get("count") |> to_integer(@default_count) |> max(0) |> min(@max_count)
    }
  end

  @doc "The largest page a list returns."
  @spec max_count() :: pos_integer()
  def max_count, do: @max_count

  defp to_integer(value, _default) when is_integer(value), do: value

  defp to_integer(value, default) when is_binary(value) do
    case value |> String.trim() |> Integer.parse() do
      {int, ""} when int in -1_000_000_000..1_000_000_000 -> int
      _other -> default
    end
  end

  defp to_integer(_value, default), do: default
end
