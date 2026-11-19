defmodule KanbanWeb.API.Me.ReviewJSON do
  @moduledoc """
  JSON rendering for `GET /api/me/reviews/:task_id` (W2751), from what
  `Kanban.Reviews.MobileReview.build/3` returns.

  The keys are a contract with every supported app version: add fields, never
  remove or rename one (docs/plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md §7.2).
  `priv/openapi/stride-api.json` documents the same keys, and
  `test/kanban_web/controllers/api/open_api_contract_test.exs` checks they
  agree. Every key is always present; a value that is unknown is `null`.

  The diffs themselves, their `diff_url`, and the task's `completion_notes`
  are never rendered here: the diff of one file is a later route of its own,
  and the notes are free text the app sends people to the web for.
  """

  alias Kanban.Tasks.Task

  @doc "The review screen's data, under `data`."
  def show(%{review: review}) do
    data =
      review
      |> verdict_part()
      |> Map.merge(detail_part(review))
      |> Map.merge(change_part(review))

    %{data: data}
  end

  defp verdict_part(review) do
    %{
      task: task(review.task),
      summary: review.summary,
      verdicts: Enum.map(review.verdicts, &verdict/1),
      acceptance_criteria: Enum.map(review.acceptance_criteria, &criterion/1),
      security_considerations: Enum.map(review.security_considerations, &consideration/1)
    }
  end

  defp detail_part(review) do
    %{
      security_findings: review.security_findings,
      project_checks: review.project_checks,
      exploratory: review.exploratory,
      behaviour_matrix: Enum.map(review.behaviour_matrix, &behaviour_row/1),
      review_requested_at: review.review_requested_at,
      waiting_since: review.waiting_since
    }
  end

  defp change_part(review) do
    %{
      files: Enum.map(review.files, &file/1),
      size: size(review.size),
      approvable_here: review.approvable_here,
      approvable_here_reason: atom_string(review.approvable_here_reason),
      holds_up: Enum.map(review.holds_up, &held_task/1)
    }
  end

  @doc """
  The review header: the task, who completed it and how long it took, its
  board and its goal (`null` without one).
  """
  def task(%Task{} = task) do
    %{
      id: task.id,
      identifier: task.identifier,
      title: task.title,
      priority: atom_string(task.priority),
      completed_by_agent: task.completed_by_agent,
      time_spent_minutes: task.time_spent_minutes,
      board: board(task.column),
      goal: goal(task.parent)
    }
  end

  defp board(%{board: %{id: id, name: name}}), do: %{id: id, name: name}

  defp goal(%Task{} = goal), do: %{id: goal.id, identifier: goal.identifier, title: goal.title}
  defp goal(_not_loaded_or_nil), do: nil

  @doc "One review section's verdict."
  def verdict(verdict) do
    %{section: atom_string(verdict.section), status: verdict.status, note: verdict.note}
  end

  @doc "One acceptance criterion with the reviewer's status and evidence."
  def criterion(criterion) do
    %{criterion: criterion.criterion, status: criterion.status, evidence: criterion.evidence}
  end

  @doc "One security consideration with the reviewer's status and detail."
  def consideration(consideration) do
    %{
      consideration: consideration.consideration,
      status: consideration.status,
      detail: consideration.detail
    }
  end

  @doc "One row of the behaviour matrix the reviewer echoed."
  def behaviour_row(row) do
    %{
      category: row.category,
      behaviour: row.behaviour,
      test_name: row.test_name,
      type: row.type,
      status: row.status
    }
  end

  @doc "One changed file, with its counts and its flag."
  def file(file) do
    %{
      index: file.index,
      path: file.path,
      additions: file.additions,
      deletions: file.deletions,
      truncated: file.truncated,
      flagged: file.flagged,
      flag_reason: atom_string(file.flag_reason)
    }
  end

  @doc "The change's size, as the large-change guard counts it."
  def size(size) do
    %{
      files: size.files,
      changed_lines: size.changed_lines,
      truncated: size.truncated,
      large_change: size.large_change
    }
  end

  @doc "A task this review holds up."
  def held_task(%Task{} = task) do
    %{id: task.id, identifier: task.identifier, title: task.title}
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
end
