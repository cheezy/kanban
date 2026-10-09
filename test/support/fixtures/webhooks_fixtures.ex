defmodule Kanban.WebhooksFixtures do
  @moduledoc """
  This module defines test helpers for creating `Kanban.Webhooks.Endpoint`
  and `Kanban.Webhooks.Delivery` entities.
  """

  alias Kanban.Repo
  alias Kanban.Webhooks.Delivery
  alias Kanban.Webhooks.Endpoint

  @doc """
  Generate an endpoint on the given board, with a fresh signing secret.

  `board_id` and `created_by_id` are set on the struct (neither is castable),
  and the URL gets only the syntax check, so no DNS lookup happens.
  """
  def webhook_endpoint_fixture(board, attrs \\ %{}) do
    {created_by_id, attrs} = attrs |> Map.new() |> Map.pop(:created_by_id)

    attrs =
      Enum.into(attrs, %{
        url: "https://hooks.example.com/stride/#{System.unique_integer([:positive])}",
        event_types: ["task.created"]
      })

    %Endpoint{board_id: board.id, created_by_id: created_by_id}
    |> Endpoint.changeset(attrs, allow_http: false)
    |> Endpoint.put_new_secret()
    |> Repo.insert!()
    |> Map.put(:secret, nil)
  end

  @doc """
  The DNS table the delivery worker uses in tests (`config/test.exs`):

    * `hooks.example.com` - a public address
    * `hooks.slack.com` - a public address
    * `internal.example.com` - a private address
    * `rebind.example.com` - a public and a loopback address

  Anything else does not resolve.
  """
  def resolve("hooks.example.com"), do: {:ok, [{93, 184, 216, 34}]}
  def resolve("hooks.slack.com"), do: {:ok, [{54, 1, 2, 3}]}
  def resolve("internal.example.com"), do: {:ok, [{10, 0, 0, 1}]}
  def resolve("rebind.example.com"), do: {:ok, [{93, 184, 216, 34}, {127, 0, 0, 1}]}
  def resolve(_host), do: {:error, :nxdomain}

  @doc "Generate a delivery attempt for the given endpoint."
  def delivery_fixture(endpoint, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{event: "task.created", payload: %{"id" => "evt"}, attempt: 1})

    %Delivery{endpoint_id: endpoint.id}
    |> Delivery.changeset(attrs)
    |> Repo.insert!()
  end
end
