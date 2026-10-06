defmodule Kanban.AuditLog.Filters do
  @moduledoc """
  Strict parsing of the untrusted query/form params the admin audit-log viewer
  and its export accept, shared by `KanbanWeb.Admin.AuditLogLive.Index` and
  `KanbanWeb.AuditLogExportController` so both apply identical filters.

  Accepted params (all optional, all strings):

    * `"action"` — an action name; must look like one (`[a-z][a-z0-9_]*`, at
      most 64 chars). Kept as a string and only ever bound as a query
      parameter — never converted to an atom.
    * `"actor_email"` — matched exactly (case-insensitively) against the actor
      account's email or the event's recorded email; trimmed, at most 254 bytes.
    * `"from"` / `"to"` — ISO-8601 dates (years 1–9999), interpreted as UTC
      days. Both are inclusive: `"to"` covers its whole day.
    * `"cursor"` — an opaque keyset cursor from `Kanban.AuditLog.Query`.

  An invalid value is dropped (that filter is simply not applied) rather than
  raising, and is removed from the normalized `params`.
  """

  alias Kanban.AuditLog.Query

  @action_format ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @max_email_bytes 254
  @year_range 1..9999

  @type t :: %{
          filters: keyword(),
          cursor: {DateTime.t(), pos_integer()} | nil,
          params: %{optional(String.t()) => String.t()}
        }

  @doc """
  Parses raw params into `%{filters: keyword, cursor: cursor | nil, params: map}`.

  `filters` is ready for `Kanban.AuditLog.list_events_page/2` and
  `Kanban.AuditLog.export_stream/2`; `params` holds only the accepted values,
  normalized, for rebuilding the form, patch URLs and export links.
  """
  @spec parse(term()) :: t()
  def parse(params) when is_map(params) do
    values = %{
      action: params |> Map.get("action") |> parse_action(),
      email: params |> Map.get("actor_email") |> parse_email(),
      from: params |> Map.get("from") |> parse_date(),
      to: params |> Map.get("to") |> parse_date()
    }

    cursor_text = Map.get(params, "cursor")
    cursor = Query.decode_cursor(cursor_text)

    %{
      filters: to_filters(values),
      cursor: cursor,
      params: values |> to_params() |> Map.put("cursor", cursor && cursor_text) |> reject_nil()
    }
  end

  def parse(_params), do: parse(%{})

  @doc """
  The applied filters as a plain map (no cursor), for recording in the
  `audit_log_exported` event. Keys are deliberately ones the audit-log
  sanitizer keeps.
  """
  @spec summary(t()) :: %{optional(String.t()) => String.t()}
  def summary(%{params: params}), do: Map.delete(params, "cursor")

  defp to_filters(%{action: action, email: email, from: from, to: to}) do
    [
      action: action,
      actor_email: email,
      since: from && start_of_day(from),
      until: to && start_of_day(Date.add(to, 1))
    ]
  end

  defp to_params(%{action: action, email: email, from: from, to: to}) do
    %{
      "action" => action,
      "actor_email" => email,
      "from" => from && Date.to_iso8601(from),
      "to" => to && Date.to_iso8601(to)
    }
  end

  defp parse_action(value) when is_binary(value) do
    if Regex.match?(@action_format, value), do: value
  end

  defp parse_action(_value), do: nil

  defp parse_email(value) when is_binary(value) do
    email = String.trim(value)

    if email != "" and byte_size(email) <= @max_email_bytes and String.valid?(email) and
         not String.contains?(email, <<0>>),
       do: email
  end

  defp parse_email(_value), do: nil

  # Only years 1..9999 are accepted. ISO-8601 also allows negative/extended
  # years, which Elixir parses but Postgres cannot bind as a timestamp (it
  # stops at 4713 BC), so such a date would crash the viewer and the export.
  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: year} = date} when year in @year_range -> date
      _invalid_or_out_of_range -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp start_of_day(date), do: DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")

  defp reject_nil(map), do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
end
