defmodule Kanban.Labels do
  @moduledoc """
  Board-scoped labels and the labels attached to tasks.

  Every function takes the caller's `%Kanban.Accounts.Scope{}` first and
  authorizes through the board's existing access levels, denying by default:

    * `list_labels/2` returns the board's labels to any member (including
      read-only members) and `[]` to anyone else, so a non-member cannot tell
      "no access" from "no labels".
    * `list_viewable_labels/2` widens that to everyone who can view the
      board — its members, plus anyone when the board is shared publicly
      read-only — matching `Kanban.Boards.get_board/2`. The board filter bar
      uses it so public read-only viewers can filter by label.
    * The mutating functions require `:owner` or `:modify` access on the
      label's (or task's) board and return `{:error, :unauthorized}` otherwise,
      matching `Kanban.Boards` and `Kanban.Columns`.
    * `set_task_labels/3` accepts only labels that belong to the task's own
      board. Any other id — from another board, nonexistent, or malformed —
      yields the same `{:error, :invalid_labels}`, so labels on other boards
      cannot be attached or probed.
    * `resolve_label_names/3` looks names up only among the board's own
      labels, so a name used on another board is indistinguishable from one
      that exists nowhere (W2239, the REST API's `labels` field).

  A successful `create_label/3`, `update_label/3` or `delete_label/2`
  broadcasts `{Kanban.Labels, :labels_changed, board_id}` on the board's
  `"board:<id>"` topic, so every open board re-renders its cards' label chips
  and refreshes its label filter. The message carries only the board id.
  """
  import Ecto.Query, warn: false

  alias Kanban.Accounts.Scope
  alias Kanban.Boards
  alias Kanban.Boards.Board
  alias Kanban.Boards.BoardUser
  alias Kanban.Labels.Label
  alias Kanban.Labels.TaskLabel
  alias Kanban.Repo
  alias Kanban.Tasks.Broadcaster
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
  Lists the labels of a board the scope's user can view, ordered like
  `list_labels/2`.

  A user can view a board when they are a member of it, or when the board is
  shared publicly read-only (`read_only: true`). Returns `[]` otherwise,
  including for a scope with no user.

  ## Examples

      iex> list_viewable_labels(public_viewer_scope, read_only_board)
      [%Label{}, ...]

      iex> list_viewable_labels(non_member_scope, private_board)
      []

  """
  def list_viewable_labels(scope, %Board{id: board_id}) do
    case scope_user(scope) do
      nil ->
        []

      %{id: user_id} ->
        members = from(bu in BoardUser, where: bu.user_id == ^user_id, select: bu.board_id)

        Label
        |> join(:inner, [l], b in Board, on: b.id == l.board_id)
        |> where([l, b], l.board_id == ^board_id)
        |> where([l, b], b.read_only or b.id in subquery(members))
        |> order_by([l], asc: fragment("lower(?)", l.name), asc: l.id)
        |> Repo.all()
    end
  end

  @doc """
  Returns the ids of the labels attached to a task, for a member of the
  label's board. Returns `[]` when the scope has no user, the user is not a
  member of the board, or the task is unsaved.

  ## Examples

      iex> list_task_label_ids(scope, task)
      [3, 7]

  """
  def list_task_label_ids(scope, %Task{id: task_id}) when is_integer(task_id) do
    case scope_user(scope) do
      nil ->
        []

      %{id: user_id} ->
        TaskLabel
        |> join(:inner, [tl], l in Label, on: l.id == tl.label_id)
        |> join(:inner, [tl, l], bu in BoardUser,
          on: bu.board_id == l.board_id and bu.user_id == ^user_id
        )
        |> where([tl], tl.task_id == ^task_id)
        |> order_by([tl, l], asc: l.id)
        |> select([tl, l], l.id)
        |> Repo.all()
    end
  end

  def list_task_label_ids(_scope, %Task{}), do: []

  @doc """
  Resolves label names to the ids of the board's labels, for a member of the
  board (W2239).

  Names are trimmed and matched case-insensitively, mirroring the
  case-insensitive uniqueness of label names on a board; an exact-case match
  wins should two labels ever fold to the same name. Duplicates (including
  case variants) collapse to their first occurrence, and ids are returned in
  request order.

  Only the given board's labels are consulted, so a name that exists on
  another board is reported exactly like a name that exists nowhere:
  `{:error, {:unknown_labels, names}}`, listing every unresolved name
  (trimmed, de-duplicated, in request order). A scope that is not a member of
  the board resolves nothing. Callers validate that `names` is a list of
  strings first.

  ## Examples

      iex> resolve_label_names(scope, board, ["bug", " Docs "])
      {:ok, [3, 7]}

      iex> resolve_label_names(scope, board, ["Bug", "Nope"])
      {:error, {:unknown_labels, ["Nope"]}}

  """
  def resolve_label_names(_scope, %Board{}, []), do: {:ok, []}

  def resolve_label_names(scope, %Board{} = board, names) when is_list(names) do
    labels = list_labels(scope, board)

    names
    |> Enum.map(&String.trim/1)
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.reduce({[], []}, &collect_label_id(labels, &1, &2))
    |> resolution_result()
  end

  defp resolution_result({ids, []}), do: {:ok, ids |> Enum.reverse() |> Enum.uniq()}
  defp resolution_result({_ids, unknown}), do: {:error, {:unknown_labels, Enum.reverse(unknown)}}

  defp collect_label_id(labels, name, {ids, unknown}) do
    case find_label_by_name(labels, name) do
      nil -> {ids, [name | unknown]}
      %Label{id: id} -> {[id | ids], unknown}
    end
  end

  defp find_label_by_name(labels, name) do
    folded = String.downcase(name)

    Enum.find(labels, &(&1.name == name)) ||
      Enum.find(labels, &(String.downcase(&1.name) == folded))
  end

  @doc """
  Returns a changeset for tracking label changes, for building forms.

  ## Examples

      iex> change_label(%Label{}, %{name: "Bug"})
      %Ecto.Changeset{data: %Label{}}

  """
  def change_label(%Label{} = label \\ %Label{}, attrs \\ %{}) do
    Label.changeset(label, attrs)
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
      |> broadcast_labels_changed(board_id)
    end
  end

  @doc """
  Updates a label's name or colour. The label's board cannot be changed.

  A label deleted since it was loaded yields `{:error, changeset}` with an
  error on `:id`, rather than raising `Ecto.StaleEntryError`.

  ## Examples

      iex> update_label(scope, label, %{color: :green})
      {:ok, %Label{}}

  """
  def update_label(scope, %Label{board_id: board_id} = label, attrs) do
    with :ok <- authorize_write(scope, board_id) do
      label
      |> Label.changeset(attrs)
      |> Repo.update(stale_error_field: :id)
      |> broadcast_labels_changed(board_id)
    end
  end

  @doc """
  Deletes a label. Its task_labels rows are removed by the database cascade;
  the tasks themselves are never touched. A label already deleted elsewhere
  yields `{:error, changeset}` with an error on `:id`, rather than raising.

  ## Examples

      iex> delete_label(scope, label)
      {:ok, %Label{}}

  """
  def delete_label(scope, %Label{board_id: board_id} = label) do
    with :ok <- authorize_write(scope, board_id) do
      label
      |> Repo.delete(stale_error_field: :id)
      |> broadcast_labels_changed(board_id)
    end
  end

  defp broadcast_labels_changed({:ok, _label} = result, board_id) do
    Phoenix.PubSub.broadcast(
      Kanban.PubSub,
      "board:#{board_id}",
      {__MODULE__, :labels_changed, board_id}
    )

    result
  end

  defp broadcast_labels_changed(error, _board_id), do: error

  @doc """
  Replaces a task's labels with the given label ids. An empty list clears
  them. Duplicate ids are collapsed.

  Returns `{:ok, task}` with `:labels` preloaded, `{:error, :unauthorized}`
  when the caller cannot modify the task's board, `{:error, :invalid_labels}`
  when any id is not a label on the task's board (including one deleted
  concurrently), or `{:error, :not_found}` when the task was deleted.

  A successful write broadcasts `:task_updated` on the board's topic once the
  transaction has committed, so every open board re-renders the task's label
  chips (the task form saves the task first and its labels second, so the
  task save's own broadcast can arrive before the labels exist).

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
         :ok <- validate_label_id_types(label_ids),
         {:ok, task} <- replace_task_labels(task, label_ids, board_id) do
      # No webhook: labels are not in the payload (as for bulk label changes).
      Broadcaster.broadcast_task_change(task, :task_updated, webhook: false)
      {:ok, task}
    end
  end

  defp validate_label_id_types(label_ids) do
    if Enum.all?(label_ids, &is_integer/1), do: :ok, else: {:error, :invalid_labels}
  end

  # The board check runs inside the transaction, after the task lock, and takes
  # a FOR KEY SHARE lock on every label it accepts: a label deleted concurrently is
  # then either already gone (an :invalid_labels error) or cannot be deleted
  # until this write commits, so the insert never hits a foreign-key error.
  defp replace_task_labels(%Task{id: task_id} = task, label_ids, board_id) do
    Repo.transact(fn ->
      with :ok <- lock_task(task_id),
           :ok <- lock_board_labels(label_ids, board_id) do
        write_task_labels(task, label_ids)
      end
    end)
  end

  # Locks the task row so concurrent label edits on the same task are
  # serialized: the last writer's set wins instead of the two interleaving.
  defp lock_task(task_id) do
    Task
    |> where([t], t.id == ^task_id)
    |> lock("FOR UPDATE")
    |> select([t], t.id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      _id -> :ok
    end
  end

  defp lock_board_labels([], _board_id), do: :ok

  defp lock_board_labels(label_ids, board_id) do
    locked =
      Label
      |> where([l], l.id in ^label_ids and l.board_id == ^board_id)
      |> lock("FOR KEY SHARE")
      |> select([l], l.id)
      |> Repo.all()

    if length(locked) == length(label_ids), do: :ok, else: {:error, :invalid_labels}
  end

  defp write_task_labels(%Task{id: task_id} = task, label_ids) do
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
