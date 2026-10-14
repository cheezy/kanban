defmodule KanbanWeb.TaskLive.Form.TaskParams do
  @moduledoc """
  Pure helpers for converting raw form params into the shape the task save
  pipeline expects: id coercion, assignment-target parsing, scope-error
  labelling, cascade counting, and flash-message building.

  Used by `KanbanWeb.TaskLive.FormComponent` from the save path. None of these
  functions touch the socket — pass the task struct and params explicitly.
  """
  use Gettext, backend: KanbanWeb.Gettext

  alias Kanban.Tasks

  # Postgres bigint, the type of every id column.
  @max_bigint 9_223_372_036_854_775_807

  @doc """
  Coerce a primary-key input into `{:ok, integer}` or `:error`. Accepts
  positive integers and decimal strings within the Postgres bigint range; a
  larger one would raise in the lookup. Used by the form's relational scope
  validators.
  """
  def coerce_id(id) when is_integer(id) and id > 0 and id <= @max_bigint, do: {:ok, id}

  def coerce_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> coerce_id(n)
      _ -> :error
    end
  end

  def coerce_id(_), do: :error

  @doc """
  User-facing label for a scope-validation failure on one of the form's
  relational fields. Returned as a top-of-form error message.
  """
  def scope_error_label(:column_id), do: gettext("Security error: Invalid column")
  def scope_error_label(:parent_id), do: gettext("Security error: Invalid parent goal")
  def scope_error_label(:assigned_to_id), do: gettext("Security error: Invalid assignee")
  def scope_error_label(:label_ids), do: gettext("Security error: Invalid label")

  @doc """
  When a goal's `assigned_to_id` is being changed, ask the Tasks context how
  many non-completed children will inherit the new assignment via the
  cascade in `Lifecycle.update_task/2`. The count is computed BEFORE the
  cascade runs, so it reflects the eligible-children set the cascade will
  touch. Returns 0 for non-goal tasks or when assignment is unchanged.
  """
  def compute_cascade_count(task, task_params) do
    if task.type == :goal and Map.has_key?(task_params, "assigned_to_id") do
      target = parse_assignment_target(task_params["assigned_to_id"])
      Tasks.count_cascade_affected_children(task, target)
    else
      0
    end
  end

  defp parse_assignment_target(value) do
    case coerce_id(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  @doc """
  Build the success flash for `perform_task_update`, including pluralized
  cascade-child language when the goal assignment change cascaded to
  one or more children.
  """
  def build_update_flash(0), do: gettext("Task updated successfully")

  def build_update_flash(n) when n > 0 do
    ngettext(
      "Task updated successfully. 1 child task was also updated.",
      "Task updated successfully. %{count} child tasks were also updated.",
      n
    )
  end
end
