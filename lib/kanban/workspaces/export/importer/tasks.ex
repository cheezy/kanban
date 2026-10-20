defmodule Kanban.Workspaces.Export.Importer.Tasks do
  @moduledoc """
  The task half of `Kanban.Workspaces.Export.Importer` (W2222): tasks, their
  labels, comments and history, inside the importer's transaction.

  Tasks are inserted in two passes. The first inserts every task with its
  column and users remapped and no task references, so insertion order never
  matters; the second sets each `parent_id` and duplicate link through the
  task changeset, now that every task has its new id. Identifiers,
  `dependencies`, statuses and positions are kept verbatim.

  Every user attribution goes through
  `Kanban.Workspaces.Export.Importer.Users.attributed/2`, so it names only
  members of the importing Organization and is otherwise left empty.

  A reference the archive cannot resolve — a parent or duplicate outside the
  workspace, a comment on a task that is not in it — is skipped and reported,
  never guessed. A task, label link, comment or history row that fails its
  changeset for any other reason rolls the whole import back, naming it.
  """

  alias Kanban.Labels.TaskLabel
  alias Kanban.Repo
  alias Kanban.Tasks.Task
  alias Kanban.Tasks.TaskComment
  alias Kanban.Tasks.TaskHistory
  alias Kanban.Workspaces.Export.Importer
  alias Kanban.Workspaces.Export.Importer.Users

  @user_fields [
    "assigned_to_id",
    "created_by_id",
    "completed_by_id",
    "reviewed_by_id",
    "archived_by_id"
  ]
  @extra_fields [
    :review_requested_at,
    :after_goal_status,
    :after_goal_result,
    :after_goal_attempts
  ]
  @not_cast ["id", "column_id", "parent_id", "duplicate_of_id", "inserted_at", "updated_at"] ++
              Enum.map(@extra_fields, &Atom.to_string/1)

  @doc "Imports tasks, task labels, comments and history, in that order."
  @spec import_all(map()) :: map()
  def import_all(ctx) do
    ctx
    |> insert_tasks()
    |> link_tasks()
    |> insert_task_labels()
    |> insert_comments()
    |> insert_history()
  end

  defp insert_tasks(ctx) do
    {tasks, ctx} =
      ctx.rows.tasks
      |> Enum.sort_by(& &1["id"])
      |> Enum.reduce({%{}, ctx}, &insert_task_row/2)

    ctx |> Map.put(:tasks, tasks) |> Importer.put_count(:tasks, map_size(tasks))
  end

  defp insert_task_row(row, {tasks, ctx}) do
    case Map.fetch(ctx.columns, row["column_id"]) do
      {:ok, column_id} ->
        {task, ctx} = insert_task(ctx, row, column_id)
        {Map.put(tasks, row["id"], task), ctx}

      :error ->
        {tasks,
         Importer.skip(ctx, :tasks, "task #{row["identifier"]}: column not in the archive")}
    end
  end

  defp insert_task(ctx, row, column_id) do
    {attrs, ctx} =
      row
      |> Map.drop(@not_cast)
      |> Map.put("column_id", column_id)
      |> remap_users(ctx)
      |> hold_duplicate_link()
      |> keep_review_attribution(ctx)

    task =
      %Task{}
      |> Task.changeset(attrs)
      |> Ecto.Changeset.cast(
        Map.take(row, Enum.map(@extra_fields, &Atom.to_string/1)),
        @extra_fields
      )
      |> Importer.cast_timestamps(row)
      |> Importer.insert!(:tasks, row["identifier"])

    {task, ctx}
  end

  defp remap_users(attrs, ctx) do
    Enum.reduce(@user_fields, attrs, fn field, attrs ->
      Map.put(attrs, field, Users.attributed(ctx, attrs[field]))
    end)
  end

  # A duplicate needs the task it duplicates, which may not exist yet; the
  # reason is set again in link_tasks/1.
  defp hold_duplicate_link(%{"archive_reason" => "duplicate"} = attrs),
    do: Map.put(attrs, "archive_reason", nil)

  defp hold_duplicate_link(attrs), do: attrs

  # A finished review needs a reviewer; an unmatched one becomes the importing
  # org-admin.
  defp keep_review_attribution(attrs, ctx) do
    if attrs["review_status"] not in [nil, "pending"] and is_nil(attrs["reviewed_by_id"]) do
      {Map.put(attrs, "reviewed_by_id", ctx.admin.id), Map.update!(ctx, :reattributed, &(&1 + 1))}
    else
      {attrs, ctx}
    end
  end

  defp link_tasks(ctx) do
    Enum.reduce(ctx.rows.tasks, ctx, fn row, ctx ->
      case Map.fetch(ctx.tasks, row["id"]) do
        {:ok, task} ->
          ctx
          |> link(task, row, "parent_id", %{})
          |> link_duplicate(task, row)

        :error ->
          ctx
      end
    end)
  end

  defp link_duplicate(ctx, task, %{"archive_reason" => "duplicate"} = row),
    do: link(ctx, task, row, "duplicate_of_id", %{"archive_reason" => "duplicate"})

  defp link_duplicate(ctx, _task, _row), do: ctx

  defp link(ctx, task, row, field, extra) do
    case row[field] do
      nil ->
        ctx

      source_id ->
        case Map.fetch(ctx.tasks, source_id) do
          {:ok, target} ->
            update_link(ctx, task, row, Map.put(extra, field, target.id), field)

          :error ->
            Importer.skip(ctx, :tasks, "task #{row["identifier"]}: #{field} not in the archive")
        end
    end
  end

  # Re-read so the second link sees the first; a changeset that refuses the
  # link (a goal under a goal, from data older than that rule) is reported,
  # since nothing has reached the database yet.
  defp update_link(ctx, task, row, attrs, field) do
    changeset = Task |> Repo.get!(task.id) |> Task.changeset(attrs)

    if changeset.valid? do
      Repo.update(changeset) |> elem(0) |> link_result(row)
      ctx
    else
      Importer.skip(ctx, :tasks, "task #{row["identifier"]}: #{field} refused")
    end
  end

  defp link_result(:ok, _row), do: :ok
  defp link_result(:error, row), do: Importer.fail(:tasks, row["identifier"], :link_failed)

  defp insert_task_labels(ctx) do
    {count, ctx} =
      ctx.rows.task_labels
      |> Enum.uniq_by(&{&1["task_id"], &1["label_id"]})
      |> Enum.reduce({0, ctx}, &insert_task_label/2)

    Importer.put_count(ctx, :task_labels, count)
  end

  defp insert_task_label(row, {count, ctx}) do
    case label_link_target(ctx, row) do
      {:ok, task, label_id} ->
        insert_label_link(task, label_id)
        {count + 1, ctx}

      :error ->
        {count, Importer.skip(ctx, :task_labels, "task or label not in the archive")}
    end
  end

  defp label_link_target(ctx, row) do
    with {:ok, task} <- Map.fetch(ctx.tasks, row["task_id"]),
         {:ok, label_id} <- Map.fetch(ctx.labels, row["label_id"]) do
      {:ok, task, label_id}
    end
  end

  defp insert_label_link(task, label_id) do
    %TaskLabel{}
    |> Ecto.Changeset.change(task_id: task.id, label_id: label_id)
    |> Ecto.Changeset.unique_constraint([:task_id, :label_id])
    |> Importer.insert!(:task_labels, task.identifier)
  end

  defp insert_comments(ctx) do
    insert_task_children(ctx, :comments, fn row, task ->
      %TaskComment{
        task_id: task.id,
        author_user_id: Users.attributed(ctx, row["author_user_id"]),
        mentioned_user_ids: mentioned(ctx, row["mentioned_user_ids"])
      }
      |> TaskComment.changeset(%{"content" => row["content"]})
      |> put_agent_name(row["author_agent_name"])
      |> Ecto.Changeset.cast(Map.take(row, ["edited_at"]), [:edited_at])
      |> Importer.cast_timestamps(row)
    end)
  end

  # Through TaskComment's own length and storable-text checks.
  defp put_agent_name(changeset, nil), do: changeset

  defp put_agent_name(changeset, name),
    do: TaskComment.put_author_agent_name(changeset, to_string(name))

  defp insert_history(ctx) do
    insert_task_children(ctx, :task_history, fn row, task ->
      attrs =
        row
        |> Map.take(["type", "from_column", "to_column", "from_priority", "to_priority"])
        |> Map.merge(%{
          "task_id" => task.id,
          "from_user_id" => Users.attributed(ctx, row["from_user_id"]),
          "to_user_id" => Users.attributed(ctx, row["to_user_id"])
        })

      %TaskHistory{}
      |> TaskHistory.changeset(attrs)
      |> Importer.cast_timestamps(row, ["inserted_at"])
    end)
  end

  defp insert_task_children(ctx, entity, build) do
    {count, ctx} =
      ctx.rows
      |> Map.fetch!(entity)
      |> Enum.reduce({0, ctx}, &insert_task_child(&1, &2, entity, build))

    Importer.put_count(ctx, entity, count)
  end

  defp insert_task_child(row, {count, ctx}, entity, build) do
    case Map.fetch(ctx.tasks, row["task_id"]) do
      {:ok, task} ->
        row |> build.(task) |> Importer.insert!(entity, task.identifier)
        {count + 1, ctx}

      :error ->
        {count, Importer.skip(ctx, entity, "task not in the archive")}
    end
  end

  defp mentioned(ctx, ids) when is_list(ids) do
    ids |> Enum.map(&Users.attributed(ctx, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  defp mentioned(_ctx, _ids), do: []
end
