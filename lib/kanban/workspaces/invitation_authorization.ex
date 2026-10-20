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
  """

  alias Kanban.Accounts.User
  alias Kanban.Boards
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
    do: Boards.owner?(board, actor)

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
