defmodule Kanban.Boards.MembershipChanges do
  @moduledoc """
  Board membership writes: adding a user to a board, changing their access
  and removing them.

  Removal and a downgrade to `:read_only` revoke the user's API tokens for
  the board in the same transaction. Once a write commits, the affected user
  gets a `board_access_changed` notification through
  `Kanban.Notifications.Events.board_access_changed/4`.

  Exposed through the `Kanban.Boards` facade via `defdelegate` — call these
  as `Boards.add_user_to_board/4` and so on rather than reaching into this
  module directly.
  """

  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.Events
  alias Kanban.Repo

  @doc """
  Adds a user to a board with the specified access level.

  On success the added user gets a `board_access_changed` notification,
  unless they added themselves.

  ## Examples

      iex> add_user_to_board(board, user, :read_only)
      {:ok, %BoardUser{}}

  """
  def add_user_to_board(%Board{} = board, user, access, current_user)
      when access in [:owner, :read_only, :modify] do
    if Boards.owner?(board, current_user) do
      %BoardUser{}
      |> BoardUser.changeset(%{
        board_id: board.id,
        user_id: user.id,
        access: access
      })
      |> Repo.insert()
      |> notify_membership(board, user, :added, current_user)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Removes a user from a board, revoking their API tokens for it.

  On success the removed user gets a `board_access_changed` notification
  saying how many tokens were revoked, unless they removed themselves.

  ## Examples

      iex> remove_user_from_board(board, user)
      {:ok, %BoardUser{}}

  """
  def remove_user_from_board(%Board{} = board, user, current_user) do
    if Boards.owner?(board, current_user) do
      case Repo.get_by(BoardUser, board_id: board.id, user_id: user.id) do
        nil ->
          {:error, :not_found}

        board_user ->
          # Revoke the removed user's board-scoped API tokens in the same
          # transaction as the membership delete, so a still-valid token cannot
          # outlive the access it depended on (W1430).
          Ecto.Multi.new()
          |> Ecto.Multi.delete(:board_user, board_user)
          |> Ecto.Multi.run(:revoke_tokens, fn _repo, _changes ->
            {:ok, ApiTokens.revoke_user_tokens_for_board(board.id, user.id)}
          end)
          |> run_board_user_multi()
          |> notify_membership(board, user, :removed, current_user)
      end
    else
      {:error, :unauthorized}
    end
  end

  # Runs a BoardUser-mutating multi, returning the board user and how many
  # API tokens its :revoke_tokens step revoked (0 without one).
  defp run_board_user_multi(multi) do
    multi
    |> Repo.transaction()
    |> case do
      {:ok, %{board_user: board_user} = changes} -> {:ok, board_user, tokens_revoked(changes)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp tokens_revoked(%{revoke_tokens: {count, _}}), do: count
  defp tokens_revoked(_changes), do: 0

  # Notifies the affected user once the write has committed, then normalizes
  # the result back to the {:ok, %BoardUser{}} / {:error, reason} shape
  # callers expect. Errors notify nobody.
  defp notify_membership({:ok, %BoardUser{} = board_user}, board, user, change, actor),
    do: notify_membership({:ok, board_user, 0}, board, user, change, actor)

  # Re-saving the same level notifies only if it still revoked tokens.
  defp notify_membership({:ok, board_user, 0}, _board, _user, :unchanged, _actor),
    do: {:ok, board_user}

  defp notify_membership({:ok, board_user, revoked}, board, user, change, actor) do
    Events.board_access_changed(board, user, event_change(change),
      actor: actor,
      access: if(change == :removed, do: nil, else: board_user.access),
      tokens_revoked: revoked,
      membership_id: board_user.id,
      stamp: membership_stamp(board_user, change)
    )

    {:ok, board_user}
  end

  defp notify_membership({:error, _reason} = error, _board, _user, _change, _actor), do: error

  defp event_change(:unchanged), do: :access_changed
  defp event_change(change), do: change

  # A save with no changes leaves updated_at alone, so a re-save that still
  # revoked tokens is stamped with the time of the revocation instead.
  defp membership_stamp(_board_user, :unchanged), do: DateTime.utc_now()
  defp membership_stamp(%BoardUser{updated_at: updated_at}, :access_changed), do: updated_at
  defp membership_stamp(%BoardUser{inserted_at: inserted_at}, _change), do: inserted_at

  @doc """
  Updates a user's access level for a board. A downgrade to `:read_only`
  revokes their API tokens for it.

  When the level actually changes (or the save still revokes tokens), the
  user gets a `board_access_changed` notification naming the new level (and, for a downgrade to `:read_only`,
  how many tokens were revoked), unless they changed it themselves.

  ## Examples

      iex> update_user_access(board, user, :modify)
      {:ok, %BoardUser{}}

  """
  def update_user_access(%Board{} = board, user, new_access, current_user)
      when new_access in [:owner, :read_only, :modify] do
    if Boards.owner?(board, current_user) do
      case Repo.get_by(BoardUser, board_id: board.id, user_id: user.id) do
        nil ->
          {:error, :not_found}

        board_user ->
          board_user
          |> change_access(board.id, user.id, new_access)
          |> notify_membership(board, user, access_change(board_user, new_access), current_user)
      end
    else
      {:error, :unauthorized}
    end
  end

  # Downgrading to :read_only revokes the user's board-scoped API tokens in
  # the same transaction, so a token minted while they held :modify can no
  # longer write to the board (W1430). Upgrades/lateral changes leave tokens
  # intact.
  defp change_access(board_user, board_id, user_id, new_access) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:board_user, BoardUser.changeset(board_user, %{access: new_access}))
    |> maybe_revoke_tokens_on_downgrade(board_id, user_id, new_access)
    |> run_board_user_multi()
  end

  defp maybe_revoke_tokens_on_downgrade(multi, board_id, user_id, :read_only) do
    Ecto.Multi.run(multi, :revoke_tokens, fn _repo, _changes ->
      {:ok, ApiTokens.revoke_user_tokens_for_board(board_id, user_id)}
    end)
  end

  defp maybe_revoke_tokens_on_downgrade(multi, _board_id, _user_id, _access), do: multi

  defp access_change(%BoardUser{access: access}, access), do: :unchanged
  defp access_change(_board_user, _new_access), do: :access_changed
end
