defmodule KanbanWeb.ErrorTrackerFilter do
  @moduledoc """
  Removes notification unsubscribe tokens from ErrorTracker contexts before
  they are stored.

  ErrorTracker records the raw query string, the params and the request
  headers of a failing request, while `:filter_parameters` only covers
  Phoenix's own logging. An unsubscribe token travels as `?token=` on the
  `/notifications/unsubscribe` routes, and can also appear in a `Referer`
  header pointing back at one of those pages, so all three are redacted.
  """

  @behaviour ErrorTracker.Filter

  @redacted "[REDACTED]"
  @unsubscribe_path "/notifications/unsubscribe"

  @impl ErrorTracker.Filter
  def sanitize(context) when is_map(context) do
    context
    |> redact_unsubscribe_request()
    |> redact_unsubscribe_referer()
  end

  def sanitize(context), do: context

  defp redact_unsubscribe_request(%{"request.path" => @unsubscribe_path <> _} = context) do
    context
    |> Map.put("request.query", @redacted)
    |> Map.update("request.params", nil, &redact_token_param/1)
  end

  defp redact_unsubscribe_request(context), do: context

  defp redact_token_param(%{"token" => _} = params), do: Map.put(params, "token", @redacted)
  defp redact_token_param(params), do: params

  defp redact_unsubscribe_referer(%{"request.headers" => %{} = headers} = context) do
    Map.put(context, "request.headers", Map.new(headers, &redact_referer/1))
  end

  defp redact_unsubscribe_referer(context), do: context

  defp redact_referer({"referer", value}) when is_binary(value) do
    if String.contains?(value, @unsubscribe_path),
      do: {"referer", @redacted},
      else: {"referer", value}
  end

  defp redact_referer(header), do: header
end
