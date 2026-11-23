defmodule KanbanWeb.ErrorJSON do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on JSON requests.

  See config/config.exs.
  """

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  # def render("500.json", _assigns) do
  #   %{errors: %{detail: "Internal Server Error"}}
  # end

  @api_errors %{
    "400.json" => {"Bad Request", "The request is malformed and could not be processed."},
    "413.json" => {"Request Entity Too Large", "The request body is too large."},
    "415.json" => {"Unsupported Media Type", "Send the request body as application/json."}
  }

  # The agent API, the MCP endpoint and the person API share the `error` +
  # `message` body for these statuses.
  @api_scopes [:api, :mcp, :device_api]

  @oauth_errors %{
    "400.json" => "The request is malformed and could not be processed.",
    "404.json" => "No endpoint matches this request.",
    "413.json" => "The request body is too large.",
    "415.json" =>
      "Send the request body as application/x-www-form-urlencoded or application/json."
  }

  # Each API is told apart by KanbanWeb.PathScope, on the decoded segments the
  # router matches (D462), so a percent-encoded prefix such as /%61pi/me gets
  # the same body as /api/me.
  def render(template, %{conn: %Plug.Conn{} = conn}) do
    render_scoped(KanbanWeb.PathScope.of(conn), template)
  end

  def render(template, _assigns), do: generic(template)

  # 404 Not Found on the person API (D462). A path under /api/me that no route
  # matches answers the same `{"error": "Not Found"}` body as the API's own
  # 404s (KanbanWeb.API.Me.FallbackController), never the generic
  # `errors.detail` fallback below. KanbanWeb.Plugs.Parsers pins the format
  # to json for /api/me paths, so this renders whatever the Accept header
  # says. The body is a fixed string: it never echoes the path or a header.
  defp render_scoped(:device_api, "404.json"), do: %{error: "Not Found"}

  # 406 Not Acceptable on an /api route (D351). Raised by
  # `plug :accepts, ["json"]` in the :api and :api_public pipelines when a
  # client asks for a format the API does not serve (e.g. Accept: text/html).
  # Returns the API's own error shape (`error` + `message`, the OpenAPI `Error`
  # schema) rather than the generic `errors.detail` fallback below. The message
  # is a fixed string: it must never echo the client-supplied Accept header or
  # `_format` value.
  #
  # Only /api requests get this body. A :browser route requested with
  # Accept: application/json also renders "406.json" here, and its body stays
  # the generic fallback, because "This API only serves application/json."
  # would be false for an HTML page.
  defp render_scoped(scope, "406.json") when scope in @api_scopes do
    %{error: "Not Acceptable", message: "This API only serves application/json."}
  end

  # 400, 413 and 415 on an /api route (D353). These are raised by Plug.Parsers
  # in the endpoint, before the router, for a malformed query string or body
  # (400), a body over the size limit (413) or a content type it cannot parse
  # (415); a 400 can also come from a controller (for example an Ecto cast
  # error). KanbanWeb.Plugs.Parsers pins the format to json for /api paths so
  # these render here rather than through ErrorHTML. Like the 406, each body is
  # the API's `error` + `message` shape with a fixed message that never echoes
  # the query string, the body, a header or the exception text.
  defp render_scoped(scope, template)
       when scope in @api_scopes and is_map_key(@api_errors, template) do
    {error, message} = Map.fetch!(@api_errors, template)
    %{error: error, message: message}
  end

  # The device sign-in token API (W2746). An app reads every refusal there as
  # an RFC 6749 §5.2 error, so a 400, 413 or 415 raised by Plug.Parsers, and a
  # 404 for an /oauth path no route matches (D462), is an `invalid_request`
  # with a fixed description, and a 406 is the API's own Not Acceptable body.
  # Every /oauth path except the authorize page, which is HTML.
  defp render_scoped(:oauth, "406.json") do
    %{error: "Not Acceptable", message: "This API only serves application/json."}
  end

  defp render_scoped(:oauth, template) when is_map_key(@oauth_errors, template) do
    %{error: "invalid_request", error_description: Map.fetch!(@oauth_errors, template)}
  end

  defp render_scoped(_scope, template), do: generic(template)

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  defp generic(template) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
