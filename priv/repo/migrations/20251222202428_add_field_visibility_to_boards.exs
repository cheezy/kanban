defmodule Kanban.Repo.Migrations.AddFieldVisibilityToBoards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :field_visibility, :map,
        null: false,
        default: %{
          "acceptance_criteria" => true,
          "complexity" => false,
          "context" => false,
          "key_files" => false,
          "verification_steps" => false,
          "technical_notes" => false,
          "observability" => false,
          "error_handling" => false,
          "technology_requirements" => false,
          "pitfalls" => false,
          "out_of_scope" => false
        }
    end
  end
end
