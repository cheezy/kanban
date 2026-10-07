defmodule Kanban.Repo.Migrations.AddAuthorshipToTaskComments do
  @moduledoc """
  Adds authorship, edit tracking and mention tracking to `task_comments`.

  Grandfathering: comments written before this migration never recorded an
  author, so there is no source of truth to backfill from. Existing rows keep a
  NULL `author_user_id` and `author_agent_name` (to be displayed as "Unknown"
  once comment authors are rendered) rather than having an author invented for
  them, and they receive the empty-array default for `mentioned_user_ids`.

  `author_user_id` stays nullable and uses `on_delete: :nilify_all` so deleting
  a user keeps the discussion history and only drops the attribution.
  """
  use Ecto.Migration

  def change do
    alter table(:task_comments) do
      add :author_user_id, references(:users, on_delete: :nilify_all)
      add :author_agent_name, :string, size: 255
      add :edited_at, :utc_datetime
      add :mentioned_user_ids, {:array, :integer}, null: false, default: []
    end

    create index(:task_comments, [:author_user_id])
  end
end
