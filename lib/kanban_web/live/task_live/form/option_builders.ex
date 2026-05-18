defmodule KanbanWeb.TaskLive.Form.OptionBuilders do
  @moduledoc """
  Pure builders for the task form's dropdown options and initial changeset.
  Used by `KanbanWeb.TaskLive.FormComponent.update/2` to populate the
  `column_options`, `assignable_users`, and `goal_options` assigns.
  """
  use KanbanWeb, :verified_routes
  use Gettext, backend: KanbanWeb.Gettext

  import Ecto.Query

  alias Kanban.Repo
  alias Kanban.Tasks

  @doc """
  Pick the column_id for the new changeset: prefer an explicit assign,
  otherwise fall back to the task's current column.
  """
  def get_column_id(%{column_id: col_id}, _task) when not is_nil(col_id), do: col_id
  def get_column_id(_assigns, task), do: task.column_id

  @doc """
  Build the initial changeset for the form. For new tasks the
  `human_task: true` flag is set so AI auto-fill doesn't accidentally
  overwrite operator input.
  """
  def build_changeset(task, nil, action) do
    task
    |> Tasks.Task.changeset(%{})
    |> maybe_default_human_task(action)
  end

  def build_changeset(task, column_id, action) do
    task
    |> Tasks.Task.changeset(%{})
    |> Ecto.Changeset.put_change(:column_id, column_id)
    |> maybe_default_human_task(action)
  end

  defp maybe_default_human_task(changeset, :new_task) do
    Ecto.Changeset.put_change(changeset, :human_task, true)
  end

  defp maybe_default_human_task(changeset, _action), do: changeset

  @doc """
  Build the `{label, id}` list for the column dropdown. WIP-full columns
  are surfaced (with a label suffix) only when they are the task's current
  column — otherwise they are filtered out.
  """
  def build_column_options(columns, task) do
    columns
    |> Enum.map(&column_option(&1, task))
    |> Enum.reject(&reject_full_column?(&1, task))
  end

  defp column_option(column, task) do
    can_add = Tasks.can_add_task?(column)

    label =
      if can_add || column.id == task.column_id do
        column.name
      else
        "#{column.name} (#{wip_limit_suffix()})"
      end

    {label, column.id}
  end

  defp reject_full_column?({label, id}, task) do
    String.contains?(label, wip_limit_suffix()) && id != task.column_id
  end

  defp wip_limit_suffix, do: gettext("WIP limit reached")

  @doc """
  Build the `{display_name, id}` list for the assignee dropdown, prefixed
  with an Unassigned option.
  """
  def build_assignable_users_options(board_users) do
    users_list =
      board_users
      |> Enum.map(fn %{user: user} ->
        display_name = if user.name && user.name != "", do: user.name, else: user.email
        {display_name, user.id}
      end)

    [{gettext("Unassigned"), nil} | users_list]
  end

  @doc """
  Build the `{label, id}` list for the parent-goal dropdown, prefixed
  with a "No parent goal" option. Excludes the task itself from its
  own parent options.
  """
  def build_goal_options(board, task) do
    goals =
      from(t in Tasks.Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board.id,
        where: t.type == :goal,
        where: t.id != ^(task.id || 0),
        order_by: [asc: t.identifier],
        select: {t.identifier, t.title, t.id}
      )
      |> Repo.all()
      |> Enum.map(fn {identifier, title, id} ->
        {"#{identifier} - #{title}", id}
      end)

    [{gettext("No parent goal"), nil} | goals]
  end
end
