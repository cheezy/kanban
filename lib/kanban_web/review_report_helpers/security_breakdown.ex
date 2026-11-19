defmodule KanbanWeb.ReviewReportHelpers.SecurityBreakdown do
  @moduledoc """
  The per-consideration mitigation breakdown of a task's security review, read
  from `reviewer_result["security_considerations"]["considerations"]`
  (W1866/W1867).

  Moved out of `KanbanWeb.ReviewReportHelpers` in W2751 to keep that module
  near the size guidance in AGENTS.md. `ReviewReportHelpers` still exposes it
  as `security_considerations_breakdown/1`, so callers are unchanged. Pure; no
  database access.
  """

  @doc """
  Extracts the per-consideration mitigation breakdown.

  Returns a list of `%{consideration: string, status: string | nil, detail:
  string | nil}` maps — one per well-formed entry — or `[]` when the breakdown is
  absent, `nil`, not a list, or the `reviewer_result` carries none. Entries
  without a non-blank `consideration` string are dropped so the read side never
  renders an empty row: the write-side validator already rejects those, but
  legacy or partial data must not crash the queue. `detail` is the reviewer's
  optional `evidence` (preferred) or `note` string, whichever is present.
  """
  @spec breakdown(map()) :: [
          %{consideration: String.t(), status: String.t() | nil, detail: String.t() | nil}
        ]
  def breakdown(task) do
    task
    |> raw_considerations()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_consideration/1)
    |> Enum.reject(&is_nil/1)
  end

  # The raw considerations list from the reviewer_result, or [] when absent, nil,
  # or not a list. Kept separate so the public function stays a flat pipeline.
  defp raw_considerations(task) do
    with %{} = result <- reviewer_result(task),
         %{"considerations" => considerations} when is_list(considerations) <-
           Map.get(result, "security_considerations") do
      considerations
    else
      _ -> []
    end
  end

  defp normalize_consideration(entry) do
    case Map.get(entry, "consideration") do
      text when is_binary(text) ->
        case String.trim(text) do
          "" ->
            nil

          trimmed ->
            %{
              consideration: trimmed,
              status: consideration_status(entry),
              detail: consideration_detail(entry)
            }
        end

      _ ->
        nil
    end
  end

  defp consideration_status(entry) do
    case Map.get(entry, "status") do
      status when is_binary(status) -> status
      _ -> nil
    end
  end

  # The reviewer may attach an optional rationale under either "evidence" or
  # "note" (neither is server-validated); prefer evidence, fall back to note.
  defp consideration_detail(entry) do
    trimmed_value(entry, "evidence") || trimmed_value(entry, "note")
  end

  defp trimmed_value(entry, key) do
    case Map.get(entry, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp reviewer_result(%{reviewer_result: %{} = result}), do: result
  defp reviewer_result(%{"reviewer_result" => %{} = result}), do: result
  defp reviewer_result(_), do: nil
end
