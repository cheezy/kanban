defmodule Kanban.Repo.Migrations.AddDisabledReasonToWebhookEndpoints do
  @moduledoc """
  Why an endpoint was switched off (decided 2026-10-21).

  `disabled_reason` is set when Stride switches an endpoint off by itself,
  because its creator lost access to the board, so the Integrations tab can
  say why. It is NULL for an enabled endpoint and for one the owner switched
  off. Nothing is backfilled: an endpoint disabled before this column existed
  shows as switched off by the owner.
  """

  use Ecto.Migration

  def change do
    alter table(:webhook_endpoints) do
      add :disabled_reason, :string
    end
  end
end
