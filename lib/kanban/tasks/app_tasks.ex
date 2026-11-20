defmodule Kanban.Tasks.AppTasks do
  @moduledoc """
  The task lookup and the quick capture of the Stride app (W2760,
  docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §6.11, §7.10), called as
  `Kanban.Tasks.get_task_for_app/2` and `Kanban.Tasks.capture_task/3`.

  A task is found as the web finds its board (`Kanban.Boards.get_board/2`):
  the person must hold access to the task's board. A task that does not
  exist, or sits on a board the person holds no access to (a public board
  they are not a member of included), is `{:error, :not_found}`, so a refusal
  never says that the task exists. An archived task is found, as the web's
  task page shows it.

  A capture creates a work or defect task in the board's Backlog through the
  web's create path (`Kanban.Tasks.create_task/2`), so positions, the
  identifier, the WIP limit, the history row and the board broadcast are
  those of a task created on the web. Only the title, the description and
  the type come from the caller; the column, `created_via: :mobile` and the
  creator are set here, and nothing else the caller sends can reach the
  changeset.
  """

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Columns
  alias Kanban.Columns.Column
  alias Kanban.Repo
  alias Kanban.Tasks.Creation
  alias Kanban.Tasks.Task

  @capture_types ["work", "defect"]
  @write_access [:owner, :modify]

  @type capture :: %{
          required(:type) => String.t(),
          required(:title) => String.t(),
          optional(:description) => String.t() | nil
        }

  @doc """
  Returns `{:ok, task, board}` for the task with `id` when the scope's user
  holds access to its board, with the task's `:column` and `:labels` loaded
  and the board's `user_access` set; else `{:error, :not_found}`.
  """
  @spec get_task_for_app(Scope.t() | nil, term()) ::
          {:ok, Task.t(), Board.t()} | {:error, :not_found}
  def get_task_for_app(%Scope{user: %{id: _} = user}, id) when is_integer(id) and id > 0 do
    with %Task{} = task <- Repo.get(Task, id),
         task = Repo.preload(task, [:column, :labels]),
         {:ok, %Board{user_access: access} = board} when not is_nil(access) <-
           Boards.get_board(task.column.board_id, user) do
      {:ok, task, board}
    else
      _not_found -> {:error, :not_found}
    end
  end

  def get_task_for_app(_scope, _id), do: {:error, :not_found}

  @doc """
  Creates a task captured in the app in `board`'s Backlog.

  `attrs` carries `type` (`"work"` or `"defect"`), `title` and an optional
  `description`; any other key is ignored. The guards run in order: the
  scope's user must hold `:owner` or `:modify` access on the board, re-read
  here (`{:error, :forbidden}`); the type must be work or defect (a goal is
  `{:error, changeset}` with "is invalid" on `type`); the board must have a Backlog column
  (`{:error, :no_backlog_column}`); and Backlog's WIP limit must hold one
  more task (`{:error, :backlog_wip_limit_reached}`). A title or description
  the task schema refuses is `{:error, changeset}`.

  Returns `{:ok, task}` with its `:column` and `:labels` loaded.
  """
  @spec capture_task(Scope.t() | nil, Board.t(), capture()) ::
          {:ok, Task.t()}
          | {:error,
             :forbidden
             | :no_backlog_column
             | :backlog_wip_limit_reached
             | Ecto.Changeset.t()}
  def capture_task(scope, %Board{} = board, attrs) when is_map(attrs) do
    with :ok <- authorize_write(scope, board),
         {:ok, type} <- capture_type(attrs),
         {:ok, backlog} <- fetch_backlog(board) do
      backlog
      |> Creation.create_task(capture_attrs(scope, attrs, type))
      |> created()
    end
  end

  # Only these keys reach the task: the app's form has no other field.
  defp capture_attrs(%Scope{user: user}, attrs, type) do
    %{
      "title" => Map.get(attrs, :title),
      "description" => Map.get(attrs, :description),
      "type" => type,
      "created_via" => "mobile",
      "created_by_id" => user.id
    }
  end

  @doc """
  `:ok` when the scope's user holds `:owner` or `:modify` access on `board`,
  read from the database now rather than from the board struct, else
  `{:error, :forbidden}`.
  """
  @spec authorize_write(Scope.t() | nil, Board.t()) :: :ok | {:error, :forbidden}
  def authorize_write(%Scope{user: %{id: user_id}}, %Board{id: board_id}) do
    if Boards.get_user_access(board_id, user_id) in @write_access,
      do: :ok,
      else: {:error, :forbidden}
  end

  def authorize_write(_scope, _board), do: {:error, :forbidden}

  @doc """
  The board's Backlog column, matched by name as the web matches it, or
  `{:error, :no_backlog_column}`.
  """
  @spec fetch_backlog(Board.t()) :: {:ok, Column.t()} | {:error, :no_backlog_column}
  def fetch_backlog(%Board{id: board_id}) do
    case Columns.get_column_by_name(board_id, "Backlog") do
      %Column{} = backlog -> {:ok, backlog}
      nil -> {:error, :no_backlog_column}
    end
  end

  defp capture_type(%{type: type}) when type in @capture_types, do: {:ok, type}

  # A goal, or any other type, is refused as the params cast refuses it: a
  # changeset with "is invalid" on type.
  defp capture_type(_attrs) do
    {:error,
     {%{}, %{type: :string}}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:type, "is invalid", validation: :inclusion)}
  end

  defp created({:ok, task}), do: {:ok, Repo.preload(task, [:column, :labels])}
  defp created({:error, :wip_limit_reached}), do: {:error, :backlog_wip_limit_reached}
  defp created({:error, %Ecto.Changeset{} = changeset}), do: {:error, changeset}
end
