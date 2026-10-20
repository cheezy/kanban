defmodule Kanban.Workspaces.InvitationAuthorization do
  @moduledoc """
  Who may send, resend and revoke email invitations (W2219), for
  `Kanban.Workspaces.Invitations`.

  Every check re-reads the actor, the workspace or board and the invitation
  from the database, so a stale struct, a revoked role or a disabled account
  cannot pass:

    * a workspace invitation needs an enabled org-admin of the workspace's
      Organization, on a live (not personal, not archived) org workspace;
    * a board invitation needs the board's own owner row on a board in a
      personal workspace, or an org-admin on a board in an org workspace.

  Refusals are `{:error, :unauthorized}`; an invitation that is not open, or
  an id that is not one, is `{:error, :not_found}`.

  `inviter_may_send?/3` applies the same rules to an invitation's sender when
  it is accepted, so an invitation stops working once its sender loses the
  right to send it.
  """

  alias Kanban.Accounts.User
  alias Kanban.Boards.Board
  alias Kanban.Repo
  alias Kanban.Workspaces.Invitation
  alias Kanban.Workspaces.Policy
  alias Kanban.Workspaces.Workspace

  @max_bigint 9_223_372_036_854_775_807

  @doc """
  The actor and the org workspace they manage, both re-read, or
  `{:error, :unauthorized}`. A missing, personal or archived workspace, a
  disabled actor and a non-org-admin all look the same.
  """
  @spec managed_workspace(User.t(), Workspace.t() | integer() | String.t()) ::
          {:ok, User.t(), Workspace.t()} | {:error, :unauthorized}
  def managed_workspace(%User{id: actor_id}, workspace) do
    with {:ok, actor} <- fresh_actor(actor_id),
         id when is_integer(id) <- parse_id(workspace_id(workspace)),
         %Workspace{personal: false, archived_at: nil} = workspace <- Repo.get(Workspace, id),
         true <- Policy.can_manage_workspace?(actor, workspace) do
      {:ok, actor, workspace}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  The board `board_id` names, when it is in `workspace`: `{:ok, nil}` for no
  board, `{:error, :invalid_board}` for a board elsewhere or a bad id.
  """
  @spec workspace_board(Workspace.t(), term()) ::
          {:ok, Board.t() | nil} | {:error, :invalid_board}
  def workspace_board(_workspace, board_id) when board_id in [nil, ""], do: {:ok, nil}

  def workspace_board(%Workspace{id: workspace_id}, board_id) do
    with id when is_integer(id) <- parse_id(board_id),
         %Board{workspace_id: ^workspace_id} = board <- Repo.get(Board, id) do
      {:ok, board}
    else
      _ -> {:error, :invalid_board}
    end
  end

  @doc """
  The actor, the board and its live workspace when the actor may invite to
  the board by email, or `{:error, :unauthorized}`.
  """
  @spec invitable_board(User.t(), Board.t() | integer() | String.t() | nil) ::
          {:ok, User.t(), Board.t(), Workspace.t()} | {:error, :unauthorized}
  def invitable_board(%User{id: actor_id}, board) do
    with {:ok, actor} <- fresh_actor(actor_id),
         {:ok, board, workspace} <- live_board(board),
         true <- may_invite_to_board?(actor, board, workspace) do
      {:ok, actor, board, workspace}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  An open invitation the actor may still send, with its workspace and board,
  re-read. `{:error, :not_found}` for an accepted, revoked or unknown one,
  `{:error, :unauthorized}` when the actor may not manage it.
  """
  @spec managed_invitation(User.t(), term()) ::
          {:ok, User.t(), Invitation.t(), Workspace.t(), Board.t() | nil}
          | {:error, :unauthorized | :not_found}
  def managed_invitation(%User{} = actor, invitation_id) do
    with id when is_integer(id) <- parse_id(invitation_id),
         %Invitation{accepted_at: nil, revoked_at: nil} = invitation <-
           Invitation |> Repo.get(id) |> Repo.preload([:workspace, :board]) do
      authorize_invitation(actor, invitation)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  True when the user who sent `invitation` may still send it, read from the
  database: an enabled account that, for a workspace invitation, is an
  org-admin of `workspace`'s Organization and, for a board-only invitation, is
  still the owner of `board`, which must still be in a personal workspace
  (`workspace`, the one the board is in now). A board-only invitation on a
  board that has moved into an Organization workspace is never sendable: it
  would grant access to an org board without Organization membership, and on
  org boards only workspace invitations are sent. An invitation whose sender
  was deleted is never sendable either.

  The caller passes the workspace and board it has locked, so the answer holds
  for the rest of its transaction.
  """
  @spec inviter_may_send?(Invitation.t(), Workspace.t(), Board.t() | nil) :: boolean()
  def inviter_may_send?(%Invitation{invited_by_id: inviter_id} = invitation, workspace, board) do
    case fresh_actor(inviter_id) do
      {:ok, inviter} -> may_send?(inviter, invitation, workspace, board)
      :error -> false
    end
  end

  defp may_send?(
         inviter,
         %Invitation{role: nil},
         %Workspace{personal: true} = workspace,
         %Board{} = board
       ),
       do: may_invite_to_board?(inviter, board, workspace)

  defp may_send?(_inviter, %Invitation{role: nil}, _workspace, _board), do: false

  defp may_send?(inviter, %Invitation{}, %Workspace{} = workspace, _board),
    do: Policy.can_manage_workspace?(inviter, workspace)

  defp authorize_invitation(actor, %Invitation{role: nil, board: %Board{} = board} = invitation) do
    case invitable_board(actor, board) do
      {:ok, actor, board, %Workspace{personal: true} = workspace} ->
        {:ok, actor, invitation, workspace, board}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp authorize_invitation(_actor, %Invitation{role: nil}), do: {:error, :not_found}

  defp authorize_invitation(actor, %Invitation{} = invitation) do
    case managed_workspace(actor, invitation.workspace_id) do
      {:ok, actor, workspace} -> {:ok, actor, invitation, workspace, invitation.board}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fresh_actor(nil), do: :error

  defp fresh_actor(actor_id) do
    case Repo.get(User, actor_id) do
      %User{disabled_at: nil} = actor -> {:ok, actor}
      _disabled_or_gone -> :error
    end
  end

  defp live_board(board) do
    with id when is_integer(id) <- parse_id(board_id(board)),
         %Board{workspace: %Workspace{archived_at: nil} = workspace} = board <-
           Board |> Repo.get(id) |> Repo.preload(:workspace) do
      {:ok, board, workspace}
    else
      _ -> :error
    end
  end

  # On a personal workspace's board, effective access is the board_users row
  # alone (Policy derives nothing there), so :owner means the explicit owner.
  defp may_invite_to_board?(actor, board, %Workspace{personal: true}),
    do: Policy.effective_board_access(board, actor) == :owner

  defp may_invite_to_board?(actor, _board, %Workspace{} = workspace),
    do: Policy.can_manage_workspace?(actor, workspace)

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(id), do: id

  defp board_id(%Board{id: id}), do: id
  defp board_id(id), do: id

  defp parse_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> parse_id(int)
      _ -> nil
    end
  end

  defp parse_id(_id), do: nil
end
