defmodule KanbanWeb.ErrorTrackerFilter do
  @moduledoc """
  Removes secret tokens from ErrorTracker contexts before they are stored.

  ErrorTracker records the raw query string, the params and the request
  headers of a failing request, and the URI and params of a failing LiveView,
  while `:filter_parameters` only covers Phoenix's own logging. Two kinds of
  token are redacted, and a failing LiveView event's params are filtered
  through `:filter_parameters`:

    * A notification unsubscribe token travels as `?token=` on the
      `/notifications/unsubscribe` routes, and can also appear in a `Referer`
      header pointing back at one of those pages, so the query string, the
      `token` param and such a Referer are redacted.
    * The release announcement list's routes under `/releases/` carry a
      confirmation or unsubscribe token as `?token=`, and its signup posts an
      email address as `subscriber[email]`, so on those routes the query
      string, the `token` param, the `subscriber` param and any Referer
      pointing back at one of them are redacted.
    * A token in the path (`KanbanWeb.TokenPaths`: an invitation link,
      password reset or a confirmation) appears in the request path, the
      LiveView URI, the `token` param and any Referer pointing at one of those
      pages, so the token segment and the `token` param are redacted.
    * The device sign-in token endpoints, `POST /oauth/token` and
      `POST /oauth/revoke`, take authorization codes, PKCE verifiers and
      refresh tokens as params, so a failing request's params there are
      filtered through `:filter_parameters` and its query string redacted.
    * The person API under `/api/me/` takes secrets as params too: an app
      approval sends its single-use nonce and its signature to
      `POST /api/me/reviews/:task_id/approve`. A failing request's params
      there are filtered through `:filter_parameters`, which lists `nonce`
      and `signature`.
    * An app review decision may send an `Idempotency-Key` header (W2755),
      which is only ever stored as a hash, so that header is redacted from a
      failing request's headers on any route.
  """

  @behaviour ErrorTracker.Filter

  alias KanbanWeb.ParamFilter
  alias KanbanWeb.TokenPaths

  @redacted "[REDACTED]"
  @unsubscribe_path "/notifications/unsubscribe"
  @releases_prefix "/releases/"
  @token_locations ["request.path", "live_view.uri"]
  @token_params ["request.params", "live_view.params"]
  @oauth_paths ["/oauth/token", "/oauth/revoke"]
  @person_api_prefix "/api/me/"

  @impl ErrorTracker.Filter
  def sanitize(context) when is_map(context) do
    context
    |> redact_unsubscribe_request()
    |> redact_releases_request()
    |> redact_token_path_request()
    |> redact_secret_headers()
    |> redact_event_params()
    |> redact_oauth_request()
    |> redact_person_api_params()
  end

  def sanitize(context), do: context

  # A failing LiveView event's params go through :filter_parameters as
  # Phoenix's own event log does, so a secret sent under a filtered key (the
  # audit stream form's destination[secret_token]) is never stored.
  defp redact_event_params(%{"live_view.event_params" => %{} = params} = context),
    do: Map.put(context, "live_view.event_params", ParamFilter.filter(params))

  defp redact_event_params(context), do: context

  defp redact_oauth_request(%{"request.path" => path} = context) when path in @oauth_paths do
    context
    |> Map.replace_lazy("request.params", &ParamFilter.filter/1)
    |> Map.replace("request.query", @redacted)
  end

  defp redact_oauth_request(context), do: context

  defp redact_person_api_params(%{"request.path" => @person_api_prefix <> _} = context),
    do: Map.replace_lazy(context, "request.params", &ParamFilter.filter/1)

  defp redact_person_api_params(context), do: context

  defp redact_unsubscribe_request(%{"request.path" => @unsubscribe_path <> _} = context) do
    context
    |> Map.put("request.query", @redacted)
    |> Map.update("request.params", nil, &redact_token_param/1)
  end

  defp redact_unsubscribe_request(context), do: context

  defp redact_releases_request(%{"request.path" => @releases_prefix <> _} = context) do
    context
    |> Map.put("request.query", @redacted)
    |> Map.update("request.params", nil, &redact_releases_params/1)
  end

  defp redact_releases_request(context), do: context

  defp redact_releases_params(%{} = params) do
    params
    |> redact_token_param()
    |> Map.replace("subscriber", @redacted)
  end

  defp redact_releases_params(params), do: params

  defp redact_token_path_request(context) do
    if Enum.any?(@token_locations, &TokenPaths.token_path?(context[&1])) do
      context
      |> replace_existing(@token_locations, &TokenPaths.redact(&1, @redacted))
      |> replace_existing(@token_params, &redact_token_param/1)
    else
      context
    end
  end

  defp replace_existing(context, keys, fun),
    do: Enum.reduce(keys, context, &Map.replace_lazy(&2, &1, fun))

  defp redact_token_param(%{"token" => _} = params), do: Map.put(params, "token", @redacted)
  defp redact_token_param(params), do: params

  defp redact_secret_headers(%{"request.headers" => %{} = headers} = context) do
    Map.put(context, "request.headers", Map.new(headers, &redact_header/1))
  end

  defp redact_secret_headers(context), do: context

  defp redact_header({"referer", value}) when is_binary(value) do
    if String.contains?(value, @unsubscribe_path) or String.contains?(value, @releases_prefix),
      do: {"referer", @redacted},
      else: {"referer", TokenPaths.redact(value, @redacted)}
  end

  defp redact_header({"idempotency-key", _value}), do: {"idempotency-key", @redacted}
  defp redact_header(header), do: header
end
