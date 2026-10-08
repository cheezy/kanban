defmodule Kanban.Labels do
  @moduledoc """
  Board-scoped labels and the labels attached to tasks.

  Every function takes the caller's `%Kanban.Accounts.Scope{}` first and
  authorizes through the board's existing access levels, denying by default:

    * `list_labels/2` returns the board's labels to any member (including
      read-only members) and `[]` to anyone else, so a non-member cannot tell
      "no access" from "no labels".
    * The mutating functions require `:owner` or `:modify` access on the
      label's (or task's) board and return `{:error, :unauthorized}` otherwise,
      matching `Kanban.Boards` and `Kanban.Columns`.
    * `set_task_labels/3` accepts only labels that belong to the task's own
      board. Any other id — from another board, nonexistent, or malformed —
      yields the same `{:error, :invalid_labels}`, so labels on other boards
      cannot be attached or probed.
  """
  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Labels.Label
  alias Kanban.Labels.TaskLabel
  alias Kanban.Repo
  alias Kanban.Tasks.Task

  @doc """
  Lists a board's labels, ordered by name ignoring case.

  Returns `[]` when the scope has no user or the user is not a member of the
  board.

  ## Examples

      iex> list_labels(scope, board)
      [%Label{}, ...]

  """
  def list_labels(scope, %Board{id: board_id}) do
    case scope_user(scope) do
      nil ->
        []

      %{id: user_id} ->
        Label
        |> join(:inner, [l], bu in BoardUser,
          on: bu.board_id == l.board_id and bu.user_id == ^user_id
        )
        |> where([l], l.board_id == ^board_id)
        |> order_by([l], asc: fragment("lower(?)", l.name), asc: l.id)
        |> Repo.all()
    end
  end

  @doc """
  Creates a label on the given board.

  ## Examples

      iex> create_label(scope, board, %{name: "Bug", color: :red})
      {:ok, %Label{}}

      iex> create_label(read_only_scope, board, %{name: "Bug", color: :red})
      {:error, :unauthorized}

  """
  def create_label(scope, %Board{id: board_id}, attrs) do
    with :ok <- authorize_write(scope, board_id) do
      %Label{board_id: board_id}
      |> Label.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Updates a label's name or colour. The label's board cannot be changed.

  ## Examples

      iex> update_label(scope, label, %{color: :green})
      {:ok, %Label{}}

  """
  def update_label(scope, %Label{board_id: board_id} = label, attrs) do
    with :ok <- authorize_write(scope, board_id) do
      label
      |> Label.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Deletes a label. Its task_labels rows are removed by the database cascade;
  the tasks themselves are never touched.

  ## Examples

      iex> delete_label(scope, label)
      {:ok, %Label{}}

  """
  def delete_label(scope, %Label{board_id: board_id} = label) do
    with :ok <- authorize_write(scope, board_id) do
      Repo.delete(label)
    end
  end

  @doc """
  Replaces a task's labels with the given label ids. An empty list clears
  them. Duplicate ids are collapsed.

  Returns `{:ok, task}` with `:labels` preloaded, `{:error, :unauthorized}`
  when the caller cannot modify the task's board, or
  `{:error, :invalid_labels}` when any id is not a label on the task's board.

  ## Examples

      iex> set_task_labels(scope, task, [label.id])
      {:ok, %Task{labels: [%Label{}]}}

      iex> set_task_labels(scope, task, [other_board_label.id])
      {:error, :invalid_labels}

  """
  def set_task_labels(scope, %Task{} = task, label_ids) when is_list(label_ids) do
    task = Repo.preload(task, :column)
    board_id = task.column.board_id
    label_ids = Enum.uniq(label_ids)

    with :ok <- authorize_write(scope, board_id),
         :ok <- validate_label_ids(label_ids, board_id) do
      replace_task_labels(task, label_ids)
    end
  end

  defp validate_label_ids(label_ids, board_id) do
    if Enum.all?(label_ids, &is_integer/1) and
         count_board_labels(label_ids, board_id) == length(label_ids) do
      :ok
    else
      {:error, :invalid_labels}
    end
  end

  defp count_board_labels(label_ids, board_id) do
    Label
    |> where([l], l.id in ^label_ids and l.board_id == ^board_id)
    |> Repo.aggregate(:count)
  end

  defp replace_task_labels(%Task{id: task_id} = task, label_ids) do
    Repo.transact(fn ->
      # Lock the task row so concurrent label edits on the same task are
      # serialized: the last writer's set wins instead of the two interleaving.
      Task
      |> where([t], t.id == ^task_id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

      TaskLabel
      |> where([tl], tl.task_id == ^task_id)
      |> Repo.delete_all()

      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)

      rows =
        Enum.map(label_ids, fn label_id ->
          %{task_id: task_id, label_id: label_id, inserted_at: now, updated_at: now}
        end)

      Repo.insert_all(TaskLabel, rows,
        on_conflict: :nothing,
        conflict_target: [:task_id, :label_id]
      )

      {:ok, Repo.preload(task, :labels, force: true)}
    end)
  end

  defp authorize_write(scope, board_id) do
    case scope_user(scope) do
      nil ->
        {:error, :unauthorized}

      %{id: user_id} ->
        if Boards.get_user_access(board_id, user_id) in [:owner, :modify] do
          :ok
        else
          {:error, :unauthorized}
        end
    end
  end

  defp scope_user(%Scope{user: %{id: _} = user}), do: user
  defp scope_user(_), do: nil
end
