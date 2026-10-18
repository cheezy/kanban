defmodule Kanban.Boards.MembershipChanges do
  @moduledoc """
  Board membership writes: adding a user to a board, changing their access
  and removing them.

  Adding a member is capped on free boards while plans are enforced: the add
  locks the board row, counts its members and asks
  `Kanban.Plans.member_cap_reached?/2`, and `member_cap_status/1` returns the
  same count and cap for the members screen. Removals and access changes are
  never capped.

  Removal and a downgrade to `:read_only` revoke the user's API tokens for
  the board in the same transaction, and removal also unassigns the user from
  the board's open tasks. Once a write commits, the affected user
  gets a `board_access_changed` notification through
  `Kanban.Notifications.Events.board_access_changed/4`, and
  `{Kanban.Boards, :members_changed, board_id}` is broadcast on the board's
  `"board:<id>"` topic so open boards refresh their assignee filter. The
  committed change is also reported as telemetry through
  `Kanban.Boards.BoardTelemetry.membership_changed/4`, including changes a
  user makes to their own membership.

  Exposed through the `Kanban.Boards` facade via `defdelegate` — call these
  as `Boards.add_user_to_board/4` and so on rather than reaching into this
  module directly.
  """

  import Ecto.Query, only: [from: 2]

  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardTelemetry
  alias Kanban.Boards.BoardUser
  alias Kanban.Notifications.Events
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Adds a user to a board with the specified access level.

  On success the added user gets a `board_access_changed` notification,
  unless they added themselves.

  The insert runs in a transaction that first locks the board row and counts
  its `board_users` rows, so two adds at once cannot both pass the free-board
  member cap. When `Kanban.Plans.member_cap_reached?/2` says the board is full
  it returns `{:error, :member_cap_reached}`, inserts nothing and emits
  `[:kanban, :board, :member_cap_reached]` with `via: :direct_add`. Adding a
  user who is already a member is never refused by the cap; it fails on the
  membership's uniqueness as before. A caller who does not own the board gets
  `{:error, :unauthorized}` before anything is counted, and a board deleted
  after it was loaded gives `{:error, :not_found}`.

  ## Examples

      iex> add_user_to_board(board, user, :read_only, owner)
      {:ok, %BoardUser{}}

      iex> add_user_to_board(full_free_board, user, :read_only, owner)
      {:error, :member_cap_reached}

  """
  def add_user_to_board(%Board{} = board, user, access, current_user)
      when access in [:owner, :read_only, :modify] do
    if Boards.owner?(board, current_user) do
      board
      |> insert_member_multi(user, access)
      |> run_board_user_multi()
      |> BoardTelemetry.member_cap_reached(board, :direct_add, current_user)
      |> notify_membership(board, user, :added, current_user)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Returns the board's member count, its member cap and whether the cap is
  reached, for the members screen.

  `count` is the number of `board_users` rows, the owner's included. `cap` is
  `Kanban.Plans.free_board_member_cap/0` when the board is capped, that is when
  plans are enforced and the board is free, and `nil` otherwise. `reached?` is
  true when a capped board's count is `cap` or more, the answer
  `Kanban.Plans.member_cap_reached?/2` gives for that count, decided with one
  paid-status query; it is always false for an uncapped board. A grandfathered
  board may report a count above `cap`.

  ## Examples

      iex> member_cap_status(free_board)
      %{count: 2, cap: 3, reached?: false}

      iex> member_cap_status(org_board)
      %{count: 7, cap: nil, reached?: false}

  """
  @spec member_cap_status(Board.t()) :: %{
          count: non_neg_integer(),
          cap: pos_integer() | nil,
          reached?: boolean()
        }
  def member_cap_status(%Board{id: board_id}) do
    count =
      from(bu in BoardUser, where: bu.board_id == ^board_id)
      |> Repo.aggregate(:count)

    if Plans.board_unlocked?(board_id) do
      %{count: count, cap: nil, reached?: false}
    else
      cap = Plans.free_board_member_cap()
      %{count: count, cap: cap, reached?: count >= cap}
    end
  end

  # Inserts the membership only after check_member_cap/3 passes, in one
  # transaction.
  defp insert_member_multi(board, user, access) do
    changeset =
      BoardUser.changeset(%BoardUser{}, %{board_id: board.id, user_id: user.id, access: access})

    Ecto.Multi.new()
    |> Ecto.Multi.run(:member_cap, fn repo, _changes ->
      check_member_cap(repo, board.id, user.id)
    end)
    |> Ecto.Multi.insert(:board_user, changeset)
  end

  # Locks the board row, then counts its members and decides the cap from the
  # database, by board id, so neither a concurrent add nor a workspace loaded
  # before the transaction can slip a member past it. A user who already holds
  # a row is passed through so the insert reports the duplicate.
  defp check_member_cap(repo, board_id, user_id) do
    with {:ok, _id} <- lock_board(repo, board_id) do
      {count, already_member} =
        from(bu in BoardUser,
          where: bu.board_id == ^board_id,
          select: {count(bu.id), filter(count(bu.id), bu.user_id == ^user_id)}
        )
        |> repo.one()

      if already_member == 0 and Plans.member_cap_reached?(board_id, count),
        do: {:error, :member_cap_reached},
        else: {:ok, count}
    end
  end

  defp lock_board(repo, board_id) do
    from(b in Board, where: b.id == ^board_id, select: b.id, lock: "FOR UPDATE")
    |> repo.one()
    |> case do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  @doc """
  Removes a user from a board, revoking their API tokens for it and
  unassigning them from the board's open tasks, in one transaction.

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
          |> Ecto.Multi.update_all(:unassign, open_assignments(board.id, user.id),
            set: [assigned_to_id: nil, updated_at: NaiveDateTime.utc_now(:second)]
          )
          |> run_board_user_multi()
          |> notify_membership(board, user, :removed, current_user)
      end
    else
      {:error, :unauthorized}
    end
  end

  # The removed user's assignments on this board's open (unarchived) tasks.
  # They can no longer see the board, so leaving them assigned would hide the
  # work from everyone else's view of who owns it. Archived tasks keep their
  # assignee as a record.
  defp open_assignments(board_id, user_id) do
    from(t in Task,
      join: c in assoc(t, :column),
      where: c.board_id == ^board_id and t.assigned_to_id == ^user_id and is_nil(t.archived_at)
    )
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
    BoardTelemetry.membership_changed(board_user, change, revoked, actor)

    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board.id}",
      {Kanban.Boards, :members_changed, board.id}
    )

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
  defp event_change({:access_changed, _from}), do: :access_changed
  defp event_change(change), do: change

  # A save with no changes leaves updated_at alone, so a re-save that still
  # revoked tokens is stamped with the time of the revocation instead.
  defp membership_stamp(_board_user, :unchanged), do: DateTime.utc_now()

  defp membership_stamp(%BoardUser{updated_at: updated_at}, {:access_changed, _from}),
    do: updated_at

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
  defp access_change(%BoardUser{access: from}, _new_access), do: {:access_changed, from}
end
