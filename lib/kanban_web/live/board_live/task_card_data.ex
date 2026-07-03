defmodule KanbanWeb.BoardLive.TaskCardData do
  @moduledoc """
  Pure task-card view-model builder for `KanbanWeb.BoardLive.Show`, extracted
  from the LiveView (W1446). Adapts a `%Kanban.Tasks.Task{}` into the duck-typed
  map shape `KanbanWeb.TaskCard` renders — avatars, goal fields, meta counts,
  reviewer verdict fields, and done/cycle-time fields.

  Every function here is pure: it takes task + precomputed board data and returns
  display maps with no socket access. The dual string/atom key lookup
  (`get_in_either/2`) preserves the behavior of reading `reviewer_result` whether
  it arrived with atom keys (freshly built in-process) or string keys (JSONB
  from Postgres).
  """

  alias KanbanWeb.AvatarPalette

  @doc """
  Adapts a `%Kanban.Tasks.Task{}` into the duck-typed map shape the
  `KanbanWeb.TaskCard` component expects. Adds `:claimed_by` /
  `:completed_by` avatar maps when the task has the relevant fields
  populated, and `:promoted` so `KanbanWeb.GoalCard` knows whether to
  show the "Promote children to Ready" affordance.
  """
  def task_card_data(
        task,
        backlog_goals_with_children \\ MapSet.new(),
        goal_progress \\ %{},
        goals_by_id \\ %{}
      ) do
    task
    |> Map.from_struct()
    |> Map.merge(task_card_avatars(task))
    |> Map.merge(
      task_card_goal_fields(task, backlog_goals_with_children, goal_progress, goals_by_id)
    )
    |> Map.merge(task_card_meta_counts(task))
    |> Map.merge(task_card_review_fields(task))
    |> Map.merge(task_card_done_fields(task))
  end

  defp task_card_avatars(task) do
    %{claimed_by: claimed_by_for(task), completed_by: completed_by_for(task)}
  end

  defp task_card_goal_fields(task, backlog_goals_with_children, goal_progress, goals_by_id) do
    %{
      promoted: not MapSet.member?(backlog_goals_with_children, task.id),
      children: children_for(task, goal_progress),
      goal: Map.get(goals_by_id, task.parent_id)
    }
  end

  defp task_card_meta_counts(task) do
    %{
      key_files_count: count_or_nil(Map.get(task, :key_files)),
      deps_count: count_or_nil(Map.get(task, :dependencies)),
      acceptance_count: acceptance_count(Map.get(task, :acceptance_criteria))
    }
  end

  # Reviewer fields surface the task-reviewer subagent's verdict on the
  # task — populated at completion time. JSONB storage means the map
  # comes back with string keys; we look them up explicitly.
  defp task_card_review_fields(task) do
    reviewer = Map.get(task, :reviewer_result) || %{}

    %{
      reviewer_skipped?: reviewer_skipped?(reviewer),
      reviewer_skip_reason: get_in_either(reviewer, [:reason, "reason"]),
      criteria_checked:
        get_in_either(reviewer, [:acceptance_criteria_checked, "acceptance_criteria_checked"]),
      issues_found: get_in_either(reviewer, [:issues_found, "issues_found"]),
      files_changed_count: count_files_changed(Map.get(task, :actual_files_changed)),
      review_status: Map.get(task, :review_status)
    }
  end

  defp task_card_done_fields(task) do
    %{cycle_time: cycle_time_for(task)}
  end

  defp reviewer_skipped?(reviewer) when is_map(reviewer) do
    case get_in_either(reviewer, [:dispatched, "dispatched"]) do
      false -> true
      _ -> false
    end
  end

  defp reviewer_skipped?(_), do: false

  defp get_in_either(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn k -> Map.get(map, k) end)
  end

  defp get_in_either(_, _), do: nil

  defp count_files_changed(str) when is_binary(str) do
    case str
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))
         |> length() do
      0 -> nil
      n -> n
    end
  end

  defp count_files_changed(_), do: nil

  # Formats cycle time as "Nh Mm", "Nm", or "Ns" depending on duration.
  # Returns nil when the task hasn't been both claimed and completed.
  defp cycle_time_for(%{claimed_at: %DateTime{} = claimed, completed_at: %DateTime{} = completed}) do
    format_duration(DateTime.diff(completed, claimed, :second))
  end

  defp cycle_time_for(_), do: nil

  # Cycle time is always rendered in hours and minutes. Hours appear
  # only when the duration is ≥ 60 minutes; sub-hour durations show
  # just minutes. Multi-day cycles roll up into hours (a 30-hour cycle
  # reads "30h 15m", not "1d 6h") to keep the unit consistent.
  defp format_duration(secs) when is_integer(secs) and secs >= 0 do
    total_mins = div(secs, 60)
    hours = div(total_mins, 60)
    mins = rem(total_mins, 60)

    cond do
      hours == 0 -> "#{mins}m"
      mins == 0 -> "#{hours}h"
      true -> "#{hours}h #{mins}m"
    end
  end

  defp format_duration(_), do: nil

  # Returns the length of a non-empty list, or nil for empty/non-list
  # so TaskCard.backlog_meta hides the chip entirely when there's
  # nothing to surface.
  defp count_or_nil(list) when is_list(list) do
    case length(list) do
      0 -> nil
      n -> n
    end
  end

  defp count_or_nil(_), do: nil

  defp acceptance_count(text) when is_binary(text) do
    case text
         |> String.split("\n", trim: true)
         |> Enum.reject(&(String.trim(&1) == ""))
         |> length() do
      0 -> nil
      n -> n
    end
  end

  defp acceptance_count(_), do: nil

  defp children_for(%{type: :goal, id: id}, goal_progress) do
    case Map.get(goal_progress, id) do
      %{total: total, completed: done} when is_integer(total) ->
        %{total: total, done: done, review: 0, doing: 0, ready: 0}

      _ ->
        nil
    end
  end

  defp children_for(_task, _goal_progress), do: nil

  # Build the top-right avatar from `assigned_to` whenever a user is
  # assigned to the task — covers both "assigned but not yet claimed"
  # and "claimed and in progress." The legacy template surfaced an
  # assigned-user icon for both states; the new card uses the avatar
  # in the same slot.
  defp claimed_by_for(%{assigned_to: %{id: _id} = user}) do
    %{
      kind: :human,
      name: user_display_name(user),
      palette: AvatarPalette.for_human(user.id)
    }
  end

  defp claimed_by_for(_), do: nil

  defp completed_by_for(%{completed_by_agent: nil}), do: nil

  defp completed_by_for(%{completed_by_agent: agent}) when is_binary(agent) do
    %{kind: :agent, name: agent, palette: AvatarPalette.for_agent(agent)}
  end

  defp completed_by_for(_), do: nil

  defp user_display_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_display_name(%{email: email}) when is_binary(email), do: email
  defp user_display_name(_), do: "?"
end
