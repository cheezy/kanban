defmodule Kanban.Repo.Migrations.CreateUserIdentities do
  use Ecto.Migration

  def change do
    create table(:user_identities) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :issuer, :string, null: false
      add :subject, :string, null: false
      add :email, :citext, null: false
      add :claims, :map, null: false, default: %{}
      add :last_login_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:user_identities, [:user_id])
    create unique_index(:user_identities, [:issuer, :subject])
  end
end
