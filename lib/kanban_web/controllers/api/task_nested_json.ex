defmodule KanbanWeb.API.TaskNestedJSON do
  @moduledoc """
  Renderers for the nested collections of the full task view — `key_files`,
  `verification_steps`, `behaviour_test_matrix` and `labels` — extracted from
  `KanbanWeb.API.TaskJSON` to keep that module under the size guideline.

  Each renderer takes a `%Kanban.Tasks.Task{}` and returns a list of plain
  maps. Anything other than a loaded list (a `nil` embed, or an association
  that was not preloaded) renders as `[]`, so a caller that forgot a preload
  degrades to an empty list rather than crashing the JSON encoder. Every API
  route that renders the full view preloads `:labels`, so on those routes the
  list is truthful.
  """

  alias Kanban.Tasks.Task

  @doc "Renders `key_files` as `file_path`/`note`/`position` maps."
  def key_files(%Task{key_files: key_files}) when is_list(key_files) do
    Enum.map(key_files, fn kf ->
      %{
        file_path: kf.file_path,
        note: kf.note,
        position: kf.position
      }
    end)
  end

  def key_files(_), do: []

  @doc "Renders `verification_steps` in their stored order."
  def verification_steps(%Task{verification_steps: steps}) when is_list(steps) do
    Enum.map(steps, fn step ->
      %{
        step_type: step.step_type,
        step_text: step.step_text,
        expected_result: step.expected_result,
        position: step.position
      }
    end)
  end

  def verification_steps(_), do: []

  @doc "Renders `behaviour_test_matrix` rows in their stored order."
  def behaviour_test_matrix(%Task{behaviour_test_matrix: rows}) when is_list(rows) do
    Enum.map(rows, fn row ->
      %{
        category: row.category,
        behaviour: row.behaviour,
        test_name: row.test_name,
        type: row.type,
        status: row.status,
        na_reason: row.na_reason,
        position: row.position
      }
    end)
  end

  def behaviour_test_matrix(_), do: []

  @doc """
  Renders the task's labels as `name`/`color` maps, ordered by name ignoring
  case (the board's own label order). Label ids are deliberately not exposed:
  the API addresses labels by name (W2239).
  """
  def labels(%Task{labels: labels}) when is_list(labels) do
    labels
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
    |> Enum.map(&%{name: &1.name, color: &1.color})
  end

  def labels(_), do: []
end
