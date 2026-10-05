defmodule Kanban.Tasks.Task.HierarchyValidations do
  @moduledoc """
  Enforces Stride's two-level task hierarchy (D354).

  A goal contains work and defect tasks and nothing else: a goal can never be
  the child of another task, and a goal's child carries no tasks of its own.
  Without this rule a goal created with a nested child of type `goal` reused
  its parent's `G` identifier, because the child identifiers were
  pre-generated before the parent row existed.

  The nested-goal message is shown to API clients and, through the task form,
  to people, so it is listed in `priv/gettext/errors.pot` and every locale's
  `errors.po`; it must not drift without updating those entries. The
  nested-tasks message only ever reaches the API, so it is not translated.

  `child_task_error/1` is called by `Kanban.Tasks.Creation` on the children of
  a goal-with-tasks create, before any identifier is generated.

  `validate_goal_has_no_parent/1` is called by every `Kanban.Tasks.Task`
  changeset that can set `type` or `parent_id`. It only fires when one of those
  two fields is being changed, so a row that already breaks the rule (written
  before D354) can still be edited, claimed or completed; changing its type or
  parent is what is refused.
  """

  import Ecto.Changeset

  alias Kanban.Tasks.TaskType

  @nested_goal_message "must be 'work' or 'defect' for a task inside a goal; a goal cannot contain another goal"

  @doc """
  The error message attached to `:type` when a goal would be given a parent.

      iex> Kanban.Tasks.Task.HierarchyValidations.nested_goal_message()
      "must be 'work' or 'defect' for a task inside a goal; a goal cannot contain another goal"
  """
  def nested_goal_message, do: @nested_goal_message

  @nested_tasks_message "must be empty for a task inside a goal; tasks cannot be nested more than one level"

  @doc """
  The error message attached to `:tasks` when a goal's child carries tasks of
  its own. Only the API can send this shape, so it is not translated.

      iex> Kanban.Tasks.Task.HierarchyValidations.nested_tasks_message()
      "must be empty for a task inside a goal; tasks cannot be nested more than one level"
  """
  def nested_tasks_message, do: @nested_tasks_message

  @doc """
  Checks the child task attrs of a goal-with-tasks create before anything is
  generated or written. Returns `nil` when every child is acceptable, else
  `{index, field, message}` for the first child that would break the two-level
  hierarchy: a child of type goal (`:type`), or a child with a non-empty `tasks`
  list (`:tasks`), which would otherwise be silently dropped.

      iex> Kanban.Tasks.Task.HierarchyValidations.child_task_error([%{"type" => "work"}])
      nil

      iex> Kanban.Tasks.Task.HierarchyValidations.child_task_error([%{}, %{"type" => "goal"}])
      {1, :type, Kanban.Tasks.Task.HierarchyValidations.nested_goal_message()}
  """
  def child_task_error(child_tasks_attrs) when is_list(child_tasks_attrs) do
    child_tasks_attrs
    |> Enum.with_index()
    |> Enum.find_value(fn {attrs, index} -> child_error(attrs, index) end)
  end

  def child_task_error(_child_tasks_attrs), do: nil

  defp child_error(attrs, index) when is_map(attrs) do
    cond do
      TaskType.from_attrs(attrs) == :goal -> {index, :type, @nested_goal_message}
      nested_tasks?(attrs) -> {index, :tasks, @nested_tasks_message}
      true -> nil
    end
  end

  defp child_error(_attrs, _index), do: nil

  defp nested_tasks?(attrs), do: Map.get(attrs, "tasks", Map.get(attrs, :tasks)) not in [nil, []]

  @doc """
  Adds an error on `:type` when the changeset would leave a goal with a
  `parent_id`, and only when `:type` or `:parent_id` is being changed.
  """
  def validate_goal_has_no_parent(changeset) do
    if hierarchy_changed?(changeset) and nested_goal?(changeset) do
      add_error(changeset, :type, @nested_goal_message)
    else
      changeset
    end
  end

  defp hierarchy_changed?(changeset) do
    changed?(changeset, :type) or changed?(changeset, :parent_id)
  end

  defp nested_goal?(changeset) do
    get_field(changeset, :type) == :goal and not is_nil(get_field(changeset, :parent_id))
  end
end
