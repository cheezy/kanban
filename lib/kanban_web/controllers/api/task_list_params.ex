defmodule KanbanWeb.API.TaskListParams do
  @moduledoc """
  Parses and validates the opt-in pagination and filter parameters of
  `GET /api/tasks` (W2224).

  **Paginated mode is triggered by key presence.** When any of `limit`,
  `cursor`, `status`, `type`, `priority`, `assigned_to_id`, `parent` or
  `updated_since` is present in the query string — even with a blank value —
  the endpoint switches to the paginated path, and a blank or malformed value
  is a `400` rather than a silent fall back to the legacy response. With none of
  them present the legacy, unpaginated response is returned unchanged.
  `column_id` and `response_view` are deliberately not page keys: on their own
  they keep the legacy behaviour, and in paginated mode they combine with the
  filters.

  Validation is pure — no conn, no database — so every rejection happens before
  any data is touched, on the `KanbanWeb.API.TaskFieldsProjection.resolve/1`
  convention. Enum values are matched against the `Ecto.Enum` string mappings
  and never converted with `String.to_atom/1`, which would be an
  atom-exhaustion vector on attacker-controlled input.

  The cursor is opaque to clients: the URL-safe base64 (unpadded) encoding of
  the last returned task id. It is decoded defensively and accepted only when
  it is a positive integer within the Postgres `bigint` range.
  """

  alias Kanban.Tasks.Task

  @page_fields [
    :limit,
    :cursor,
    :status,
    :type,
    :priority,
    :assigned_to_id,
    :parent,
    :updated_since
  ]
  @page_keys Enum.map(@page_fields, &Atom.to_string/1)

  @default_limit 50
  @max_limit 200
  @max_id 9_223_372_036_854_775_807
  @max_cursor_bytes 32
  @max_parent_bytes 255

  @filter_keys [:status, :type, :priority, :assigned_to_id, :parent, :updated_since]

  defstruct limit: @default_limit,
            cursor: nil,
            status: nil,
            type: nil,
            priority: nil,
            assigned_to_id: nil,
            parent: nil,
            updated_since: nil

  @type t :: %__MODULE__{
          limit: pos_integer(),
          cursor: pos_integer() | nil,
          status: atom() | nil,
          type: atom() | nil,
          priority: atom() | nil,
          assigned_to_id: pos_integer() | nil,
          parent: String.t() | nil,
          updated_since: NaiveDateTime.t() | nil
        }

  @doc """
  Whether the request opts into paginated mode — true when any page key is
  present, whatever its value.
  """
  @spec paginated?(map()) :: boolean()
  def paginated?(params) when is_map(params) do
    Enum.any?(@page_keys, &Map.has_key?(params, &1))
  end

  @doc """
  Parses the page keys of `params` into a `t:t/0`.

  Keys are validated in a fixed order so the first error reported is
  deterministic. An absent key keeps its default (`limit` 50, every filter
  `nil`). Returns `{:error, message}` for the first invalid value.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, String.t()}
  def parse(params) when is_map(params) do
    Enum.reduce_while(@page_fields, {:ok, %__MODULE__{}}, fn field, {:ok, acc} ->
      case Map.fetch(params, Atom.to_string(field)) do
        :error -> {:cont, {:ok, acc}}
        {:ok, value} -> put_parsed(acc, field, value)
      end
    end)
  end

  defp put_parsed(acc, field, value) do
    case parse_value(field, value) do
      {:ok, parsed} -> {:cont, {:ok, Map.put(acc, field, parsed)}}
      {:error, _message} = error -> {:halt, error}
    end
  end

  @doc """
  The filters to apply, as a map of only the non-nil filter fields.
  `limit` and `cursor` are paging controls, not filters, and are excluded.
  """
  @spec filters(t()) :: map()
  def filters(%__MODULE__{} = page) do
    page
    |> Map.take(@filter_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Encodes a task id as an opaque cursor. `nil` (no further page) stays `nil`.
  """
  @spec encode_cursor(pos_integer() | nil) :: String.t() | nil
  def encode_cursor(nil), do: nil

  def encode_cursor(id) when is_integer(id) and id > 0 do
    id |> Integer.to_string() |> Base.url_encode64(padding: false)
  end

  defp parse_value(:limit, value) do
    case parse_int(value) do
      {:ok, n} when n >= 1 and n <= @max_limit -> {:ok, n}
      _ -> {:error, "Invalid limit: must be an integer between 1 and #{@max_limit}"}
    end
  end

  defp parse_value(:cursor, value)
       when is_binary(value) and byte_size(value) <= @max_cursor_bytes do
    with {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, id} <- parse_positive_id(decoded) do
      {:ok, id}
    else
      _ -> invalid_cursor()
    end
  end

  defp parse_value(:cursor, _value), do: invalid_cursor()

  defp parse_value(field, value) when field in [:status, :type, :priority] do
    mappings = Ecto.Enum.mappings(Task, field)

    case Enum.find(mappings, fn {_atom, string} -> string == value end) do
      {atom, _string} ->
        {:ok, atom}

      nil ->
        allowed = Enum.map_join(mappings, ", ", fn {_atom, string} -> string end)
        {:error, "Invalid #{field}: must be one of #{allowed}"}
    end
  end

  defp parse_value(:assigned_to_id, value) do
    case parse_positive_id(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "Invalid assigned_to_id: must be a positive integer"}
    end
  end

  defp parse_value(:parent, value)
       when is_binary(value) and value != "" and byte_size(value) <= @max_parent_bytes do
    {:ok, value}
  end

  defp parse_value(:parent, _value),
    do: {:error, "Invalid parent: must be a goal identifier such as G12"}

  defp parse_value(:updated_since, value) when is_binary(value) do
    case parse_datetime(value) do
      {:ok, naive} -> {:ok, naive}
      :error -> invalid_updated_since()
    end
  end

  defp parse_value(:updated_since, _value), do: invalid_updated_since()

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_int(_value), do: :error

  defp parse_positive_id(value) do
    case parse_int(value) do
      {:ok, n} when n >= 1 and n <= @max_id -> {:ok, n}
      _ -> :error
    end
  end

  # An offset-carrying timestamp is shifted to UTC; one without an offset is
  # taken as UTC, matching how `updated_at` (a naive UTC timestamp) is stored.
  # A bare date is rejected: both parsers require a time component.
  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok,
         datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive() |> floor_second()}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> {:ok, floor_second(naive)}
          {:error, _} -> :error
        end
    end
  end

  # `updated_at` is written truncated to the whole second, so the comparison is
  # made at whole-second precision: a fractional bound is floored, explicitly,
  # rather than left to the `:naive_datetime` type's silent truncation when the
  # query parameter is cast.
  # Flooring (not rounding up) is deliberate for incremental sync: a task
  # updated at 12:00:00.7 is stored as 12:00:00, and a client polling with
  # updated_since=12:00:00.4 must still receive it. The cost is that a task
  # updated earlier in that same second may be returned again — a duplicate an
  # idempotent sync absorbs, where rounding up would lose the update outright.
  defp floor_second(naive), do: NaiveDateTime.truncate(naive, :second)

  defp invalid_cursor,
    do: {:error, "Invalid cursor: use the meta.next_cursor value from a previous page"}

  defp invalid_updated_since,
    do:
      {:error, "Invalid updated_since: must be an ISO 8601 datetime such as 2026-01-31T12:00:00Z"}
end
