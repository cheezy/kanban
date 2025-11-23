defmodule Kanban.Repo.Migrations.AddTypeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :type, :string, null: false, default: "user"
    end

    create constraint(:users, :type_must_be_valid, check: "type IN ('user', 'admin')")
  end
end
