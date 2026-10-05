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
  def render("406.json", %{conn: %Plug.Conn{path_info: ["api" | _]}}) do
    %{error: "Not Acceptable", message: "This API only serves application/json."}
  end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
