defmodule KanbanWeb.SCIM.Response do
  @moduledoc """
  Sends SCIM responses (W2247): JSON bodies with the
  `application/scim+json` content type, SCIM errors, and the resource and
  list shapes of RFC 7644.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: KanbanWeb.Endpoint,
    router: KanbanWeb.Router

  import Plug.Conn

  alias Kanban.SCIM.UserMapping
  alias KanbanWeb.SCIM.ErrorJSON

  @list_schema "urn:ietf:params:scim:api:messages:2.0:ListResponse"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"

  @doc "Sends `body` as `application/scim+json` with `status`."
  @spec send_json(Plug.Conn.t(), non_neg_integer(), map()) :: Plug.Conn.t()
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/scim+json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
  end

  @doc "Sends a SCIM error."
  @spec send_error(Plug.Conn.t(), non_neg_integer(), String.t() | nil, String.t()) ::
          Plug.Conn.t()
  def send_error(conn, status, scim_type, detail),
    do: send_json(conn, status, ErrorJSON.error(status, scim_type, detail))

  @doc "A ListResponse of already-rendered resources."
  @spec list(map(), [map()]) :: map()
  def list(%{total: total, start_index: start_index}, resources) do
    %{
      "schemas" => [@list_schema],
      "totalResults" => total,
      "startIndex" => start_index,
      "itemsPerPage" => length(resources),
      "Resources" => resources
    }
  end

  @doc "Renders a user record as a User resource."
  @spec user(map()) :: map()
  def user(%{user: user, active: active, link: link}),
    do: UserMapping.to_resource(user, active, link, user_location(user.id))

  @doc "The URL of the User resource with `id`."
  @spec user_location(integer()) :: String.t()
  def user_location(id), do: url(~p"/scim/v2/Users/#{id}")

  @doc "Renders a workspace record as a Group resource."
  @spec group(map()) :: map()
  def group(%{workspace: workspace, members: members}) do
    %{
      "schemas" => [@group_schema],
      "id" => Integer.to_string(workspace.id),
      "displayName" => workspace.name,
      "meta" => %{
        "resourceType" => "Group",
        "created" => DateTime.to_iso8601(workspace.inserted_at),
        "lastModified" => DateTime.to_iso8601(workspace.updated_at),
        "location" => url(~p"/scim/v2/Groups/#{workspace.id}")
      }
    }
    |> put_members(members)
  end

  defp put_members(group, nil), do: group

  defp put_members(group, members) do
    Map.put(
      group,
      "members",
      Enum.map(members, fn %{user_id: id, email: email} ->
        %{"value" => Integer.to_string(id), "display" => email, "$ref" => user_location(id)}
      end)
    )
  end
end
