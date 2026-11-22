defmodule Kanban.Workspaces.Export.Importer.Timestamps do
  @moduledoc """
  Prepares an archive row's timestamps for the importer's `:naive_datetime`
  columns.

  Those columns hold UTC with no zone, and `Ecto.Changeset.cast/3` drops a
  value's UTC offset instead of applying it, so `2026-10-07T15:40:52+02:00`
  would be stored as `2026-10-07 15:40:52`, two hours late. `to_utc/1`
  converts each value that carries an offset (including `Z`) to the UTC
  `NaiveDateTime` it names, before the cast. Every other value is returned
  unchanged, so a naive value is stored as written and an invalid one still
  fails its row with the cast's own error.
  """

  @doc """
  Returns `values` with every ISO 8601 string that carries a UTC offset
  replaced by the same instant as a UTC `NaiveDateTime`.

      iex> to_utc(%{"inserted_at" => "2026-10-07T15:40:52+02:00"})
      %{"inserted_at" => ~N[2026-10-07 13:40:52]}

      iex> to_utc(%{"inserted_at" => "2026-10-07T15:40:52", "updated_at" => nil})
      %{"inserted_at" => "2026-10-07T15:40:52", "updated_at" => nil}
  """
  @spec to_utc(%{optional(String.t()) => term()}) :: %{optional(String.t()) => term()}
  def to_utc(values) when is_map(values), do: Map.new(values, fn {k, v} -> {k, value(v)} end)

  defp value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_naive(datetime)
      {:error, _reason} -> value
    end
  end

  defp value(value), do: value
end
