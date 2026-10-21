defmodule KanbanWeb.SCIM.DiscoveryController do
  @moduledoc """
  The SCIM discovery endpoints (RFC 7644 §4, W2247): ServiceProviderConfig,
  ResourceTypes and Schemas, describing what Stride supports.
  """
  use KanbanWeb, :controller

  alias KanbanWeb.SCIM.DiscoveryJSON
  alias KanbanWeb.SCIM.Response

  action_fallback KanbanWeb.SCIM.FallbackController

  def service_provider_config(conn, _params),
    do: Response.send_json(conn, 200, DiscoveryJSON.service_provider_config())

  def resource_types(conn, _params) do
    types = DiscoveryJSON.resource_types()
    Response.send_json(conn, 200, Response.list(%{total: length(types), start_index: 1}, types))
  end

  def resource_type(conn, %{"id" => id}) do
    case Enum.find(DiscoveryJSON.resource_types(), &(&1["id"] == id)) do
      nil -> {:error, :not_found}
      type -> Response.send_json(conn, 200, type)
    end
  end

  def schemas(conn, _params) do
    schemas = DiscoveryJSON.schemas()

    Response.send_json(
      conn,
      200,
      Response.list(%{total: length(schemas), start_index: 1}, schemas)
    )
  end

  def schema(conn, %{"id" => id}) do
    case Enum.find(DiscoveryJSON.schemas(), &(&1["id"] == id)) do
      nil -> {:error, :not_found}
      schema -> Response.send_json(conn, 200, schema)
    end
  end
end
