defmodule Kanban.Repo.Migrations.AddReviewRequestedAtToTasks do
  use Ecto.Migration

  # When a task last entered the Review column; the review queue, its cards,
  # the review detail header and the weekly digest all age a pending task from
  # it (D348).
  def up do
    alter table(:tasks) do
      add :review_requested_at, :utc_datetime
    end

    flush()

    # Tasks already in a Review column keep the age the queue has been showing:
    # until now it sorted and aged them by updated_at.
    execute("""
    UPDATE tasks AS t
    SET review_requested_at = date_trunc('second', t.updated_at)
    FROM columns AS c
    WHERE c.id = t.column_id AND c.name = 'Review'
    """)
  end

  def down do
    alter table(:tasks) do
      remove :review_requested_at
    end
  end
end
