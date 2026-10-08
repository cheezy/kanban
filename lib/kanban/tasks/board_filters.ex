defmodule Kanban.Tasks.BoardFilters do
  @moduledoc """
  The board view's search-and-filter model, and its composition onto a task
  query (W2235).

  A `%BoardFilters{}` holds the five dimensions the board filter bar offers —
  free-text `search`, `type`, `priority`, `assignee` and `label_id` — each
  `nil` when unset. `apply_filters/2` narrows an existing task query with
  every set dimension ANDed together; an inactive filter returns the query
  untouched. Building the struct from untrusted URL params is
  `KanbanWeb.BoardLive.FilterParams`' job; this module only ever sees values
  that are already whitelisted atoms, integers, or a trimmed string.

  ## Contract

    * **Board scoping comes from the caller.** The base query is expected to
      be already restricted to one board's columns (as
      `Kanban.Tasks.Queries.list_tasks_by_columns/2` is). Filters only ever
      narrow that set, so they can never widen visibility.
    * **Search is parameterized.** The text is bound as a parameter with its
      LIKE wildcards (`%`, `_`) and the escape character escaped, and matched
      case-insensitively against the title or the identifier — never
      interpolated into SQL.
    * **Labels are board-scoped.** A label only matches tasks whose column is
      on the label's own board, so a label id from another board matches
      nothing.
    * **Goals keep their context.** A task is shown when it matches, or when
      it is a goal with at least one non-archived child that matches — so a
      matching child is never shown without its goal card. A matching goal
      does not pull in children that do not match.
  """
  import Ecto.Query, warn: false

  alias Kanban.Columns.Column
  alias Kanban.Labels.Label
  alias Kanban.Labels.TaskLabel
  alias Kanban.Tasks.Task

  defstruct search: nil, type: nil, priority: nil, assignee: nil, label_id: nil

  @type t :: %__MODULE__{
          search: String.t() | nil,
          type: :work | :defect | :goal | nil,
          priority: :low | :medium | :high | :critical | nil,
          assignee: :unassigned | pos_integer() | nil,
          label_id: pos_integer() | nil
        }

  @doc """
  True when at least one filter dimension is set. `nil` and the default
  struct are inactive.
  """
  @spec active?(t() | nil) :: boolean()
  def active?(%__MODULE__{} = filters), do: filters != %__MODULE__{}
  def active?(_), do: false

  @doc """
  Narrows `query` (rooted on `Kanban.Tasks.Task`) to the tasks matching every
  set dimension of `filters`, plus the goals of matching children. Returns
  the query unchanged when the filters are inactive.
  """
  @spec apply_filters(Ecto.Queryable.t(), t() | nil) :: Ecto.Queryable.t()
  def apply_filters(query, filters) do
    if active?(filters) do
      match = match_dynamic(filters)

      matching_child_parents =
        from c in Task,
          where: ^match,
          where: not is_nil(c.parent_id) and is_nil(c.archived_at),
          select: c.parent_id

      shown =
        dynamic(
          [t],
          ^match or (t.type == :goal and t.id in subquery(matching_child_parents))
        )

      where(query, ^shown)
    else
      query
    end
  end

  defp match_dynamic(%__MODULE__{} = filters) do
    filters
    |> Map.from_struct()
    |> Enum.reduce(dynamic(true), &add_condition/2)
  end

  defp add_condition({_key, nil}, acc), do: acc

  defp add_condition({:search, text}, acc) do
    pattern = "%" <> escape_like(text) <> "%"

    dynamic(
      [t],
      ^acc and
        (fragment("? ILIKE ? ESCAPE '\\'", t.title, ^pattern) or
           fragment("? ILIKE ? ESCAPE '\\'", t.identifier, ^pattern))
    )
  end

  defp add_condition({:type, type}, acc), do: dynamic([t], ^acc and t.type == ^type)

  defp add_condition({:priority, priority}, acc),
    do: dynamic([t], ^acc and t.priority == ^priority)

  defp add_condition({:assignee, :unassigned}, acc),
    do: dynamic([t], ^acc and is_nil(t.assigned_to_id))

  defp add_condition({:assignee, user_id}, acc) when is_integer(user_id),
    do: dynamic([t], ^acc and t.assigned_to_id == ^user_id)

  defp add_condition({:label_id, label_id}, acc) when is_integer(label_id) do
    labelled_task_ids =
      from tl in TaskLabel,
        join: l in Label,
        on: l.id == tl.label_id,
        join: lt in Task,
        on: lt.id == tl.task_id,
        join: c in Column,
        on: c.id == lt.column_id,
        where: tl.label_id == ^label_id and l.board_id == c.board_id,
        select: tl.task_id

    dynamic([t], ^acc and t.id in subquery(labelled_task_ids))
  end

  # Same escaping as `Kanban.Metrics.UserActivity.escape_like/1`: the escape
  # character first, then the two LIKE wildcards, so user text matches
  # literally under `ESCAPE '\\'`.
  defp escape_like(text) do
    String.replace(text, ["\\", "%", "_"], &("\\" <> &1))
  end
end
