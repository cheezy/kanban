defmodule KanbanWeb.API.BoardWriteAccess do
  @moduledoc """
  The live board-access check every API write makes before it looks at a task.

  A token's user can lose access to the token's board without the token being
  revoked (see `KanbanWeb.API.BoardReadAccess`). A write that fetched the task
  first and checked access second told that user what it found: a missing id
  answered `404`, while an existing task answered with its state ("Task is not
  currently claimed", "Task must be in progress or blocked", "You can only
  unclaim tasks that you claimed"). So the check runs first, and a refused
  write gets one fixed `403` whether the task exists or what state it is in.

    * `authorize/2` — write access (`:owner` or `:modify`), refused with
      `{:error, :not_authorized_write}`: claim, complete, unclaim,
      changed_files, mark_reviewed, mark_done and after_goal.
    * `authorize_member/2` — any board access, `:read_only` included, refused
      with `{:error, :not_authorized}`: adding a comment, which any board
      member may do (`Kanban.Tasks.CommentPolicy`).

  As a plug it runs `authorize/2` and halts with the
  `KanbanWeb.API.TaskErrors.error_body/1` body of its `:reason` option
  (default `:not_authorized_write`), so the after_goal report keeps its own
  documented `:not_authorized_after_goal` body.

  Both checks read `Kanban.Boards.get_user_access/2`, the same live access the
  read check and the Tasks context use. A workspace token's board was already
  checked for write access when the request selected it, so it passes.
  """

  @behaviour Plug

  import Plug.Conn, only: [halt: 1]

  alias Kanban.Boards
  alias KanbanWeb.API.TaskErrors

  @write_access [:owner, :modify]

  @impl Plug
  def init(opts), do: Keyword.get(opts, :reason, :not_authorized_write)

  @impl Plug
  def call(%Plug.Conn{assigns: assigns} = conn, reason) do
    case authorize(assigns[:current_board], assigns[:current_user]) do
      :ok -> conn
      {:error, _} -> conn |> TaskErrors.render_error(reason) |> halt()
    end
  end

  @doc """
  `:ok` when `user` holds `:owner` or `:modify` access to `board`, else
  `{:error, :not_authorized_write}`.
  """
  @spec authorize(map() | nil, map() | nil) :: :ok | {:error, :not_authorized_write}
  def authorize(%{id: board_id}, %{id: user_id}) do
    if Boards.get_user_access(board_id, user_id) in @write_access,
      do: :ok,
      else: {:error, :not_authorized_write}
  end

  def authorize(_board, _user), do: {:error, :not_authorized_write}

  @doc """
  `:ok` when `user` holds any access to `board`, `:read_only` included, else
  `{:error, :not_authorized}`.
  """
  @spec authorize_member(map() | nil, map() | nil) :: :ok | {:error, :not_authorized}
  def authorize_member(%{id: board_id}, %{id: user_id}) do
    if Boards.get_user_access(board_id, user_id), do: :ok, else: {:error, :not_authorized}
  end

  def authorize_member(_board, _user), do: {:error, :not_authorized}
end
