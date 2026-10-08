defmodule Kanban.Tasks.BoardLookup do
  @moduledoc """
  Lean, board-scoped task lookups for API actions that only need to know the
  task exists on the caller's board, such as listing or adding comments.

  Each lookup is one query that returns the task with only its `:column`
  preloaded, or `nil` when the task does not exist or is on another board, so
  a cross-board id and a missing one are indistinguishable. Use
  `Kanban.Tasks.get_task_for_view/1` instead when the full task (history,
  comments, assignees) is rendered.

  Exposed through the `Kanban.Tasks` facade via `defdelegate`.
  """

  import Ecto.Query, warn: false

  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  The task with numeric `id` on board `board_id`, with its column preloaded,
  or `nil`.
  """
  @spec get_task_with_column(integer(), integer()) :: Task.t() | nil
  def get_task_with_column(id, board_id) when is_integer(id) and is_integer(board_id) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], t.id == ^id and c.board_id == ^board_id)
    |> preload([_t, c], column: c)
    |> Repo.one()
  end

  @doc """
  The task with `identifier` (for example `"W14"`) on board `board_id`, with
  its column preloaded, or `nil`.

  The caller must reject text PostgreSQL cannot hold as a parameter (invalid
  UTF-8 or a NUL character) before calling.
  """
  @spec get_task_by_identifier_with_column(String.t(), integer()) :: Task.t() | nil
  def get_task_by_identifier_with_column(identifier, board_id)
      when is_binary(identifier) and is_integer(board_id) do
    Task
    |> join(:inner, [t], c in assoc(t, :column))
    |> where([t, c], t.identifier == ^identifier and c.board_id == ^board_id)
    |> limit(1)
    |> preload([_t, c], column: c)
    |> Repo.one()
  end
end
