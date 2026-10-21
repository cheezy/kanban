defmodule Kanban.Tasks.ClaimRelease do
  @moduledoc """
  Returns a user's claimed tasks to the Ready column when they lose the
  ability to work them: a board removal or a downgrade that ends their write
  access (`Kanban.Boards.MembershipChanges`), leaving a workspace or an
  Organization (`Kanban.Workspaces.MembershipCascade`), and deleting their own
  account (`Kanban.Accounts.AccountDeletion`), all decided 2026-10-20.

  A claimed task is one the user holds in progress through a claim that has
  not been completed: `status` `:in_progress`, `claimed_at` set and
  `completed_at` empty, unarchived. Without this it would stay in Doing,
  assigned to nobody once the caller clears the assignee, and neither its
  board's owner nor an agent could unclaim or claim it until the claim
  expired. Each one is moved exactly as `Kanban.Tasks.unclaim_task/3` moves
  it: open, unclaimed and unassigned, at the end of its board's Ready column.
  A task on a board with no Ready column is left where it is, for the caller
  to unassign.

  Run it inside the caller's transaction, before the caller clears the user's
  remaining assignments. It sends nothing itself: every caller broadcasts
  `{Kanban.Boards, :members_changed, board_id}` after commit, which makes open
  board pages reload their tasks. No `task_unclaimed` event or webhook is
  emitted, because the user did not unclaim.
  """

  import Ecto.Query, warn: false

  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Positioning
  alias Kanban.Tasks.Task

  @doc """
  Releases `user_id`'s claimed tasks on the boards named by `boards`: a list
  of board ids, a query selecting board ids, or `:all` for every board.

  Returns the released tasks, in id order.

  ## Examples

      iex> release(user.id, [board.id])
      [%Task{status: :open, assigned_to_id: nil}]

  """
  @spec release(integer(), [integer()] | Ecto.Query.t() | :all) :: [Task.t()]
  def release(_user_id, []), do: []

  def release(user_id, boards) when is_integer(user_id) do
    user_id
    |> claimed_query()
    |> on_boards(boards)
    |> Repo.all()
    |> Enum.flat_map(&release_task/1)
  end

  defp claimed_query(user_id) do
    from(t in Task,
      join: c in assoc(t, :column),
      as: :column,
      where: t.assigned_to_id == ^user_id and t.status == :in_progress,
      where: not is_nil(t.claimed_at) and is_nil(t.completed_at) and is_nil(t.archived_at),
      order_by: t.id,
      select: {t, c.board_id}
    )
  end

  defp on_boards(query, :all), do: query

  defp on_boards(query, board_ids) when is_list(board_ids),
    do: where(query, [column: c], c.board_id in ^board_ids)

  defp on_boards(query, %Ecto.Query{} = board_ids),
    do: where(query, [column: c], c.board_id in subquery(board_ids))

  defp release_task({task, board_id}) do
    case ready_column(board_id) do
      nil -> []
      ready -> [move_to_ready(task, ready)]
    end
  end

  defp ready_column(board_id) do
    from(c in Column, where: c.board_id == ^board_id and c.name == "Ready", limit: 1)
    |> Repo.one()
  end

  defp move_to_ready(task, ready) do
    task
    |> Ecto.Changeset.change(%{
      status: :open,
      claimed_at: nil,
      claim_expires_at: nil,
      assigned_to_id: nil,
      column_id: ready.id,
      position: Positioning.get_next_position_locked(ready)
    })
    |> Repo.update!()
  end
end
