defmodule Kanban.Repo.Migrations.CreateWebhookEndpointsAndDeliveries do
  @moduledoc """
  Board-scoped outbound webhook endpoints and their delivery log (W2226).

  `encrypted_secret` and `url` hold ciphertext written by
  `Kanban.Integrations.SecretBox`, never the raw signing secret or URL (a
  Slack incoming-webhook URL is itself a credential). `lock_version` makes a
  secret rotation fail rather than overwrite a concurrent one. `kind` is
  `generic` (signed JSON) or `slack` (an incoming-webhook message), and
  `event_types` lists the public event names the endpoint subscribes to.
  Each row of `webhook_deliveries` is one delivery attempt.
  """

  use Ecto.Migration

  def change do
    create table(:webhook_endpoints) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :kind, :string, null: false, default: "generic"
      add :url, :binary, null: false
      add :encrypted_secret, :binary, null: false
      add :event_types, {:array, :string}, null: false, default: []
      add :enabled, :boolean, null: false, default: true
      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create index(:webhook_endpoints, [:board_id])
    create index(:webhook_endpoints, [:created_by_id])

    create table(:webhook_deliveries) do
      add :endpoint_id, references(:webhook_endpoints, on_delete: :delete_all), null: false
      add :event, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempt, :integer, null: false, default: 0
      add :response_status, :integer
      add :error, :text
      add :delivered_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:webhook_deliveries, [:endpoint_id, :inserted_at])
  end
end
