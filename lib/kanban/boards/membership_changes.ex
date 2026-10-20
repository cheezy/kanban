defmodule Kanban.Boards.MembershipChanges do
  @moduledoc """
  Board membership writes: adding a user to a board, changing their access
  and removing them.

  Adding a member is capped on free boards while plans are enforced: the add
  locks the board row, counts its members and asks
  `Kanban.Plans.member_cap_reached?/2`, and `member_cap_status/1` returns the
  same count and cap for the members screen. Removals and access changes are
  never capped. A disabled account is never added, since it cannot sign in
  and would only take a seat, and a board in an Organization workspace takes
  only members of that Organization (`Kanban.Boards.OrgBoardMembers`).

  The owner's own row can be neither removed nor demoted: either would leave
  the board with no owner, invisible to everyone and stranded in the old
  owner's personal workspace. Both return `{:error, :owner_required}`.

  Removal revokes the user's API tokens for the board and unassigns them from
  its open tasks in the same transaction. A downgrade to `:read_only` does
  both too, unless the user keeps write access as an org-admin of the
  board's Organization. Once a write commits, the affected user
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

  alias Kanban.Accounts.User
  alias Kanban.ApiTokens
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardTelemetry
  alias Kanban.Boards.BoardUser
  alias Kanban.Boards.OrgBoardMembers
  alias Kanban.Notifications.Events
  alias Kanban.Plans
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Telemetry.AfterCommit
  alias Kanban.Workspaces.Policy

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
  after it was loaded gives `{:error, :not_found}`. A disabled account, read
  from the database, gives `{:error, :user_disabled}` and nothing is
  written: it cannot sign in, and on a free board it would take a seat.
  On a board in an Organization workspace, a user who is not a member of that
  Organization gives `{:error, :not_org_member}` and nothing is written
  (`Kanban.Boards.OrgBoardMembers`): outsiders join through a workspace
  invitation, which adds the Organization membership and its audit row.

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
  Adds `user` to the board for an accepted invitation (W2219). Not gated on
  the caller: the invitation was authorized when it was sent, and
  `Kanban.Workspaces.Invitations` has already checked it. `access` is
  `:read_only` or `:modify`, never `:owner`.

  It goes through the same insert path as `add_user_to_board/4` — the
  disabled-account check, the board lock and the free-board member cap — so a
  full free board returns `{:error, :member_cap_reached}` and emits
  `[:kanban, :board, :member_cap_reached]` once, with `via: :invitation` and
  `actor` (the inviter) as `actor_user_id`.

  Meant to run inside the caller's transaction. The member-added telemetry,
  the `members_changed` broadcast and the user's `board_access_changed`
  notification are passed to `Kanban.Telemetry.AfterCommit.defer/2`, so when
  the caller wraps its transaction in `AfterCommit.after_commit/1` they wait
  for that commit and a rolled-back acceptance reports nothing.
  """
  @spec add_invited_user(Board.t(), User.t(), :read_only | :modify, User.t()) ::
          {:ok, BoardUser.t()} | {:error, term()}
  def add_invited_user(%Board{} = board, %User{} = user, access, %User{} = actor)
      when access in [:read_only, :modify] do
    board
    |> insert_member_multi(user, access)
    |> run_board_user_multi()
    |> BoardTelemetry.member_cap_reached(board, :invitation, actor)
    |> defer_added_notice(board, user, actor)
  end

  defp defer_added_notice({:ok, board_user, revoked}, board, user, actor) do
    AfterCommit.defer(fn ->
      notify_membership({:ok, board_user, revoked}, board, user, :added, actor)
    end)

    {:ok, board_user}
  end

  defp defer_added_notice({:error, _reason} = error, _board, _user, _actor), do: error

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

  # Inserts the membership only after the Organization check and
  # check_member_cap/3 pass, in one transaction. OrgBoardMembers takes the
  # Organization lock and then the board lock, so check_member_cap/3 re-locks a
  # board row it already holds.
  defp insert_member_multi(board, user, access) do
    changeset =
      BoardUser.changeset(%BoardUser{}, %{board_id: board.id, user_id: user.id, access: access})

    Ecto.Multi.new()
    |> Ecto.Multi.run(:enabled, fn repo, _changes -> check_enabled(repo, user.id) end)
    |> Ecto.Multi.run(:organization, fn repo, _changes ->
      OrgBoardMembers.lock_and_check(repo, board.id, user.id)
    end)
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

  # Read from the database, so a struct loaded before the account was disabled
  # is refused too. A user whose row is gone is left to the insert's foreign key.
  defp check_enabled(repo, user_id) do
    disabled_query = from(u in User, where: u.id == ^user_id, select: not is_nil(u.disabled_at))

    case repo.one(disabled_query) do
      true -> {:error, :user_disabled}
      _enabled_or_gone -> {:ok, user_id}
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
  unassigning them from the board's open tasks, in one transaction. An
  org-admin of the board's Organization keeps owner access through their role
  after losing the row, so their removal does neither, exactly as their
  downgrade to `:read_only` does not.

  On success the removed user gets a `board_access_changed` notification
  saying how many tokens were revoked, unless they removed themselves.

  The owner's row is never removed: it returns `{:error, :owner_required}`
  and changes nothing.

  ## Examples

      iex> remove_user_from_board(board, user)
      {:ok, %BoardUser{}}

      iex> remove_user_from_board(board, owner, owner)
      {:error, :owner_required}

  """
  def remove_user_from_board(%Board{} = board, user, current_user) do
    if Boards.owner?(board, current_user) do
      with {:ok, board_user} <- fetch_changeable_member(board, user, :removed) do
        board_user
        |> removal_multi(board.id, user.id)
        |> run_board_user_multi()
        |> notify_membership(board, user, :removed, current_user)
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Reports a membership row that another context already deleted in its own
  committed transaction, exactly as `remove_user_from_board/3` reports one:
  telemetry and the token revocation report, the
  `{Kanban.Boards, :members_changed, board_id}` broadcast on `"board:<id>"`,
  and the removed user's `board_access_changed` notification.

  Call it only after that transaction has committed. `revoked` is the number of
  the user's API tokens for the board it revoked. Returns `:ok`.
  """
  @spec notify_removed(Board.t(), User.t(), BoardUser.t(), non_neg_integer(), User.t()) :: :ok
  def notify_removed(%Board{} = board, %User{} = user, %BoardUser{} = board_user, revoked, actor) do
    {:ok, _board_user} =
      notify_membership({:ok, board_user, revoked}, board, user, :removed, actor)

    :ok
  end

  # The member's row, unless the change would take the owner's row away: only
  # re-saving it as :owner is let through.
  defp fetch_changeable_member(board, user, new_access) do
    case Repo.get_by(BoardUser, board_id: board.id, user_id: user.id) do
      nil -> {:error, :not_found}
      %BoardUser{access: :owner} when new_access != :owner -> {:error, :owner_required}
      board_user -> {:ok, board_user}
    end
  end

  # Revoke the removed user's board-scoped API tokens in the same transaction
  # as the membership delete, so a still-valid token cannot outlive the access
  # it depended on (W1430) — unless they keep write access without the row.
  defp removal_multi(board_user, board_id, user_id) do
    Ecto.Multi.new()
    |> Ecto.Multi.delete(:board_user, board_user)
    |> end_write_access_if_lost(board_id, user_id)
  end

  # The user's assignments on this board's open (unarchived) tasks, cleared on
  # removal and on a downgrade that ends their write access. Leaving them
  # assigned would hide the work from everyone else's view of who owns it.
  # Archived tasks keep their assignee as a record.
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
  Updates a user's access level for a board. A downgrade to `:read_only` that
  leaves them without write access revokes their API tokens for it and
  unassigns them from its open tasks. An org-admin of the board's
  Organization keeps owner access through their role, so their downgrade
  does neither.

  When the level actually changes (or the save still revokes tokens), the
  user gets a `board_access_changed` notification naming the new level (and, for a downgrade to `:read_only`,
  how many tokens were revoked), unless they changed it themselves.

  The owner's row is never demoted: any level but `:owner` returns
  `{:error, :owner_required}` and changes nothing. Re-saving it as `:owner`
  changes nothing either.

  ## Examples

      iex> update_user_access(board, user, :modify)
      {:ok, %BoardUser{}}

      iex> update_user_access(board, owner, :modify, owner)
      {:error, :owner_required}

  """
  def update_user_access(%Board{} = board, user, new_access, current_user)
      when new_access in [:owner, :read_only, :modify] do
    if Boards.owner?(board, current_user) do
      with {:ok, board_user} <- fetch_changeable_member(board, user, new_access) do
        apply_access_change(board_user, board, user, new_access, current_user)
      end
    else
      {:error, :unauthorized}
    end
  end

  defp apply_access_change(board_user, board, user, new_access, current_user) do
    board_user
    |> change_access(board.id, user.id, new_access)
    |> notify_membership(board, user, access_change(board_user, new_access), current_user)
  end

  # Downgrading to :read_only revokes the user's board-scoped API tokens (W1430)
  # and unassigns them from the board's open tasks, which they could no longer
  # complete or unclaim, in the same transaction, as removal does.
  # Upgrades/lateral changes leave both intact.
  defp change_access(board_user, board_id, user_id, new_access) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:board_user, BoardUser.changeset(board_user, %{access: new_access}))
    |> maybe_end_write_access(board_id, user_id, new_access)
    |> run_board_user_multi()
  end

  defp maybe_end_write_access(multi, board_id, user_id, :read_only),
    do: end_write_access_if_lost(multi, board_id, user_id)

  defp maybe_end_write_access(multi, _board_id, _user_id, _access), do: multi

  # Revokes the user's tokens for the board and unassigns their open tasks
  # there, after a removal or downgrade earlier in `multi`, only when that
  # change left them without write access. An org-admin of the board's
  # Organization keeps owner access through their role
  # (Kanban.Workspaces.Policy, read inside the transaction, after the change),
  # so their tokens and tasks stay.
  defp end_write_access_if_lost(multi, board_id, user_id) do
    multi
    |> Ecto.Multi.run(:write_access_ended, fn _repo, _changes ->
      {:ok, Policy.effective_board_access(board_id, user_id) not in [:owner, :modify]}
    end)
    |> Ecto.Multi.run(:revoke_tokens, fn
      _repo, %{write_access_ended: true} ->
        {:ok, ApiTokens.revoke_user_tokens_for_board(board_id, user_id)}

      _repo, _changes ->
        {:ok, {0, nil}}
    end)
    |> Ecto.Multi.run(:unassign, fn
      repo, %{write_access_ended: true} ->
        unassigned =
          board_id
          |> open_assignments(user_id)
          |> repo.update_all(
            set: [assigned_to_id: nil, updated_at: NaiveDateTime.utc_now(:second)]
          )

        {:ok, unassigned}

      _repo, _changes ->
        {:ok, {0, nil}}
    end)
  end

  defp access_change(%BoardUser{access: access}, access), do: :unchanged
  defp access_change(%BoardUser{access: from}, _new_access), do: {:access_changed, from}
end
