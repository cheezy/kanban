defmodule KanbanWeb.ArchiveLive.Filters do
  @moduledoc """
  Pure, in-memory filtering and input coercion for the Archive view.

  Each `apply_*` function is a list transform over already-loaded,
  board-scoped rows — no Ecto, no `current_scope`. `KanbanWeb.ArchiveLive.Index`
  composes them in `recompute_rows/1`, and its event handlers use the
  `parse_*` coercers to turn untrusted chip/input values into the filter
  model. Extracted from the LiveView to keep that module under the size cap and
  to make the filtering logic unit-testable in isolation.

  The reason/assignee/date/search dimensions are independent, so the
  composition order in the caller does not affect the result.
  """
  require Logger

  @valid_reasons [:completed]

  @doc "The archive reasons the chip row can filter by."
  @spec valid_reasons() :: [atom()]
  def valid_reasons, do: @valid_reasons

  # --- Row filters ----------------------------------------------------------

  @doc "Filter by archive reason. `:completed` includes legacy nil-reason rows."
  def apply_reason(rows, :all), do: rows

  def apply_reason(rows, :completed) do
    Enum.filter(rows, fn task ->
      reason = task.archive_reason
      reason == :completed or is_nil(reason)
    end)
  end

  @doc "Filter by assignee — `:all`, `:unassigned` (nil), or an integer user id."
  def apply_assignee(rows, :all), do: rows

  def apply_assignee(rows, :unassigned) do
    Enum.filter(rows, &is_nil(&1.assigned_to))
  end

  def apply_assignee(rows, id) when is_integer(id) do
    Enum.filter(rows, fn task -> match?(%{id: ^id}, task.assigned_to) end)
  end

  @doc """
  Filter rows whose task title contains the search query (case-insensitive
  substring). A blank query is a no-op that returns every row. The query is
  untrusted free text — kept a string and matched with `String.contains?/2`,
  never coerced with `String.to_atom`.
  """
  def apply_search(rows, ""), do: rows

  def apply_search(rows, query) do
    needle = String.downcase(query)
    Enum.filter(rows, fn task -> String.contains?(String.downcase(task.title), needle) end)
  end

  @doc """
  Filter rows by the `archived_at` date within an inclusive `[from, to]` range.
  Both bounds are `Date.t() | nil`; a nil bound is open-ended, and both nil is a
  no-op that returns every row. When a bound is set, rows whose `archived_at` is
  nil are excluded rather than raising.
  """
  def apply_date_range(rows, nil, nil), do: rows

  def apply_date_range(rows, from, to) do
    Enum.filter(rows, fn task ->
      case task.archived_at do
        %DateTime{} = at -> date_in_range?(DateTime.to_date(at), from, to)
        _ -> false
      end
    end)
  end

  defp date_in_range?(date, from, to) do
    (is_nil(from) or Date.compare(date, from) != :lt) and
      (is_nil(to) or Date.compare(date, to) != :gt)
  end

  @doc "True when a row matches the given reason bucket (nil counts as :completed)."
  def reason_matches?(%{archive_reason: nil}, :completed), do: true
  def reason_matches?(%{archive_reason: r}, target), do: r == target

  # --- Input coercion -------------------------------------------------------

  @doc """
  Coerce the reason chip's phx-value into the `:filter` model. Unknown values
  log a warning and degrade to `:all`; never `String.to_atom`.
  """
  def parse_reason("all"), do: :all

  def parse_reason(raw) when is_binary(raw) do
    case Enum.find(@valid_reasons, fn r -> Atom.to_string(r) == raw end) do
      nil ->
        Logger.warning("ArchiveLive: unknown filter reason #{inspect(raw)} — defaulting to :all")
        :all

      reason ->
        reason
    end
  end

  def parse_reason(_), do: :all

  @doc """
  Coerce the assignee chip's phx-value into the `:assignee_filter` model. Parse
  ids with `Integer.parse` and string-compare the `"all"`/`"unassigned"`
  sentinels; never `String.to_atom`. Unparseable input degrades to `:all`.
  """
  def parse_assignee("all"), do: :all
  def parse_assignee("unassigned"), do: :unassigned

  def parse_assignee(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {id, ""} -> id
      _ -> :all
    end
  end

  def parse_assignee(_), do: :all

  @doc """
  Coerce an inbound date string into a `Date.t()`, or nil when absent/invalid.
  Never raises — an unparseable bound becomes nil (open-ended for `apply_date_range/3`).
  """
  def parse_date(value) when is_binary(value) and value != "" do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _reason} -> nil
    end
  end

  def parse_date(_), do: nil
end
