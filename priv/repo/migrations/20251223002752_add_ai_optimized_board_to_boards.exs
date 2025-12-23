defmodule Kanban.Repo.Migrations.AddAiOptimizedBoardToBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :ai_optimized_board, :boolean, default: false, null: false
    end
  end
end
