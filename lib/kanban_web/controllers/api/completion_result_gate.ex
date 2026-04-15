defmodule KanbanWeb.API.CompletionResultGate do
  @moduledoc """
  Gates `PATCH /api/tasks/:id/complete` on `explorer_result` and
  `reviewer_result` payloads.

  Runs `Kanban.Tasks.CompletionValidation` on each field. Grace mode
  (default) logs a structured warning and lets the request through.
  Strict mode returns a rejection body the controller renders as 422.

  The mode is read from `Application.get_env(:kanban,
  :strict_completion_validation, false)` so it can be flipped at runtime
  via the `STRIDE_STRICT_COMPLETION_VALIDATION` environment variable
  without a redeploy. Validation runs in both modes — the flag only
  decides whether failures become a 422 or a log line, which means the
  grace-mode warning volume is a faithful predictor of strict-mode
  rejection volume.
  """

  alias Kanban.Tasks.CompletionValidation

  require Logger

  @doc """
  Validates the payload and returns one of:

    * `:ok` — both results passed validation
    * `{:warn, failures}` — one or more failed, strict mode is OFF;
      caller proceeds, failures already logged
    * `{:reject, body}` — one or more failed, strict mode is ON;
      caller renders 422 with `body`

  Always logs a structured warning when failures are present, regardless
  of mode. The `:metadata` option extends the log metadata keyword list
  (e.g. `[task_id: task.id, agent: agent_name]`).
  """
  def gate(params, opts \\ []) when is_map(params) do
    strict? = Keyword.get(opts, :strict, strict?())
    metadata = Keyword.get(opts, :metadata, [])

    failures = collect_failures(params)

    handle_result(failures, strict?, metadata)
  end

  @doc """
  Returns the current value of `:strict_completion_validation`.
  """
  def strict?, do: Application.get_env(:kanban, :strict_completion_validation, false)

  defp collect_failures(params) do
    [
      evaluate("explorer_result", params["explorer_result"], &CompletionValidation.validate_explorer_result/1),
      evaluate("reviewer_result", params["reviewer_result"], &CompletionValidation.validate_reviewer_result/1)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp evaluate(field, payload, validator) do
    case validator.(payload) do
      {:ok, _} -> nil
      {:error, errors} -> %{field: field, errors: errors}
    end
  end

  defp handle_result([], _strict?, _metadata), do: :ok

  defp handle_result(failures, strict?, metadata) do
    log_warning(failures, metadata, strict?)

    if strict?, do: {:reject, build_body(failures)}, else: {:warn, failures}
  end

  defp log_warning(failures, metadata, strict?) do
    mode = if strict?, do: :strict, else: :grace

    summary =
      Enum.map_join(failures, "; ", fn %{field: field, errors: errors} ->
        fields = Enum.map_join(errors, ",", fn {f, _} -> to_string(f) end)
        "#{field}: #{fields}"
      end)

    log_metadata =
      [
        event: "stride.completion.validation_failed",
        mode: mode,
        failures: Enum.map(failures, &format_failure_for_metadata/1)
      ] ++ metadata

    Logger.warning("stride.completion.validation_failed (#{mode}): #{summary}", log_metadata)
  end

  defp format_failure_for_metadata(%{field: field, errors: errors}) do
    %{
      field: field,
      errors: Enum.map(errors, fn {f, msg} -> %{field: to_string(f), message: msg} end)
    }
  end

  defp build_body(failures) do
    %{
      error: "completion validation failed",
      failures:
        Enum.map(failures, fn %{field: field, errors: errors} ->
          %{
            field: field,
            errors: Enum.map(errors, fn {f, msg} -> %{field: to_string(f), message: msg} end)
          }
        end),
      required_format: %{
        "explorer_result" => %{
          "dispatched" => true,
          "summary" => "A substantive summary of what the subagent explored (40+ non-whitespace chars)",
          "duration_ms" => 12_000
        },
        "reviewer_result" => %{
          "dispatched" => true,
          "summary" => "A substantive summary of what the reviewer checked (40+ non-whitespace chars)",
          "duration_ms" => 8_000,
          "acceptance_criteria_checked" => 5,
          "issues_found" => 0
        },
        "skip_form" => %{
          "dispatched" => false,
          "reason" => "one of: #{Enum.map_join(CompletionValidation.skip_reasons(), ", ", &Atom.to_string/1)}",
          "summary" => "A substantive summary of what was self-reported (40+ non-whitespace chars)"
        }
      }
    }
  end
end
