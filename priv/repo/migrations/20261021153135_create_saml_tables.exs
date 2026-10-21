defmodule Kanban.Repo.Migrations.CreateSamlTables do
  use Ecto.Migration

  # SAML 2.0 single sign-on per Organization (W2246).
  #
  # sso_connections.client_id: a SAML connection has no client id, so the
  # column becomes nullable; the OIDC changeset still requires it.
  #
  # saml_requests: one row per SP-initiated sign-in. The RelayState the
  # identity provider echoes back is the random relay_token, looked up here
  # (never in the session cookie, which a SameSite=Lax browser does not send
  # on the identity provider's cross-site POST); request_id is the
  # AuthnRequest ID the assertion's InResponseTo must name; return_to is a
  # local path. Rows expire after a few minutes and are removed by
  # Kanban.Retention.PurgeWorker.
  #
  # saml_assertion_ids: the replay cache. An assertion ID is accepted once per
  # connection (the unique index decides a race); rows are kept until the
  # assertion itself has expired, then removed by Kanban.Retention.PurgeWorker.
  def change do
    alter table(:sso_connections) do
      modify :client_id, :string, size: 1024, null: true, from: {:string, size: 1024, null: false}
    end

    create table(:saml_requests) do
      add :sso_connection_id, references(:sso_connections, on_delete: :delete_all), null: false
      add :request_id, :string, null: false
      add :relay_token, :string, null: false
      add :return_to, :string, size: 2048
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:saml_requests, [:request_id])
    create unique_index(:saml_requests, [:relay_token])
    create index(:saml_requests, [:sso_connection_id])
    create index(:saml_requests, [:expires_at])

    create table(:saml_assertion_ids) do
      add :sso_connection_id, references(:sso_connections, on_delete: :delete_all), null: false
      add :assertion_id, :string, size: 256, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:saml_assertion_ids, [:sso_connection_id, :assertion_id])
    create index(:saml_assertion_ids, [:expires_at])
  end
end
