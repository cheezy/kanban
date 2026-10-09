defmodule Kanban.Webhooks.Delivery do
  @moduledoc """
  One delivery attempt to a webhook endpoint (W2226): the event, the payload
  that was sent, and how it went. Deleting the endpoint deletes its log.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Kanban.Webhooks.Endpoint

  schema "webhook_deliveries" do
    field :event, :string
    field :payload, :map, default: %{}
    field :status, Ecto.Enum, values: [:pending, :succeeded, :failed], default: :pending
    field :attempt, :integer, default: 0
    field :response_status, :integer
    field :error, :string
    field :delivered_at, :utc_datetime

    belongs_to :endpoint, Endpoint

    timestamps(type: :utc_datetime)
  end

  @doc """
  Casts a delivery record. The endpoint is set on the struct, never cast;
  an endpoint deleted meanwhile is an error on `:endpoint_id`. `event` is
  one of `Endpoint.event_types/0` or `"ping"` (a test event).
  """
  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:event, :payload, :status, :attempt, :response_status, :error, :delivered_at])
    |> validate_required([:event, :payload, :status, :attempt])
    |> validate_inclusion(:event, ["ping" | Endpoint.event_types()])
    |> validate_number(:attempt, greater_than_or_equal_to: 0)
    |> validate_number(:response_status,
      greater_than_or_equal_to: 100,
      less_than_or_equal_to: 599
    )
    |> foreign_key_constraint(:endpoint_id)
  end
end
