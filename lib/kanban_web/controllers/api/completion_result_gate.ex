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
    task = Keyword.get(opts, :task)

    always = contract_failures(params, task)
    gated = gated_failures(params)

    handle_result(always, gated, strict?, metadata)
  end

  @doc """
  Returns the current value of `:strict_completion_validation` — the single
  source of truth for the grace decision. The always-reject review contract
  (W1070) does NOT consult it; only the legacy-shape grace path does.
  """
  def strict?, do: Application.get_env(:kanban, :strict_completion_validation, false)

  # W1070: the fully-populated + consistent review contract is enforced
  # UNCONDITIONALLY — these failures reject regardless of the grace flag, so a
  # thin, task-inconsistent, or omitted review can never complete. Scoped to
  # completeness/consistency only (see CompletionValidation.review_contract_failures/2);
  # legacy shape nits stay in gated_failures/1. Folded into the same
  # "reviewer_result" field shape the controller already renders.
  defp contract_failures(params, task) do
    case CompletionValidation.review_contract_failures(params["reviewer_result"], task) do
      [] -> []
      errors -> [%{field: "reviewer_result", errors: errors}]
    end
  end

  # Grace-gated: explorer_result, reviewer_result legacy/shape checks (presence of
  # the structured block is handled unconditionally by the contract above, so the
  # base check runs WITHOUT require_structured_block here), and changed_files.
  defp gated_failures(params) do
    [
      evaluate(
        "explorer_result",
        params["explorer_result"],
        &CompletionValidation.validate_explorer_result/1
      ),
      evaluate(
        "reviewer_result",
        params["reviewer_result"],
        &CompletionValidation.validate_reviewer_result/1
      ),
      evaluate_changed_files(params)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # `changed_files` is optional on /complete (D36): the field is no longer
  # persisted via this path, so an omitted/nil value is a no-op here. The
  # standalone PUT /api/tasks/:id/changed_files endpoint enforces nil
  # rejection at the controller layer.
  defp evaluate_changed_files(%{"changed_files" => nil}), do: nil
  defp evaluate_changed_files(params) when not is_map_key(params, "changed_files"), do: nil

  defp evaluate_changed_files(params) do
    evaluate(
      "changed_files",
      params["changed_files"],
      &CompletionValidation.validate_changed_files/1
    )
  end

  defp evaluate(field, payload, validator) do
    case validator.(payload) do
      {:ok, _} -> nil
      {:error, errors} -> %{field: field, errors: errors}
    end
  end

  defp handle_result([], [], _strict?, _metadata), do: :ok

  defp handle_result(always, gated, strict?, metadata) do
    # The contract and the base/shape checks can both fail under "reviewer_result";
    # merge by field so the body carries one entry per field with all its errors.
    all = merge_by_field(always ++ gated)
    # Reject when the always-on contract failed (any mode) OR strict mode is on.
    reject? = always != [] or strict?
    log_warning(all, metadata, reject?)

    if reject?, do: {:reject, build_body(all)}, else: {:warn, merge_by_field(gated)}
  end

  # Stable merge: preserve first-seen field order, concatenating errors per field.
  defp merge_by_field(failures) do
    fields = failures |> Enum.map(& &1.field) |> Enum.uniq()
    Enum.map(fields, &%{field: &1, errors: errors_for_field(failures, &1)})
  end

  defp errors_for_field(failures, field) do
    failures
    |> Enum.filter(&(&1.field == field))
    |> Enum.flat_map(& &1.errors)
  end

  defp log_warning(failures, metadata, reject?) do
    mode = if reject?, do: :reject, else: :grace

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
          "summary" =>
            "A substantive summary of what the subagent explored (40+ non-whitespace chars)",
          "duration_ms" => 12_000
        },
        "reviewer_result" => %{
          "dispatched" => true,
          "summary" =>
            "A substantive summary of what the reviewer checked (40+ non-whitespace chars)",
          "duration_ms" => 8_000,
          "acceptance_criteria_checked" => 5,
          "issues_found" => 0,
          "status" => "approved",
          "issue_counts" => %{"critical" => 0, "important" => 0, "minor" => 0},
          "issues" => [],
          "acceptance_criteria" => [
            %{"criterion" => "All positions recalculate on move", "status" => "met"}
          ],
          "schema_version" => "1.0"
        },
        "skip_form" => %{
          "dispatched" => false,
          "reason" =>
            "one of: #{Enum.map_join(CompletionValidation.skip_reasons(), ", ", &Atom.to_string/1)}",
          "summary" =>
            "A substantive summary of what was self-reported (40+ non-whitespace chars)"
        },
        "changed_files" => [
          %{
            "path" => "lib/foo.ex",
            "diff" => "Unified-patch text — see docs/diff-contract.md (≤ 500 lines per file)"
          },
          %{"path" => "assets/logo.png", "diff" => "[binary file — no diff captured]"}
        ]
      }
    }
  end
end
