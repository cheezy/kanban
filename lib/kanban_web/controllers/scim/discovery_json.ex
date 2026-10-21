defmodule KanbanWeb.SCIM.DiscoveryJSON do
  @moduledoc """
  The static discovery documents of Stride's SCIM 2.0 service (W2247):
  PATCH and the `eq` filter are supported; bulk operations, sorting, ETags
  and password changes are not.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: KanbanWeb.Endpoint,
    router: KanbanWeb.Router

  alias Kanban.SCIM.ListParams

  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @group_schema "urn:ietf:params:scim:schemas:core:2.0:Group"

  @doc "The ServiceProviderConfig resource."
  def service_provider_config do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig"],
      "documentationUri" => url(~p"/resources"),
      "patch" => %{"supported" => true},
      "bulk" => %{"supported" => false, "maxOperations" => 0, "maxPayloadSize" => 0},
      "filter" => %{"supported" => true, "maxResults" => ListParams.max_count()},
      "changePassword" => %{"supported" => false},
      "sort" => %{"supported" => false},
      "etag" => %{"supported" => false},
      "authenticationSchemes" => [
        %{
          "type" => "oauthbearertoken",
          "name" => "OAuth Bearer Token",
          "description" =>
            "A SCIM token created by an org-admin in the Stride org console, sent as Authorization: Bearer <token>.",
          "primary" => true
        }
      ],
      "meta" => %{
        "resourceType" => "ServiceProviderConfig",
        "location" => url(~p"/scim/v2/ServiceProviderConfig")
      }
    }
  end

  @doc "The User and Group ResourceType resources."
  def resource_types do
    [
      resource_type("User", "/Users", @user_schema),
      resource_type("Group", "/Groups", @group_schema)
    ]
  end

  defp resource_type(name, endpoint, schema) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"],
      "id" => name,
      "name" => name,
      "endpoint" => endpoint,
      "schema" => schema,
      "meta" => %{
        "resourceType" => "ResourceType",
        "location" => url(~p"/scim/v2/ResourceTypes/#{name}")
      }
    }
  end

  @doc "The User and Group Schema resources, listing the attributes Stride reads."
  def schemas do
    [
      schema(@user_schema, "User", [
        attribute("userName", "string", required: true, uniqueness: "server"),
        complex("name", [
          attribute("formatted", "string"),
          attribute("givenName", "string"),
          attribute("familyName", "string")
        ]),
        attribute("displayName", "string"),
        attribute("externalId", "string"),
        attribute("active", "boolean"),
        complex(
          "emails",
          [
            attribute("value", "string"),
            attribute("type", "string"),
            attribute("primary", "boolean")
          ],
          multi_valued: true,
          mutability: "readOnly"
        )
      ]),
      schema(@group_schema, "Group", [
        attribute("displayName", "string", required: true, mutability: "readOnly"),
        complex(
          "members",
          [attribute("value", "string"), attribute("display", "string", mutability: "readOnly")],
          multi_valued: true
        )
      ])
    ]
  end

  defp schema(id, name, attributes) do
    %{
      "schemas" => ["urn:ietf:params:scim:schemas:core:2.0:Schema"],
      "id" => id,
      "name" => name,
      "attributes" => attributes,
      "meta" => %{"resourceType" => "Schema", "location" => url(~p"/scim/v2/Schemas/#{id}")}
    }
  end

  defp attribute(name, type, opts \\ []) do
    %{
      "name" => name,
      "type" => type,
      "multiValued" => false,
      "required" => Keyword.get(opts, :required, false),
      "caseExact" => false,
      "mutability" => Keyword.get(opts, :mutability, "readWrite"),
      "returned" => "default",
      "uniqueness" => Keyword.get(opts, :uniqueness, "none")
    }
  end

  defp complex(name, sub_attributes, opts \\ []) do
    "complex"
    |> then(&attribute(name, &1, opts))
    |> Map.put("multiValued", Keyword.get(opts, :multi_valued, false))
    |> Map.put("subAttributes", sub_attributes)
  end
end
