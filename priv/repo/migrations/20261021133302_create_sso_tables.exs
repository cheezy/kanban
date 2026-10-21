defmodule Kanban.Repo.Migrations.CreateSsoTables do
  use Ecto.Migration

  # Single sign-on per Organization (W2245).
  #
  # organization_domains: email domains an Organization claims, proven through
  # a DNS TXT record. Several Organizations may claim the same domain, but only
  # one may verify it: the partial unique index admits one verified row per
  # domain, so the first verification wins and every later one is refused.
  #
  # sso_connections: one identity provider per Organization and protocol. The
  # client secret is stored encrypted (Kanban.Encryption.EncryptedBinary).
  #
  # user_identities: the identity provider's subject for a user. Later logins
  # match on (connection, issuer, subject), never on email.
  def change do
    create table(:organization_domains) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :domain, :string, null: false
      add :verification_token, :string, null: false
      add :verified_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_domains, [:organization_id, :domain])

    create unique_index(:organization_domains, [:domain],
             where: "verified_at IS NOT NULL",
             name: :organization_domains_verified_domain_index
           )

    create constraint(:organization_domains, :domain_lowercase, check: "domain = lower(domain)")

    create table(:sso_connections) do
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :protocol, :string, null: false
      add :issuer, :string, size: 2048, null: false
      add :client_id, :string, size: 1024, null: false
      add :client_secret, :binary
      add :settings, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: false
      add :updated_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:sso_connections, [:organization_id, :protocol])
    create index(:sso_connections, [:updated_by_id])

    create table(:user_identities) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :sso_connection_id, references(:sso_connections, on_delete: :delete_all), null: false
      add :issuer, :string, size: 2048, null: false
      add :subject, :string, size: 1024, null: false
      add :last_login_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_identities, [:sso_connection_id, :issuer, :subject])
    create index(:user_identities, [:user_id])
  end
end
