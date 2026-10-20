defmodule Kanban.Workspaces.PersonalCleanup do
  @moduledoc """
  Emptying a user's personal workspace before their account is deleted
  (W2221), so `Kanban.Workspaces.delete_personal_workspace/1` can remove it.

  Each board in the workspace is either deleted or re-homed into another
  user's personal workspace, using the placement rule of the W2217 backfill
  (`priv/repo/migrations/20261018134655_backfill_personal_workspaces.exs`):

    1. another user's `board_users` owner row: the board goes to its owner;
    2. otherwise the earliest other member, by `board_users.inserted_at` then
       id;
    3. a board with no `board_users` rows at all goes to the earliest enabled
       site admin other than the user, by `users.inserted_at` then id.

  A board nobody else uses — only the user's own row, or no rows and no other
  enabled site admin — is deleted, with its columns and tasks (they cascade).

  The caller must already have refused the deletion while the user owns a
  board other people use, which is why rule 1 only ever finds another user's
  owner row.

  Run it inside the transaction that deletes the user. The workspace's boards
  are locked `FOR UPDATE` in id order, so a concurrent membership change or
  move waits for that transaction.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace

  @type result :: %{deleted: [Board.t()], rehomed: [{integer(), integer()}]}

  @doc """
  Deletes or re-homes every board in `user`'s personal workspace. Returns
  `{:ok, %{deleted: boards, rehomed: [{board_id, new_home_user_id}]}}`, or
  `{:error, reason}` from the first write that failed; roll back on an error.
  A user with no personal workspace gets empty lists.
  """
  @spec clear_personal_boards(User.t()) :: {:ok, result()} | {:error, term()}
  def clear_personal_boards(%User{} = user) do
    case Workspaces.get_personal_workspace(user) do
      nil -> {:ok, %{deleted: [], rehomed: []}}
      %Workspace{} = workspace -> workspace |> lock_boards() |> clear_boards(user)
    end
  end

  defp lock_boards(%Workspace{id: workspace_id}) do
    from(b in Board, where: b.workspace_id == ^workspace_id, order_by: b.id, lock: "FOR UPDATE")
    |> Repo.all()
  end

  defp clear_boards(boards, user) do
    Enum.reduce_while(boards, {:ok, %{deleted: [], rehomed: []}}, fn board, {:ok, acc} ->
      board |> clear_board(user) |> accumulate(acc)
    end)
  end

  defp accumulate({:deleted, board}, acc),
    do: {:cont, {:ok, %{acc | deleted: [board | acc.deleted]}}}

  defp accumulate({:rehomed, pair}, acc),
    do: {:cont, {:ok, %{acc | rehomed: [pair | acc.rehomed]}}}

  defp accumulate({:error, _reason} = error, _acc), do: {:halt, error}

  defp clear_board(board, user) do
    case new_home(board, user) do
      nil -> delete_board(board)
      %User{} = target -> rehome_board(board, target)
    end
  end

  defp new_home(%Board{id: board_id}, %User{id: user_id} = user) do
    rows =
      from(bu in BoardUser,
        where: bu.board_id == ^board_id,
        order_by: [asc: bu.inserted_at, asc: bu.id],
        preload: :user
      )
      |> Repo.all()

    others = Enum.reject(rows, &(&1.user_id == user_id))

    cond do
      owner = Enum.find(others, &(&1.access == :owner)) -> owner.user
      others != [] -> hd(others).user
      rows == [] -> earliest_other_admin(user)
      true -> nil
    end
  end

  defp earliest_other_admin(%User{id: user_id}) do
    from(u in User,
      where: u.type == ^:admin and is_nil(u.disabled_at) and u.id != ^user_id,
      order_by: [asc: u.inserted_at, asc: u.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp delete_board(board) do
    case Repo.delete(board) do
      {:ok, deleted} -> {:deleted, deleted}
      {:error, _changeset} = error -> error
    end
  end

  defp rehome_board(board, target) do
    with {:ok, %Workspace{id: workspace_id}} <- Workspaces.ensure_personal_workspace(target),
         {:ok, _board} <-
           board |> Ecto.Changeset.change(workspace_id: workspace_id) |> Repo.update() do
      {:rehomed, {board.id, target.id}}
    end
  end
end
