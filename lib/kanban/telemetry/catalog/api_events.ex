defmodule Kanban.Telemetry.Catalog.ApiEvents do
  @moduledoc """
  The API token and request events in `Kanban.Telemetry.Catalog`.

  These are legacy events: their names predate the catalog and are never
  renamed. The token events count API tokens being created, revoked, deleted
  and used; `request` and `error` time and count finished API requests;
  `auth_failed` counts a refused bearer token or board selection; and
  `after_goal_delivered` counts an after_goal hook included in a `/complete`
  or `/mark_reviewed` response.

  The runtime-named `[:kanban, :api, action]` entries are generated in
  `Kanban.Telemetry.Catalog.Families`. Metadata carries ids, the endpoint, the
  method, the status and a fixed reason only, never a token value.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :api, :token_created],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :board_id, :workspace_id, :token_id],
      description: "An API token was created.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :token_revoked],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :token_id],
      description: "An API token was revoked.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :token_deleted],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :token_id],
      description: "An API token was deleted.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :token_used],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:user_id, :token_id],
      description: "An API token authenticated a request.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :request],
      kind: :event,
      domain: :api,
      measurements: [:count, :duration],
      metadata: [:endpoint, :method, :status],
      description: "An API request finished. Duration is in native time units.",
      legacy: true,
      metrics: [counter: :count, summary: :duration],
      persist: true,
      tags: [:endpoint, :method]
    },
    %{
      name: [:kanban, :api, :error],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:endpoint, :status, :method],
      description: "An API request finished with a status of 400 or above.",
      legacy: true,
      metrics: [counter: :count],
      persist: true,
      tags: [:endpoint, :status]
    },
    %{
      name: [:kanban, :api, :auth_failed],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:reason, :path, :method],
      description: "An API request failed bearer-token authentication or board selection.",
      legacy: true,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :api, :after_goal_delivered],
      kind: :event,
      domain: :api,
      measurements: [:count],
      metadata: [:goal_id, :board_id, :project_id],
      description: "An after_goal hook was included in a /complete or /mark_reviewed response.",
      legacy: true,
      metrics: [counter: :count],
      persist: true
    }
  ]

  @doc """
  Returns the API token and request entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
