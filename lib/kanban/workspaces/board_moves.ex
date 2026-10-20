defmodule Kanban.Workspaces.BoardMoves do
  @moduledoc """
  Moving a personal board into an Organization workspace (D8).

  An org-admin who owns a board in their personal workspace can move it into
  one of their Organization's unarchived workspaces. That lifts the free-board
  member cap and unlocks paid features on the board, because whether a board
  is paid is derived from its workspace's Organization (`Kanban.Plans`).

  The move only changes `boards.workspace_id`:

    * `board_users` rows are kept as they are, so everyone keeps their access.
    * Nobody is added to the Organization.
    * Open board-only invitations for the board are kept, as the design doc
      requires. From then on, accepting one needs its sender to be an
      org-admin of the board's Organization, as for any org board, not only
      the board's owner (`Kanban.Workspaces.InvitationAcceptance`).
    * There is no move back to a personal workspace, and none between org
      workspaces (no downgrade).

  Every check runs inside one transaction, against rows re-read and locked
  there:

    * The actor needs their own `board_users` **owner** row on the board.
      Owning the personal workspace the board sits in is not enough: the W2217
      backfill placed ownerless and memberless boards in other users' personal
      workspaces, and derived org-admin access does not count either.
    * The board must be in the actor's personal workspace.
    * The target must be an unarchived org workspace whose Organization the
      actor is an enabled org-admin of. Any other workspace, including one of
      another Organization, is refused like a missing one.

  After commit, `{Kanban.Boards, :members_changed, board_id}` is broadcast on
  `"board:<id>"`, so an open members screen recomputes
  `Kanban.Boards.member_cap_status/1` and drops the cap line.
  """

  import Ecto.Query, warn: false

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Organizations
  alias Kanban.Repo
  alias Kanban.Workspaces
  alias Kanban.Workspaces.Workspace

  @max_bigint 9_223_372_036_854_775_807

  @type error :: :not_found | :not_owner | :not_in_personal_workspace

  @doc """
  Moves `board` into the org workspace `workspace`. Both are structs or ids and
  are re-read from the database.

  Returns `{:ok, board}` with the new `workspace_id`, or:

    * `{:error, :not_found}` — no such board, or a workspace the actor cannot
      move boards into (missing, personal, archived, another Organization's, or
      one whose Organization the actor is not an org-admin of).
    * `{:error, :not_owner}` — the actor has no `board_users` owner row on it.
    * `{:error, :not_in_personal_workspace}` — the board is not in the actor's
      personal workspace (for example it is already in an org workspace).

  A refusal changes nothing.

  ## Examples

      iex> move_board_to_workspace(org_admin, board, workspace)
      {:ok, %Board{}}

      iex> move_board_to_workspace(org_admin, board, other_org_workspace)
      {:error, :not_found}

  """
  @spec move_board_to_workspace(User.t(), Board.t() | integer() | String.t(), term()) ::
          {:ok, Board.t()} | {:error, error()}
  def move_board_to_workspace(%User{} = actor, board, workspace) do
    fn -> move_locked(actor, id_of(board), id_of(workspace)) end
    |> Repo.transaction()
    |> broadcast_move()
  end

  defp move_locked(actor, board_id, workspace_id) do
    with {:ok, board} <- lock_board(board_id),
         :ok <- check_movable(board, actor),
         {:ok, target} <- lock_target(workspace_id, actor),
         {:ok, moved} <- place_board(board, target) do
      moved
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp place_board(board, target) do
    board
    |> Ecto.Changeset.change(workspace_id: target.id)
    |> Repo.update()
  end

  defp lock_board(nil), do: {:error, :not_found}

  defp lock_board(board_id) do
    case from(b in Board, where: b.id == ^board_id, lock: "FOR UPDATE") |> Repo.one() do
      %Board{} = board -> {:ok, board}
      nil -> {:error, :not_found}
    end
  end

  defp check_movable(board, actor) do
    with :ok <- check_owner_row(board, actor) do
      check_in_personal_workspace(board, actor)
    end
  end

  defp check_owner_row(%Board{id: board_id}, %User{id: user_id}) do
    if from(bu in BoardUser,
         where: bu.board_id == ^board_id and bu.user_id == ^user_id and bu.access == ^:owner
       )
       |> Repo.exists?(),
       do: :ok,
       else: {:error, :not_owner}
  end

  defp check_in_personal_workspace(%Board{workspace_id: workspace_id}, actor) do
    case Workspaces.get_personal_workspace(actor) do
      %Workspace{id: ^workspace_id} -> :ok
      _other -> {:error, :not_in_personal_workspace}
    end
  end

  # FOR SHARE serializes against OrgWorkspaces' archive, which locks the row
  # FOR UPDATE and then checks that the workspace holds no boards.
  defp lock_target(nil, _actor), do: {:error, :not_found}

  defp lock_target(workspace_id, actor) do
    from(w in Workspace,
      where: w.id == ^workspace_id and w.personal == false and is_nil(w.archived_at),
      lock: "FOR SHARE"
    )
    |> Repo.one()
    |> case do
      %Workspace{organization_id: org_id} = target when is_integer(org_id) ->
        if Organizations.org_admin?(actor, org_id),
          do: {:ok, target},
          else: {:error, :not_found}

      _missing ->
        {:error, :not_found}
    end
  end

  defp broadcast_move({:ok, %Board{id: board_id}} = result) do
    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {Kanban.Boards, :members_changed, board_id}
    )

    result
  end

  defp broadcast_move({:error, _reason} = error), do: error

  defp id_of(%{id: id}), do: parse_id(id)
  defp id_of(id), do: parse_id(id)

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> parse_id(int_id)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
