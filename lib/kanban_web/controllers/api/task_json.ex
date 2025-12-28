defmodule KanbanWeb.API.TaskJSON do
  alias Kanban.Tasks.Task

  def index(%{tasks: tasks}) do
    %{data: for(task <- tasks, do: data(task))}
  end

  def show(%{task: task}) do
    %{data: data(task)}
  end

  def tree(%{tree: tree}) do
    %{
      data: %{
        task: data(tree.task),
        children: Enum.map(tree.children, &data/1),
        counts: tree.counts
      }
    }
  end

  # credo:disable-for-next-line Credo.Check.Refactor.ABCSize
  defp data(%Task{} = task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      acceptance_criteria: task.acceptance_criteria,
      position: task.position,
      type: task.type,
      priority: task.priority,
      identifier: task.identifier,
      column_id: task.column_id,
      assigned_to_id: task.assigned_to_id,
      parent_id: task.parent_id,
      complexity: task.complexity,
      estimated_files: task.estimated_files,
      why: task.why,
      what: task.what,
      where_context: task.where_context,
      patterns_to_follow: task.patterns_to_follow,
      database_changes: task.database_changes,
      validation_rules: task.validation_rules,
      telemetry_event: task.telemetry_event,
      metrics_to_track: task.metrics_to_track,
      logging_requirements: task.logging_requirements,
      error_user_message: task.error_user_message,
      error_on_failure: task.error_on_failure,
      key_files: render_key_files(task),
      verification_steps: render_verification_steps(task),
      technology_requirements: task.technology_requirements,
      pitfalls: task.pitfalls,
      out_of_scope: task.out_of_scope,
      security_considerations: task.security_considerations,
      testing_strategy: task.testing_strategy,
      integration_points: task.integration_points,
      created_by_id: task.created_by_id,
      created_by_agent: task.created_by_agent,
      completed_at: task.completed_at,
      completed_by_id: task.completed_by_id,
      completed_by_agent: task.completed_by_agent,
      completion_summary: task.completion_summary,
      dependencies: task.dependencies,
      status: task.status,
      claimed_at: task.claimed_at,
      claim_expires_at: task.claim_expires_at,
      required_capabilities: task.required_capabilities,
      actual_complexity: task.actual_complexity,
      actual_files_changed: task.actual_files_changed,
      time_spent_minutes: task.time_spent_minutes,
      needs_review: task.needs_review,
      review_status: task.review_status,
      review_notes: task.review_notes,
      reviewed_at: task.reviewed_at,
      reviewed_by_id: task.reviewed_by_id,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp render_key_files(%Task{key_files: key_files}) when is_list(key_files) do
    Enum.map(key_files, fn kf ->
      %{
        file_path: kf.file_path,
        note: kf.note,
        position: kf.position
      }
    end)
  end

  defp render_key_files(_), do: []

  defp render_verification_steps(%Task{verification_steps: steps}) when is_list(steps) do
    Enum.map(steps, fn step ->
      %{
        step_type: step.step_type,
        step_text: step.step_text,
        expected_result: step.expected_result,
        position: step.position
      }
    end)
  end

  defp render_verification_steps(_), do: []

  def error(%{changeset: changeset}) do
    %{
      errors:
        Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
          Enum.reduce(opts, msg, fn {key, value}, acc ->
            string_value =
              if is_binary(value) or is_number(value) or is_atom(value) do
                to_string(value)
              else
                inspect(value)
              end

            String.replace(acc, "%{#{key}}", string_value)
          end)
        end)
    }
  end
end
