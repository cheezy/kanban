defmodule KanbanWeb.API.TaskLabels do
  @moduledoc """
  The REST API's `labels` field and `label` filter (W2239).

  Clients address labels by **name**; the API never exposes label ids. This
  module validates the request shape, resolves names against the API token's
  own board through `Kanban.Labels.resolve_label_names/3`, and applies the
  resolved ids through `Kanban.Labels.set_task_labels/3` — the only writer of
  a task's labels.

  ## Contract

    * **Resolved in the controller layer, never mass-assigned.** `labels` is
      popped from the params before they reach a changeset, so no changeset
      allow-list grows and no workflow or audit field becomes assignable.
    * **Validated before any write.** `prepare_create/4` and
      `prepare_batch/3` check every name — the task's, every child's, every
      goal's — before the caller inserts a row, so an unknown name leaves
      nothing behind.
    * **No existence oracle.** Only the token's board is consulted, so a
      label that exists on another board is reported in exactly the same
      words as one that exists nowhere, and a `label` filter naming one
      matches nothing.
    * **Labels are never created here.** Label management stays in the
      board UI.

  Errors are returned as a schemaless changeset carrying `:labels` errors,
  so every endpoint renders them through its existing 422 shape.
  """

  import Ecto.Changeset, only: [add_error: 3, change: 1]

  alias Kanban.Accounts.Scope
  alias Kanban.Labels

  require Logger

  @max_name_length 40
  @invalid_shape "must be an array of label names, each 1 to #{@max_name_length} characters"

  @typedoc "Resolved label ids to apply, or `nil` when the field was absent."
  @type plan :: [pos_integer()] | nil

  @typedoc "The caller's `Kanban.Accounts.Scope`, or `nil`."
  @type scope :: struct() | nil

  @doc """
  Validates a raw `labels` value: a list of strings, each 1 to
  #{@max_name_length} characters once trimmed. `nil` is rejected too — an
  empty list is how labels are cleared.
  """
  @spec validate_names(term()) :: {:ok, [String.t()]} | {:error, String.t()}
  def validate_names(names) when is_list(names) do
    if Enum.all?(names, &valid_name?/1),
      do: {:ok, names},
      else: {:error, @invalid_shape}
  end

  def validate_names(_names), do: {:error, @invalid_shape}

  @doc """
  Validates a `label` filter value: a single label name of 1 to
  #{@max_name_length} characters once trimmed. Returns the trimmed name.
  """
  @spec validate_filter_name(term()) :: {:ok, String.t()} | :error
  def validate_filter_name(name) do
    if valid_name?(name), do: {:ok, String.trim(name)}, else: :error
  end

  defp valid_name?(name) when is_binary(name) do
    String.valid?(name) and name |> String.trim() |> String.length() |> in_name_range?()
  end

  defp valid_name?(_name), do: false

  defp in_name_range?(length), do: length in 1..@max_name_length

  @doc """
  Validates and resolves a raw `labels` value against `board`. Returns the
  label ids, or an error message naming the problem.
  """
  @spec resolve(scope(), struct(), term()) ::
          {:ok, [pos_integer()]} | {:error, String.t()}
  def resolve(scope, board, raw) do
    with {:ok, names} <- validate_names(raw) do
      case Labels.resolve_label_names(scope, board, names) do
        {:ok, ids} -> {:ok, ids}
        {:error, {:unknown_labels, unknown}} -> {:error, unknown_message(unknown)}
      end
    end
  end

  defp unknown_message(names),
    do: "unknown labels: " <> Enum.map_join(names, ", ", &inspect/1)

  @doc """
  Pops `labels` from a task's params and from each of its child tasks, and
  resolves them all. Returns the stripped params and children with the plan
  for each, or a changeset carrying every label error found (child errors are
  prefixed `tasks[i]`). Non-map params and a non-list `children` pass through
  untouched, to fail in the existing validation.
  """
  @spec prepare_create(scope(), struct(), term(), term()) ::
          {:ok, term(), term(), %{task: plan(), children: [plan()]}}
          | {:error, Ecto.Changeset.t()}
  def prepare_create(scope, board, params, children) do
    {params, task_result} = pop_and_resolve(scope, board, params)
    {children, child_results} = pop_and_resolve_children(scope, board, children)

    case error_messages(nil, task_result) ++ child_error_messages(child_results) do
      [] -> {:ok, params, children, build_plan(task_result, child_results)}
      errors -> {:error, error_changeset(errors)}
    end
  end

  defp pop_and_resolve_children(scope, board, children) when is_list(children) do
    children
    |> Enum.map(&pop_and_resolve(scope, board, &1))
    |> Enum.unzip()
  end

  defp pop_and_resolve_children(_scope, _board, children), do: {children, []}

  defp child_error_messages(child_results) do
    child_results
    |> Enum.with_index()
    |> Enum.flat_map(fn {result, index} -> error_messages(index, result) end)
  end

  defp build_plan(task_result, child_results),
    do: %{task: plan(task_result), children: Enum.map(child_results, &plan/1)}

  @doc """
  Runs `prepare_create/4` over every goal of a batch before anything is
  created. Returns each goal's stripped params paired with its plan, or the
  index and changeset of the first goal with a label error. A non-list
  `goals` returns `:skip`, leaving the batch path to handle it as before.
  """
  @spec prepare_batch(scope(), struct(), term()) ::
          {:ok, [{term(), map()}]} | {:error, non_neg_integer(), Ecto.Changeset.t()} | :skip
  def prepare_batch(scope, board, goals) when is_list(goals) do
    goals
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, &prepare_next_goal(scope, board, &1, &2))
    |> reverse_prepared()
  end

  def prepare_batch(_scope, _board, _goals), do: :skip

  defp prepare_next_goal(scope, board, {goal, index}, {:ok, acc}) do
    case prepare_goal(scope, board, goal) do
      {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
      {:error, changeset} -> {:halt, {:error, index, changeset}}
    end
  end

  defp prepare_goal(scope, board, goal) do
    children = if is_map(goal), do: Map.get(goal, "tasks", []), else: []

    with {:ok, goal, children, plan} <- prepare_create(scope, board, goal, children) do
      {:ok, {put_children(goal, children), plan}}
    end
  end

  defp reverse_prepared({:ok, prepared}), do: {:ok, Enum.reverse(prepared)}
  defp reverse_prepared(error), do: error

  defp put_children(goal, children) when is_map(goal) and is_list(children),
    do: if(Map.has_key?(goal, "tasks"), do: Map.put(goal, "tasks", children), else: goal)

  defp put_children(goal, _children), do: goal

  defp pop_and_resolve(scope, board, params) when is_map(params) do
    case Map.pop(params, "labels", :absent) do
      {:absent, params} -> {params, :absent}
      {raw, params} -> {params, resolve(scope, board, raw)}
    end
  end

  defp pop_and_resolve(_scope, _board, params), do: {params, :absent}

  defp plan({:ok, ids}), do: ids
  defp plan(:absent), do: nil

  defp error_messages(nil, {:error, message}), do: [message]
  defp error_messages(index, {:error, message}), do: ["tasks[#{index}] #{message}"]
  defp error_messages(_index, _result), do: []

  @doc """
  A changeset carrying `messages` as `:labels` errors, for the existing 422
  renderers.
  """
  @spec error_changeset([String.t()]) :: Ecto.Changeset.t()
  def error_changeset(messages) do
    # add_error/3 prepends, so add in reverse to render in request order.
    messages
    |> Enum.reverse()
    |> Enum.reduce(change({%{}, %{labels: {:array, :string}}}), fn message, cs ->
      add_error(cs, :labels, message)
    end)
  end

  @doc """
  Applies a resolved plan to a saved task. `nil` (the field was absent) does
  nothing; a list replaces the task's labels, so `[]` clears them.

  The ids were resolved before the task was written, so the only failure left
  is a label deleted in between. That outcome is the same as the deletion
  arriving just after the assignment, so it is logged and the request still
  succeeds with the task's real, persisted labels.
  """
  @spec apply_plan(scope(), Kanban.Tasks.Task.t(), plan()) :: :ok
  def apply_plan(_scope, _task, nil), do: :ok

  def apply_plan(scope, task, ids) when is_list(ids) do
    case Labels.set_task_labels(scope, task, ids) do
      {:ok, _task} ->
        :ok

      {:error, reason} ->
        Logger.warning("API labels not applied: #{inspect(reason)}", task_id: task.id)
        :ok
    end
  end

  @doc """
  Applies a goal's plan to the created goal and its child tasks. A `nil` plan
  (the batch's `goals` was not a list) applies nothing.
  """
  @spec apply_goal_plan(scope(), Kanban.Tasks.Task.t(), [Kanban.Tasks.Task.t()], map() | nil) ::
          :ok
  def apply_goal_plan(_scope, _goal, _children, nil), do: :ok

  def apply_goal_plan(scope, goal, children, plan) do
    apply_plan(scope, goal, plan.task)
    apply_children(scope, children, plan.children)
  end

  @doc """
  Applies each child's plan to the created child tasks. Children are created
  at consecutive positions in request order, so sorting by position pairs
  each created child with the request entry it came from.
  """
  @spec apply_children(scope(), [Kanban.Tasks.Task.t()], [plan()]) :: :ok
  def apply_children(scope, created_children, plans) do
    created_children
    |> Enum.sort_by(& &1.position)
    |> Enum.zip(plans)
    |> Enum.each(fn {task, plan} -> apply_plan(scope, task, plan) end)
  end

  @doc """
  Resolves a validated `label` filter name to the filter to apply on the
  conn's board: `:all` when no filter was given, `{:label, id}` for a label on
  the board, or `:none` when the board has no such label — which yields an
  empty result, never an error.
  """
  @spec label_filter(Plug.Conn.t(), String.t() | nil) :: :all | :none | {:label, pos_integer()}
  def label_filter(_conn, nil), do: :all

  def label_filter(conn, name) when is_binary(name) do
    scope = Scope.for_user(conn.assigns.current_user)

    case Labels.resolve_label_names(scope, conn.assigns.current_board, [name]) do
      {:ok, [id]} -> {:label, id}
      _ -> :none
    end
  end

  @doc """
  The paginated-listing filter for a validated `label` name: `%{}` without
  one, `%{label_id: id}` for a label on the board, and `%{label_id: :none}`
  when the board has no such label (the caller returns an empty page).
  """
  @spec page_filter(Plug.Conn.t(), String.t() | nil) :: map()
  def page_filter(conn, name) do
    case label_filter(conn, name) do
      :all -> %{}
      {:label, id} -> %{label_id: id}
      :none -> %{label_id: :none}
    end
  end

  @doc "The caller's scope, for the label functions."
  @spec scope(Plug.Conn.t()) :: scope()
  def scope(conn), do: Scope.for_user(conn.assigns.current_user)
end
