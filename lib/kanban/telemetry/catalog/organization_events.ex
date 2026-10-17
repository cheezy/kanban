defmodule Kanban.Telemetry.Catalog.OrganizationEvents do
  @moduledoc """
  The Organization events in `Kanban.Telemetry.Catalog`.

  They are emitted by `Kanban.Organizations.OrganizationTelemetry` once the
  change has committed. Metadata carries ids and changed field names only,
  never an Organization's name, address or contact details.
  `Kanban.Telemetry.Catalog` appends these entries to its own list; nothing
  else should call this module.
  """

  @events [
    %{
      name: [:kanban, :organization, :created],
      kind: :event,
      domain: :organization,
      measurements: [:count],
      metadata: [:organization_id, :actor_user_id],
      description: "A site admin created an Organization. actor_user_id is the site admin.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    },
    %{
      name: [:kanban, :organization, :updated],
      kind: :event,
      domain: :organization,
      measurements: [:count],
      metadata: [:organization_id, :actor_user_id, :fields],
      description:
        "A site admin changed an Organization's details. fields lists the changed field names, never their values.",
      legacy: false,
      metrics: [counter: :count],
      persist: false
    }
  ]

  @doc """
  Returns the Organization entries, in declaration order.
  """
  @spec events() :: [Kanban.Telemetry.Catalog.entry()]
  def events, do: @events
end
