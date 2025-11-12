defmodule Kanban.Repo.Migrations.CreateBoardUsers do
  use Ecto.Migration

  def change do
    create table(:board_users) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :access, :string, null: false

      timestamps()
    end

    create index(:board_users, [:board_id])
    create index(:board_users, [:user_id])
    create unique_index(:board_users, [:board_id, :user_id])

    # Create a unique partial index to ensure only one owner per board
    create unique_index(:board_users, [:board_id], where: "access = 'owner'", name: :board_users_one_owner_per_board)
  end
end
