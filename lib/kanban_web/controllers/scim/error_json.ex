defmodule KanbanWeb.SCIM.ErrorJSON do
  @moduledoc """
  Renders errors raised on `/scim/v2` (W2247) in the SCIM error schema
  (RFC 7644 §3.12), for `Phoenix.Endpoint.RenderErrors` (the `scim` format in
  `config/config.exs`) and for `KanbanWeb.SCIM.Response`.

  The `detail` is a fixed message per status: it never echoes the request.
  """

  @error_schema "urn:ietf:params:scim:api:messages:2.0:Error"

  @details %{
    400 => "The request is malformed and could not be processed.",
    401 => "A valid SCIM bearer token is required.",
    404 => "Resource not found.",
    406 => "Not acceptable.",
    413 => "The request body is too large.",
    415 => "Send the request body as application/scim+json or application/json.",
    429 => "Too many requests."
  }

  @doc """
  Renders the SCIM error for an error template such as `"404.scim"`.
  """
  def render(template, _assigns) do
    status = template |> String.split(".") |> hd() |> String.to_integer()
    error(status, nil, Map.get(@details, status, "The request could not be completed."))
  rescue
    ArgumentError -> error(500, nil, "The request could not be completed.")
  end

  @doc "A SCIM error body. `scim_type` may be `nil`."
  @spec error(pos_integer(), String.t() | nil, String.t()) :: map()
  def error(status, scim_type, detail) when is_integer(status) and is_binary(detail) do
    %{"schemas" => [@error_schema], "status" => Integer.to_string(status), "detail" => detail}
    |> put_scim_type(scim_type)
  end

  defp put_scim_type(body, nil), do: body
  defp put_scim_type(body, scim_type), do: Map.put(body, "scimType", scim_type)
end
