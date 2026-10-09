defmodule KanbanWeb.TaskLive.Form.LabelSelection do
  @moduledoc """
  The task form's label picker state and save path (W2234), kept out of
  `KanbanWeb.TaskLive.FormComponent` (which sits at the module-size limit in
  `AGENTS.md`).

  The picker posts `task[label_ids][]` — a hidden `""` sentinel plus one value
  per checked label — so an empty selection still arrives as a key. Labels are
  not a `Kanban.Tasks.Task` cast field: the ids are popped off the params
  before the task changeset sees them and written afterwards through
  `Kanban.Labels.set_task_labels/3`. Every read and write goes through
  `Kanban.Labels`; this module issues no queries of its own.

  Submitted ids are resolved against the board's labels twice:

    * before the task is saved, against the labels the picker offered (only
      the current board's). An id the picker never offered — another board's
      label, a nonexistent one, or a malformed value — rejects the whole save,
      like the form's other relational fields.
    * after the task is saved, against the board's labels as they stand now,
      so a label deleted while the form was open is dropped and reported
      instead of failing the label write.
  """
  use Gettext, backend: KanbanWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Kanban.Labels
  alias KanbanWeb.TaskLive.Form.OptionBuilders

  @param "label_ids"

  @doc """
  Assigns the picker's options (the board's labels) and the task's current
  selection. A new task starts with no labels.
  """
  def assign_options(socket, scope, board, task, action) do
    selected = initial_label_ids(scope, task, action)

    options = scope |> Labels.list_labels(board) |> OptionBuilders.build_label_options()

    socket
    |> assign(:label_options, options)
    |> assign(:initial_label_ids, selected)
    |> assign(:selected_label_ids, selected)
  end

  defp initial_label_ids(scope, %{id: id} = task, :edit_task) when is_integer(id),
    do: Labels.list_task_label_ids(scope, task)

  defp initial_label_ids(_scope, _task, _action), do: []

  @doc """
  Keeps the checked labels across `phx-change` re-renders, which rebuild the
  task changeset and would otherwise lose them.
  """
  def track(socket, params) do
    case Map.fetch(params, @param) do
      {:ok, raw} -> assign(socket, :selected_label_ids, valid_ids(raw))
      :error -> socket
    end
  end

  @doc """
  Pops the submitted label ids off the save params and resolves them against
  the offered label ids.

  Returns `{:unchanged, params}` when the picker did not post or the selection
  equals the task's labels when the form opened, `{{:set, ids}, params}` for a
  new selection, and `{:invalid, params}` when any submitted id was not
  offered. `params` never contains `"label_ids"`.

  ## Examples

      iex> pop(%{"label_ids" => ["", "3"]}, [3, 4], [])
      {{:set, [3]}, %{}}

      iex> pop(%{"label_ids" => ["", "99"]}, [3, 4], [])
      {:invalid, %{}}

  """
  def pop(params, offered_ids, initial_ids) do
    case Map.pop(params, @param) do
      {nil, rest} -> {:unchanged, rest}
      {raw, rest} -> {resolve(raw, offered_ids, initial_ids), rest}
    end
  end

  defp resolve(raw, offered_ids, initial_ids) do
    with {:ok, ids} <- parse_ids(raw),
         true <- Enum.all?(ids, &(&1 in offered_ids)) do
      if MapSet.new(ids) == MapSet.new(initial_ids), do: :unchanged, else: {:set, ids}
    else
      _ -> :invalid
    end
  end

  @doc """
  Parses the posted ids, ignoring the `""` sentinel. Returns `:error` for any
  value that is not a whole positive integer.

  ## Examples

      iex> parse_ids(["", "3", "7", "3"])
      {:ok, [3, 7]}

      iex> parse_ids(["3", "3abc"])
      :error

  """
  def parse_ids(raw) when is_list(raw) do
    raw
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, &collect_id/2)
    |> finish_ids()
  end

  def parse_ids(_raw), do: :error

  defp collect_id(value, {:ok, acc}) do
    case parse_id(value) do
      {:ok, id} -> {:cont, {:ok, [id | acc]}}
      :error -> {:halt, :error}
    end
  end

  defp finish_ids({:ok, ids}), do: {:ok, ids |> Enum.reverse() |> Enum.uniq()}
  defp finish_ids(:error), do: :error

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_id(_value), do: :error

  defp valid_ids(raw) do
    case parse_ids(raw) do
      {:ok, ids} -> ids
      :error -> []
    end
  end

  @doc """
  Writes the label change for a task that has just been saved, returning the
  socket with an error flash when the labels could not be (fully) written.
  The task save itself is never undone.
  """
  def apply_change(socket, task) do
    case write(socket.assigns[:current_scope], socket.assigns.board, task, label_change(socket)) do
      :ok -> socket
      {:error, message} -> put_flash(socket, :error, message)
    end
  end

  defp label_change(socket), do: Map.get(socket.assigns, :label_change, :unchanged)

  @doc """
  Writes a resolved label change for a saved task. Ids no longer on the board
  (deleted since the form opened) are dropped before the write and reported.
  """
  def write(_scope, _board, _task, :unchanged), do: :ok

  def write(scope, board, task, {:set, ids}) do
    current = scope |> Labels.list_labels(board) |> MapSet.new(& &1.id)
    kept = Enum.filter(ids, &MapSet.member?(current, &1))

    scope
    |> Labels.set_task_labels(task, kept)
    |> write_result(length(kept) == length(ids))
  end

  defp write_result({:ok, _task}, true = _all_kept), do: :ok

  defp write_result({:ok, _task}, false = _all_kept),
    do: {:error, gettext("Task saved, but a label deleted in the meantime was not applied")}

  defp write_result({:error, _reason}, _all_kept),
    do: {:error, gettext("Task saved, but its labels could not be updated")}
end
