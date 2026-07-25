defmodule Kanban.Tasks.Comments do
  @moduledoc """
  Persistence for task comments, extracted from the task form LiveComponent so
  the web layer holds no Ecto queries (see `CODE-REVIEW.md`, "LiveView /
  context boundary").
  """

  alias Kanban.Repo
  alias Kanban.Tasks.TaskComment

  @doc """
  Creates a comment on `task_id`.

  `task_id` is set on the server-held struct and is never cast from client
  params (D111), so a comment cannot be redirected to another task or board —
  `content` is the only client-controlled field the changeset casts.
  """
  def create_comment(task_id, attrs) do
    %TaskComment{task_id: task_id}
    |> TaskComment.changeset(attrs)
    |> Repo.insert()
  end
end
