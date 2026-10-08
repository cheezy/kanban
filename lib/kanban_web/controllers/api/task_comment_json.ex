defmodule KanbanWeb.API.TaskCommentJSON do
  @moduledoc """
  JSON rendering for task comments, shared by `GET` and
  `POST /api/tasks/:id/comments` and the MCP `stride_add_comment` tool, so a
  comment has one shape on every path.
  """

  alias Kanban.Accounts.User
  alias Kanban.Tasks.TaskComment

  @unknown_author "Unknown"

  @doc """
  A page of comments, oldest first, with its `meta` (`limit` and `has_more`).
  """
  def index(%{comments: comments, meta: meta}) do
    %{data: Enum.map(comments, &comment/1), meta: meta}
  end

  @doc """
  One comment.
  """
  def show(%{comment: comment}), do: %{data: comment(comment)}

  @doc """
  The rendered fields of one comment. `author_name` is the author's name, else
  their email, else `"Unknown"` for a comment with no author (legacy rows).
  """
  def comment(%TaskComment{} = comment) do
    %{
      id: comment.id,
      task_id: comment.task_id,
      content: comment.content,
      author_name: author_name(comment.author),
      author_agent_name: comment.author_agent_name,
      mentioned_user_ids: comment.mentioned_user_ids || [],
      edited_at: comment.edited_at,
      inserted_at: comment.inserted_at,
      updated_at: comment.updated_at
    }
  end

  defp author_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp author_name(%User{email: email}) when is_binary(email) and email != "", do: email
  defp author_name(_author), do: @unknown_author
end
