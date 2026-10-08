defmodule Kanban.Repo.Migrations.CreateLabelsAndTaskLabels do
  use Ecto.Migration

  def change do
    create table(:labels) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :name, :string, size: 40, null: false
      add :color, :string, null: false

      timestamps()
    end

    # Case-insensitive uniqueness per board. board_id leads the index, so it
    # also serves board-scoped lookups and no separate board_id index is needed.
    create unique_index(:labels, [:board_id, "lower(name)"],
             name: :labels_board_id_lower_name_index
           )

    create table(:task_labels) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :label_id, references(:labels, on_delete: :delete_all), null: false

      timestamps()
    end

    create unique_index(:task_labels, [:task_id, :label_id])
    create index(:task_labels, [:label_id])
  end
end
