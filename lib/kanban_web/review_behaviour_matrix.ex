defmodule KanbanWeb.ReviewBehaviourMatrix do
  @moduledoc """
  Read-side normalizer for the reviewer's `behaviour_test_matrix` verdict on the
  Review queue (W1920 write side -> W1921 read side).

  The task-reviewer agent echoes the task's behaviour/test matrix back inside
  `reviewer_result["behaviour_test_matrix"]["rows"]`.
  `Kanban.Tasks.CompletionValidation` shape-checks that echo at completion time,
  but the verdict is entirely optional and every completion before W1920
  predates it, so the read side must tolerate anything: a missing key, an
  explicit nil, a non-map verdict, a non-list `rows`, entries that are not maps,
  and rows missing the required keys. Nothing here raises, and no row value is
  ever converted to an atom — rows are agent-supplied, untrusted data.

  Lives beside `KanbanWeb.ReviewAcceptance` rather than inside
  `KanbanWeb.ReviewReportHelpers` (833 lines) so that already-over-cap module
  does not grow further; `CODE-REVIEW.md` asks new modules to stay under ~600
  lines. The pipeline deliberately mirrors
  `ReviewReportHelpers.security_considerations_breakdown/1` so the two
  read-side normalizers stay recognizably the same shape.

  Pure; no database access. Accepts a task struct, an atom-keyed map, or a
  string-keyed map.
  """

  @doc """
  Render-ready rows from `reviewer_result["behaviour_test_matrix"]["rows"]`.

  Returns one map per well-formed row — `%{category:, behaviour:, test_name:,
  type:, status:}` — or `[]` when the verdict is absent, nil, not a map, carries
  no `rows` list, or the task has no `reviewer_result` at all.

  A row is kept only when it is a map carrying non-blank `"category"` and
  `"behaviour"` strings — the same required pair `CompletionValidation` enforces
  on the write side — so the queue never renders a headless row. The optional
  `"test_name"`, `"type"` and `"status"` are trimmed and become `nil` when
  absent, blank, or not a string: a junk optional field never costs the reader
  the category and behaviour the reviewer did supply. `status` is passed through
  verbatim; the render side owns the tone and label fallback for unrecognized
  values.
  """
  @spec rows(map()) :: [
          %{
            category: String.t(),
            behaviour: String.t(),
            test_name: String.t() | nil,
            type: String.t() | nil,
            status: String.t() | nil
          }
        ]
  def rows(task) do
    task
    |> raw_rows()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_row/1)
    |> Enum.reject(&is_nil/1)
  end

  # The raw rows list, or [] when the verdict is absent, nil, not a map, or
  # carries a non-list `rows`. Kept separate so `rows/1` stays a flat pipeline.
  defp raw_rows(task) do
    with %{} = result <- reviewer_result(task),
         %{"rows" => rows} when is_list(rows) <- Map.get(result, "behaviour_test_matrix") do
      rows
    else
      _ -> []
    end
  end

  defp normalize_row(row) do
    case {trimmed(row, "category"), trimmed(row, "behaviour")} do
      {category, behaviour} when is_binary(category) and is_binary(behaviour) ->
        %{
          category: category,
          behaviour: behaviour,
          test_name: trimmed(row, "test_name"),
          type: trimmed(row, "type"),
          status: trimmed(row, "status")
        }

      _ ->
        nil
    end
  end

  defp trimmed(row, key) do
    case Map.get(row, key) do
      value when is_binary(value) -> presence(String.trim(value))
      _ -> nil
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp reviewer_result(%{reviewer_result: %{} = result}), do: result
  defp reviewer_result(%{"reviewer_result" => %{} = result}), do: result
  defp reviewer_result(_), do: nil
end
