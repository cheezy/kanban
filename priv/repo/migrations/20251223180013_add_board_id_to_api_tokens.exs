defmodule Kanban.Repo.Migrations.AddBoardIdToApiTokens do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
    end

    create index(:api_tokens, [:board_id])
  end
end
